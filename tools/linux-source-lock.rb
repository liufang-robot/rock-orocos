#!/usr/bin/env ruby

require "find"
require "json"
require "open3"
require "yaml"
require_relative "check-source-provenance"

module OrocosRock
  module LinuxSourceLock
    PACKAGE_SET_NAME = "rock-package-set"
    UNUSED_SOURCE_NAMES = %w[vcpkg].freeze
    SELECTORS = {
      "farbot" => "farbot",
      "rtlog-cpp" => "rtlog-cpp",
      "rtt" => "rtt",
      "open62541" => "open62541",
      "open62541pp" => "open62541pp",
      "rtt_opcua" => "rtt_opcua",
      "ocl" => "ocl",
      "orogen" => "orogen",
      "typelib" => "typelib",
      "utilmm" => "utilmm",
      "utilrb" => "utilrb",
      "metaruby" => "tools/metaruby",
      "rtt_typelib" => "rtt_typelib"
    }.freeze
    CHECKOUT_PATHS = {
      "farbot" => "toolchain/farbot",
      "rtlog-cpp" => "toolchain/rtlog-cpp",
      "rtt" => "toolchain/tools/rtt",
      "open62541" => "toolchain/open62541",
      "open62541pp" => "toolchain/open62541pp",
      "rtt_opcua" => "toolchain/tools/rtt_opcua",
      "ocl" => "toolchain/tools/ocl",
      "utilmm" => "toolchain/tools/utilmm",
      "typelib" => "toolchain/tools/typelib",
      "rtt_typelib" => "toolchain/tools/rtt_typelib",
      "utilrb" => "toolchain/tools/utilrb",
      "metaruby" => "tools/metaruby",
      "orogen" => "toolchain/tools/orogen",
      PACKAGE_SET_NAME =>
        ".autoproj/remotes/git_https___github_com_rock_core_package_set_git"
    }.freeze
    GENERATED_CHECKOUT_PATH_PREFIXES = %w[build/].freeze
    EXPECTED_REPOSITORIES =
      OrocosRock::SourceProvenance::FIRST_PARTY_REPOSITORIES.merge(
        OrocosRock::SourceProvenance::THIRD_PARTY_REPOSITORIES
      ).freeze

    module_function

    def load_lock(path)
      document = JSON.parse(File.read(path))
      unless document.is_a?(Hash) && document.keys.sort == %w[schema_version sources]
        raise "source lock root must contain only schema_version and sources"
      end
      raise "source lock schema_version must be 1" unless document["schema_version"] == 1
      raise "source lock sources must be an array" unless document["sources"].is_a?(Array)

      sources = {}
      document["sources"].each do |source|
        unless source.is_a?(Hash) && source.keys.sort == %w[name repository revision]
          raise "every source lock entry must contain only name, repository, and revision"
        end

        name = source.fetch("name")
        raise "duplicate source lock entry #{name}" if sources.key?(name)
        unless source.fetch("revision").match?(/\A[0-9a-f]{40}\z/)
          raise "source lock entry #{name} must use a lowercase 40-character revision"
        end

        sources[name] = source
      end

      expected = SELECTORS.keys + [PACKAGE_SET_NAME] + UNUSED_SOURCE_NAMES
      missing = expected - sources.keys
      unknown = sources.keys - expected
      raise "source lock is missing: #{missing.sort.join(', ')}" unless missing.empty?
      raise "source lock contains unknown entries: #{unknown.sort.join(', ')}" unless unknown.empty?

      expected.each do |name|
        actual_repository = sources.fetch(name).fetch("repository")
        expected_repository = EXPECTED_REPOSITORIES.fetch(name)
        next if actual_repository == expected_repository

        raise "source lock entry #{name} must use canonical repository " \
              "#{expected_repository.inspect}, got #{actual_repository.inspect}"
      end

      sources
    end

    def apply(root, sources)
      overrides_path = File.join(root, "autoproj", "overrides.yml")
      overrides = YAML.safe_load_file(overrides_path)
      entries = %w[version_control overrides].flat_map { |section| overrides.fetch(section) }

      SELECTORS.each do |name, selector|
        entry = entries.find { |candidate| candidate.key?(selector) }
        raise "Autoproj source selection is missing #{selector}" unless entry

        source = sources.fetch(name)
        unless entry.fetch("url") == source.fetch("repository")
          raise "Autoproj source #{selector} does not match the source lock repository"
        end
        entry["commit"] = source.fetch("revision")
      end
      File.write(overrides_path, YAML.dump(overrides))

      manifest_path = File.join(root, "autoproj", "manifest")
      manifest = YAML.safe_load_file(manifest_path)
      package_sets = manifest.fetch("package_sets")
      locked_set = sources.fetch(PACKAGE_SET_NAME)
      package_set = package_sets.find { |candidate| candidate["url"] == locked_set.fetch("repository") }
      raise "Autoproj manifest is missing the locked Rock package set" unless package_set

      package_set["commit"] = locked_set.fetch("revision")
      File.write(manifest_path, YAML.dump(manifest))
    end

    def normalize_repository(url)
      url.sub(%r{\Agit@github\.com:}, "https://github.com/")
         .sub(%r{\Assh://git@github\.com/}, "https://github.com/")
         .delete_suffix(".git")
         .delete_suffix("/")
    end

    def git_worktrees(root)
      worktrees = []
      Find.find(root) do |path|
        relative = path.delete_prefix("#{root}/")
        if File.directory?(path) && relative.match?(%r{\A(?:build|install|\.pixi)(?:/|\z)})
          Find.prune
        elsif File.basename(path) == ".git"
          worktrees << File.dirname(path)
          Find.prune if File.directory?(path)
        end
      end
      worktrees
    end

    def capture_git(directory, *arguments)
      output, status = Open3.capture2e("git", "-C", directory, *arguments)
      raise "git #{arguments.join(' ')} failed in #{directory}: #{output}" unless status.success?

      output.strip
    end

    def verify(root, sources)
      checkouts = git_worktrees(root).map do |directory|
        remotes = capture_git(directory, "remote").lines.map(&:strip).reject(&:empty?)
        repositories = remotes.map do |remote|
          normalize_repository(capture_git(directory, "remote", "get-url", remote))
        end
        [directory, repositories, capture_git(directory, "rev-parse", "HEAD")]
      end

      (sources.keys - UNUSED_SOURCE_NAMES).each do |name|
        source = sources.fetch(name)
        expected_repository = normalize_repository(source.fetch("repository"))
        matches = checkouts.select { |_directory, repositories, _head| repositories.include?(expected_repository) }
        raise "locked source #{name} was not checked out" if matches.empty?
        if matches.size > 1
          actual = matches.map(&:first).join(", ")
          raise "locked source #{name} has duplicate checkouts: #{actual}"
        end
        expected_directory = File.join(root, CHECKOUT_PATHS.fetch(name))
        unless matches.any? { |directory, _repositories, _head| directory == expected_directory }
          actual = matches.map(&:first).join(", ")
          raise "locked source #{name} must be checked out at #{expected_directory}, found #{actual}"
        end
        unless matches.any? { |_directory, _repositories, head| head == source.fetch("revision") }
          actual = matches.map { |directory, _repositories, head| "#{directory}=#{head}" }.join(", ")
          raise "locked source #{name} has the wrong revision: #{actual}"
        end
        tracked_changes = capture_git(
          expected_directory, "status", "--porcelain=v1",
          "--untracked-files=no", "--ignore-submodules=none"
        )
        unless tracked_changes.empty?
          raise "locked source #{name} has tracked changes: #{tracked_changes.lines.first.strip}"
        end
        untracked_files = capture_git(
          expected_directory, "ls-files", "--others", "--exclude-standard"
        ).lines.map(&:strip).reject(&:empty?)
        unexpected_untracked = untracked_files.reject do |path|
          GENERATED_CHECKOUT_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) }
        end
        unless unexpected_untracked.empty?
          raise "locked source #{name} has unexpected untracked files: " \
                "#{unexpected_untracked.first}"
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode, lock_path, root = ARGV
  unless %w[apply verify validate].include?(mode) && lock_path && root
    abort "usage: ruby tools/linux-source-lock.rb apply|verify|validate LOCK_PATH REPOSITORY_ROOT"
  end

  root = File.expand_path(root)
  sources = OrocosRock::LinuxSourceLock.load_lock(File.expand_path(lock_path))
  OrocosRock::LinuxSourceLock.public_send(mode, root, sources) unless mode == "validate"
  action = { "apply" => "Applied", "verify" => "Verified", "validate" => "Validated" }.fetch(mode)
  warn "#{action} #{sources.size - 1} locked Linux build sources."
end
