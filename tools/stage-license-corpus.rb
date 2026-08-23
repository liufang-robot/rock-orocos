#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "rubygems/package"
require "tmpdir"

module OrocosRock
  module LicenseCorpus
    ROOT_KEYS = %w[
      aggregate_license license_refs ruby_gems schema_version sources windows_vcpkg
    ].freeze
    PLATFORMS = %w[linux windows].freeze

    module_function

    def load_json(path, description)
      document = JSON.parse(File.read(path))
      raise "#{description} must be a JSON object" unless document.is_a?(Hash)

      document
    rescue Errno::ENOENT
      raise "#{description} does not exist: #{path}"
    rescue JSON::ParserError => e
      raise "#{description} is invalid JSON: #{e.message}"
    end

    def require_keys(document, keys, description)
      actual = document.keys.sort
      expected = keys.sort
      return if actual == expected

      raise "#{description} keys must equal #{expected.join(', ')}, got #{actual.join(', ')}"
    end

    def safe_relative_path(value, description)
      unless value.is_a?(String) && !value.empty? && !value.include?("\\")
        raise "#{description} must be a nonempty forward-slash relative path"
      end
      parts = value.split("/", -1)
      if value.start_with?("/") || parts.any? { |part| part.empty? || %w[. ..].include?(part) }
        raise "#{description} must not escape its declared root: #{value.inspect}"
      end

      parts
    end

    def checked_string(document, key, description, pattern = nil)
      value = document[key]
      unless value.is_a?(String) && !value.empty? && (!pattern || value.match?(pattern))
        raise "#{description} #{key} is invalid"
      end

      value
    end

    def checked_string_array(document, key, description)
      values = document[key]
      unless values.is_a?(Array) && !values.empty? &&
             values.all? { |value| value.is_a?(String) && !value.empty? }
        raise "#{description} #{key} must be a nonempty string array"
      end

      values
    end

    def literal_glob(path)
      path.gsub(/[\\*?\[\]]/) { |character| "\\#{character}" }
    end

    def relative_path_parts(root, path, description)
      relative = Pathname.new(File.expand_path(path)).relative_path_from(
        Pathname.new(File.expand_path(root))
      )
      safe_relative_path(relative.each_filename.to_a.join("/"), description)
    rescue ArgumentError
      raise "#{description} is not below its declared root: #{path}"
    end

    def validate_inventory(document)
      require_keys(document, ROOT_KEYS, "license inventory")
      raise "license inventory schema_version must be 1" unless document["schema_version"] == 1
      unless document["aggregate_license"].is_a?(Hash) &&
             document["aggregate_license"].keys.sort == PLATFORMS
        raise "license inventory aggregate_license must define linux and windows"
      end
      PLATFORMS.each do |platform|
        checked_string(document["aggregate_license"], platform, "aggregate license")
      end
      raise "license inventory license_refs must be an array" unless document["license_refs"].is_a?(Array)
      raise "license inventory sources must be an array" unless document["sources"].is_a?(Array)
      unless document["ruby_gems"].is_a?(Hash) &&
             document["ruby_gems"].keys.sort == %w[remote source_built]
        raise "license inventory ruby_gems must define remote and source_built"
      end
      %w[remote source_built].each do |kind|
        unless document["ruby_gems"][kind].is_a?(Array)
          raise "license inventory ruby_gems #{kind} must be an array"
        end
      end
      require_keys(
        document.fetch("windows_vcpkg"),
        %w[exact_names license name_prefixes],
        "license inventory windows_vcpkg"
      )
      vcpkg = document.fetch("windows_vcpkg")
      checked_string(vcpkg, "license", "license inventory windows_vcpkg")
      %w[exact_names name_prefixes].each do |key|
        checked_string_array(vcpkg, key, "license inventory windows_vcpkg")
      end
      validate_license_refs(document)

      document
    end

    def validate_license_refs(document)
      identifiers = document.fetch("license_refs").map do |reference|
        require_keys(
          reference, %w[description evidence id], "license inventory LicenseRef"
        )
        identifier = checked_string(
          reference, "id", "license inventory LicenseRef",
          /\ALicenseRef-[A-Za-z0-9][A-Za-z0-9.-]*\z/
        )
        checked_string(reference, "description", "license inventory LicenseRef #{identifier}")
        checked_string_array(
          reference, "evidence", "license inventory LicenseRef #{identifier}"
        )
        identifier
      end
      duplicate = identifiers.tally.find { |_identifier, count| count > 1 }&.first
      raise "duplicate license inventory LicenseRef #{duplicate}" if duplicate

      license_expressions = document.fetch("aggregate_license").values +
                            document.fetch("sources").filter_map { |source| source["license"] } +
                            document.fetch("ruby_gems").values.flatten.filter_map do |gem|
                              gem["license"]
                            end +
                            [document.fetch("windows_vcpkg").fetch("license")]
      used = license_expressions.flat_map do |expression|
        expression.to_s.scan(/LicenseRef-[A-Za-z0-9][A-Za-z0-9.-]*/)
      end.uniq.sort
      undefined = used - identifiers
      unless undefined.empty?
        raise "license inventory uses undefined LicenseRef #{undefined.join(', ')}"
      end
      unused = identifiers - used
      unless unused.empty?
        raise "license inventory defines unused LicenseRef #{unused.join(', ')}"
      end
    end

    def source_lock_revisions(document)
      require_keys(document, %w[schema_version sources], "source lock")
      raise "source lock schema_version must be 1" unless document["schema_version"] == 1
      raise "source lock sources must be an array" unless document["sources"].is_a?(Array)

      revisions = {}
      document["sources"].each do |source|
        name = checked_string(source, "name", "source lock entry")
        raise "duplicate source lock entry #{name}" if revisions.key?(name)
        revision = checked_string(
          source, "revision", "source lock entry #{name}", /\A[0-9a-f]{40}\z/
        )
        revisions[name] = revision
      end
      revisions
    end

    def stage_sources(inventory, revisions, platform, source_root, corpus_root)
      names = {}
      inventory.fetch("sources").sort_by { |source| source.fetch("name") }.map do |source|
        require_keys(
          source,
          %w[checkouts license name notices revision source_lock_name],
          "license inventory source"
        )
        name = checked_string(source, "name", "license inventory source")
        raise "duplicate license inventory source #{name}" if names[name]
        names[name] = true
        safe_relative_path(name, "source name")
        lock_name = checked_string(source, "source_lock_name", "license inventory source #{name}")
        revision = checked_string(
          source, "revision", "license inventory source #{name}", /\A[0-9a-f]{40}\z/
        )
        unless revisions[lock_name] == revision
          raise "license inventory source #{name} revision does not match the source lock"
        end
        license = checked_string(source, "license", "license inventory source #{name}")
        checkouts = source.fetch("checkouts")
        unless checkouts.is_a?(Hash) && checkouts.keys.sort == PLATFORMS
          raise "license inventory source #{name} checkouts must define linux and windows"
        end
        checkout_parts = safe_relative_path(
          checkouts.fetch(platform), "license inventory source #{name} #{platform} checkout"
        )
        checkout = File.join(source_root, *checkout_parts)
        raise "source checkout does not exist: #{checkout}" unless File.directory?(checkout)
        notices = source.fetch("notices")
        unless notices.is_a?(Array) && !notices.empty?
          raise "license inventory source #{name} must declare at least one notice"
        end

        staged_notices = notices.sort_by { |notice| notice.fetch("path") }.map do |notice|
          require_keys(notice, %w[path sha256], "license inventory source #{name} notice")
          relative = checked_string(notice, "path", "license inventory source #{name} notice")
          parts = safe_relative_path(relative, "license inventory source #{name} notice path")
          expected_sha = checked_string(
            notice, "sha256", "license inventory source #{name} notice", /\A[0-9a-f]{64}\z/
          )
          source_path = File.join(checkout, *parts)
          raise "declared source notice is missing: #{source_path}" unless File.file?(source_path)
          actual_sha = Digest::SHA256.file(source_path).hexdigest
          unless actual_sha == expected_sha
            raise "source notice digest mismatch for #{name}/#{relative}: " \
                  "expected #{expected_sha}, got #{actual_sha}"
          end
          target = File.join("sources", name, *parts)
          destination = File.join(corpus_root, target)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.copy_file(source_path, destination)
          {
            "path" => relative,
            "corpus_path" => target.tr("\\", "/"),
            "sha256" => actual_sha
          }
        end

        {
          "name" => name,
          "source_lock_name" => lock_name,
          "revision" => revision,
          "license" => license,
          "notices" => staged_notices
        }
      end
    end

    def installed_gems(gem_home)
      specifications = File.join(gem_home, "specifications")
      unless File.directory?(specifications)
        raise "installed Ruby gem specifications do not exist: #{specifications}"
      end

      Dir[File.join(specifications, "*.gemspec")].sort.map do |path|
        specification = Gem::Specification.load(path)
        raise "installed Ruby gem specification is invalid: #{path}" unless specification

        {
          "name" => specification.name,
          "version" => specification.version.to_s,
          "declared_licenses" => specification.licenses,
          "path" => path
        }
      end
    end

    def validate_installed_gems(inventory, gem_home)
      expected_entries = %w[remote source_built].flat_map do |kind|
        inventory.fetch("ruby_gems").fetch(kind).map do |gem|
          {
            "name" => gem.fetch("name"),
            "version" => gem.fetch("version"),
            "declared_licenses" => gem.fetch("declared_licenses")
          }
        end
      end
      expected_ids = expected_entries.map { |gem| [gem.fetch("name"), gem.fetch("version")] }
      duplicates = expected_ids.tally.select { |_gem, count| count > 1 }.keys
      unless duplicates.empty?
        raise "duplicate Ruby gem inventory entry: #{duplicates.first.join('-')}"
      end

      actual_entries = installed_gems(gem_home)
      actual_ids = actual_entries.map { |gem| [gem.fetch("name"), gem.fetch("version")] }
      actual_duplicates = actual_ids.tally.select { |_gem, count| count > 1 }.keys
      unless actual_duplicates.empty?
        raise "duplicate installed Ruby gem specification: #{actual_duplicates.first.join('-')}"
      end
      missing = expected_ids - actual_ids
      unexpected = actual_ids - expected_ids
      details = []
      details << "missing #{missing.map { |gem| gem.join('-') }.join(', ')}" unless missing.empty?
      details << "unexpected #{unexpected.map { |gem| gem.join('-') }.join(', ')}" unless unexpected.empty?
      unless details.empty?
        raise "installed Ruby gem set does not match the license inventory: #{details.join('; ')}"
      end

      expected_by_id = expected_entries.to_h do |gem|
        [[gem.fetch("name"), gem.fetch("version")], gem]
      end
      actual_entries.each do |gem|
        identity = [gem.fetch("name"), gem.fetch("version")]
        expected_licenses = expected_by_id.fetch(identity).fetch("declared_licenses")
        next if gem.fetch("declared_licenses") == expected_licenses

        raise "#{gem.fetch('name')} #{gem.fetch('version')} installed gem declared licenses " \
              "do not match the inventory: expected #{expected_licenses.inspect}, " \
              "got #{gem.fetch('declared_licenses').inspect}"
      end
    end

    def stage_remote_gems(inventory, gem_cache, corpus_root)
      inventory.fetch("ruby_gems").fetch("remote").sort_by do |gem|
        [gem.fetch("name"), gem.fetch("version")]
      end.map do |gem|
        require_keys(
          gem, %w[artifact declared_licenses license name notices sha256 version],
          "remote Ruby gem inventory entry"
        )
        name = checked_string(gem, "name", "remote Ruby gem inventory entry")
        version = checked_string(gem, "version", "remote Ruby gem #{name}")
        safe_relative_path(name, "remote Ruby gem name")
        safe_relative_path(version, "remote Ruby gem #{name} version")
        artifact_name = checked_string(gem, "artifact", "remote Ruby gem #{name}")
        artifact_parts = safe_relative_path(artifact_name, "remote Ruby gem #{name} artifact")
        unless artifact_parts.size == 1
          raise "remote Ruby gem #{name} artifact must be a cache filename"
        end
        expected_sha = checked_string(
          gem, "sha256", "remote Ruby gem #{name}", /\A[0-9a-f]{64}\z/
        )
        artifact = File.join(gem_cache, artifact_name)
        raise "locked Ruby gem artifact is missing: #{artifact}" unless File.file?(artifact)
        actual_sha = Digest::SHA256.file(artifact).hexdigest
        unless actual_sha == expected_sha
          raise "Ruby gem artifact digest mismatch for #{artifact_name}: " \
                "expected #{expected_sha}, got #{actual_sha}"
        end
        package = Gem::Package.new(artifact)
        specification = package.spec
        unless specification.name == name && specification.version.to_s == version
          raise "Ruby gem artifact #{artifact_name} embedded specification does not match " \
                "#{name} #{version}: got #{specification.full_name}"
        end
        license = checked_string(gem, "license", "remote Ruby gem #{name}")
        declared_licenses = checked_string_array(
          gem, "declared_licenses", "remote Ruby gem #{name}"
        )
        unless specification.licenses == declared_licenses
          raise "Ruby gem artifact #{artifact_name} artifact declared licenses do not match " \
                "the inventory: expected #{declared_licenses.inspect}, " \
                "got #{specification.licenses.inspect}"
        end
        notices = gem.fetch("notices")
        unless notices.is_a?(Array) && !notices.empty?
          raise "remote Ruby gem #{name} must declare at least one notice"
        end

        staged_notices = Dir.mktmpdir("orocos-license-gem-") do |extracted|
          notices.sort_by { |notice| notice.fetch("path") }.map do |notice|
            require_keys(notice, %w[path sha256], "remote Ruby gem #{name} notice")
            relative = checked_string(notice, "path", "remote Ruby gem #{name} notice")
            parts = safe_relative_path(relative, "remote Ruby gem #{name} notice path")
            notice_sha = checked_string(
              notice, "sha256", "remote Ruby gem #{name} notice", /\A[0-9a-f]{64}\z/
            )
            package.extract_files(extracted, literal_glob(relative))
            source_path = File.join(extracted, *parts)
            unless File.file?(source_path)
              raise "declared notice #{relative} is missing from #{artifact_name}"
            end
            actual_notice_sha = Digest::SHA256.file(source_path).hexdigest
            unless actual_notice_sha == notice_sha
              raise "Ruby gem notice digest mismatch for #{name}/#{relative}: " \
                    "expected #{notice_sha}, got #{actual_notice_sha}"
            end
            target = File.join("gems", "#{name}-#{version}", *parts)
            destination = File.join(corpus_root, target)
            FileUtils.mkdir_p(File.dirname(destination))
            FileUtils.copy_file(source_path, destination)
            {
              "path" => relative,
              "corpus_path" => target.tr("\\", "/"),
              "sha256" => actual_notice_sha
            }
          end
        end

        {
          "name" => name,
          "version" => version,
          "license" => license,
          "declared_licenses" => declared_licenses,
          "artifact" => artifact_name,
          "artifact_sha256" => actual_sha,
          "notices" => staged_notices
        }
      end
    end

    def source_built_gems(inventory, source_names)
      inventory.fetch("ruby_gems").fetch("source_built").sort_by do |gem|
        [gem.fetch("name"), gem.fetch("version")]
      end.map do |gem|
        require_keys(
          gem, %w[declared_licenses license name source version],
          "source-built Ruby gem inventory entry"
        )
        name = checked_string(gem, "name", "source-built Ruby gem inventory entry")
        version = checked_string(gem, "version", "source-built Ruby gem #{name}")
        source = checked_string(gem, "source", "source-built Ruby gem #{name}")
        unless source_names.include?(source)
          raise "source-built Ruby gem #{name} refers to unknown source #{source}"
        end
        {
          "name" => name,
          "version" => version,
          "source" => source,
          "declared_licenses" => checked_string_array(
            gem, "declared_licenses", "source-built Ruby gem #{name}"
          ),
          "license" => checked_string(gem, "license", "source-built Ruby gem #{name}")
        }
      end
    end

    def stage_windows_vcpkg(inventory, platform, vcpkg_share, corpus_root)
      return [] unless platform == "windows"
      raise "--vcpkg-share is required for a Windows license corpus" unless vcpkg_share

      share = File.expand_path(vcpkg_share)
      raise "vcpkg installed share directory does not exist: #{share}" unless File.directory?(share)
      policy = inventory.fetch("windows_vcpkg")
      exact_names = policy.fetch("exact_names").map(&:downcase)
      prefixes = policy.fetch("name_prefixes").map(&:downcase)
      # vcpkg's share tree also contains CMake aliases and support directories
      # such as boost_algorithm and man. They are not ports and own no notice.
      matches = Dir[File.join(share, "**", "*")].select do |path|
        next false unless File.file?(path)

        basename = File.basename(path).downcase
        exact_names.include?(basename) || prefixes.any? { |prefix| basename.start_with?(prefix) }
      end.sort_by do |path|
        relative_path_parts(share, path, "vcpkg license metadata path").join("/")
      end
      raise "vcpkg installed share directory contains no license metadata" if matches.empty?

      matches.map do |source_path|
        parts = relative_path_parts(share, source_path, "vcpkg license metadata path")
        relative = parts.join("/")
        target = File.join("vcpkg", *parts)
        destination = File.join(corpus_root, target)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.copy_file(source_path, destination)
        {
          "port" => parts.fetch(0),
          "path" => relative,
          "corpus_path" => target.tr("\\", "/"),
          "sha256" => Digest::SHA256.file(source_path).hexdigest
        }
      end
    end

    def write_metadata(
      corpus_root, inventory, platform, sources, remote_gems, built_gems, vcpkg_metadata
    )
      manifest = {
        "schema_version" => 1,
        "platform" => platform,
        "aggregate_license" => inventory.fetch("aggregate_license").fetch(platform),
        "license_refs" => inventory.fetch("license_refs"),
        "sources" => sources,
        "ruby_gems" => { "remote" => remote_gems, "source_built" => built_gems },
        "windows_vcpkg" => vcpkg_metadata
      }
      File.write(File.join(corpus_root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

      lines = [
        "# Orocos/Rock License Corpus",
        "",
        "Aggregate license: `#{manifest.fetch('aggregate_license')}`"
      ]
      unless inventory.fetch("license_refs").empty?
        lines.concat(["", "## LicenseRef Definitions"])
        inventory.fetch("license_refs").sort_by { |reference| reference.fetch("id") }.each do |reference|
          lines.concat([
            "",
            "### #{reference.fetch('id')}",
            "",
            reference.fetch("description"),
            "",
            "Evidence: #{reference.fetch('evidence').join(', ')}"
          ])
        end
      end
      lines.concat([
        "",
        "## Source Components",
        "",
        "| Component | Revision | License | Notice evidence |",
        "|---|---|---|---|"
      ])
      sources.each do |source|
        evidence = source.fetch("notices").map { |notice| notice.fetch("corpus_path") }.join("<br>")
        lines << "| #{source.fetch('name')} | `#{source.fetch('revision')}` | " \
                 "`#{source.fetch('license')}` | #{evidence} |"
      end
      lines.concat([
        "",
        "## Ruby Gems",
        "",
        "| Gem | Origin | License | Notice evidence |",
        "|---|---|---|---|"
      ])
      remote_gems.each do |gem|
        evidence = gem.fetch("notices").map { |notice| notice.fetch("corpus_path") }.join("<br>")
        lines << "| #{gem.fetch('name')} #{gem.fetch('version')} | " \
                 "`#{gem.fetch('artifact')}`; declares " \
                 "#{gem.fetch('declared_licenses').join(', ')} | " \
                 "`#{gem.fetch('license')}` | #{evidence} |"
      end
      built_gems.each do |gem|
        lines << "| #{gem.fetch('name')} #{gem.fetch('version')} | " \
                 "source-built from #{gem.fetch('source')}; declares " \
                 "#{gem.fetch('declared_licenses').join(', ')} | `#{gem.fetch('license')}` | " \
                 "sources/#{gem.fetch('source')} |"
      end
      unless vcpkg_metadata.empty?
        lines.concat([
          "",
          "## Bundled Windows vcpkg Dependencies",
          "",
          "License classification: `#{inventory.fetch('windows_vcpkg').fetch('license')}`",
          "",
          "The exact dynamic notice set is recorded below and in `manifest.json`.",
          "",
          "| Port | Notice evidence | SHA256 |",
          "|---|---|---|"
        ])
        vcpkg_metadata.each do |entry|
          lines << "| #{entry.fetch('port')} | #{entry.fetch('corpus_path')} | " \
                   "`#{entry.fetch('sha256')}` |"
        end
      end
      File.write(File.join(corpus_root, "LICENSES.md"), lines.join("\n") + "\n")
    end

    def replace_corpora(parent, staged_parent)
      names = %w[orocos orocos-dev]
      moved_new = []
      moved_old = []
      begin
        names.each do |name|
          destination = File.join(parent, name)
          next unless File.exist?(destination)

          backup = File.join(staged_parent, "previous-#{name}")
          File.rename(destination, backup)
          moved_old << [backup, destination]
        end
        names.each do |name|
          destination = File.join(parent, name)
          File.rename(File.join(staged_parent, name), destination)
          moved_new << destination
        end
      rescue StandardError
        moved_new.reverse_each { |path| FileUtils.rm_rf(path) }
        moved_old.reverse_each { |backup, destination| File.rename(backup, destination) }
        raise
      end
    end

    def stage(options)
      inventory = validate_inventory(load_json(options.fetch(:inventory), "license inventory"))
      revisions = source_lock_revisions(load_json(options.fetch(:source_lock), "source lock"))
      platform = options.fetch(:platform)
      raise "unsupported license corpus platform: #{platform}" unless PLATFORMS.include?(platform)

      prefix = File.expand_path(options.fetch(:prefix))
      raise "package prefix does not exist: #{prefix}" unless File.directory?(prefix)
      parent = File.join(prefix, "share", "licenses")
      FileUtils.mkdir_p(parent)

      Dir.mktmpdir(".orocos-license-corpus-", parent) do |staged_parent|
        runtime = File.join(staged_parent, "orocos")
        development = File.join(staged_parent, "orocos-dev")
        FileUtils.mkdir_p(runtime)
        sources = stage_sources(
          inventory, revisions, platform, File.expand_path(options.fetch(:source_root)), runtime
        )
        validate_installed_gems(inventory, File.expand_path(options.fetch(:gem_home)))
        remote_gems = stage_remote_gems(
          inventory, File.expand_path(options.fetch(:gem_cache)), runtime
        )
        built_gems = source_built_gems(inventory, sources.map { |source| source.fetch("name") })
        vcpkg_metadata = stage_windows_vcpkg(
          inventory, platform, options[:vcpkg_share], runtime
        )
        write_metadata(
          runtime, inventory, platform, sources, remote_gems, built_gems, vcpkg_metadata
        )
        FileUtils.mkdir_p(development)
        FileUtils.cp_r(Dir.children(runtime).map { |entry| File.join(runtime, entry) }, development)
        replace_corpora(parent, staged_parent)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {}
    parser = OptionParser.new do |arguments|
      arguments.banner = "usage: stage-license-corpus.rb [options]"
      arguments.on("--inventory PATH") { |value| options[:inventory] = value }
      arguments.on("--source-lock PATH") { |value| options[:source_lock] = value }
      arguments.on("--platform PLATFORM") { |value| options[:platform] = value }
      arguments.on("--source-root PATH") { |value| options[:source_root] = value }
      arguments.on("--gem-home PATH") { |value| options[:gem_home] = value }
      arguments.on("--gem-cache PATH") { |value| options[:gem_cache] = value }
      arguments.on("--prefix PATH") { |value| options[:prefix] = value }
      arguments.on("--vcpkg-share PATH") { |value| options[:vcpkg_share] = value }
    end
    parser.parse!
    required = %i[inventory source_lock platform source_root gem_home gem_cache prefix]
    missing = required.reject { |key| options.key?(key) }
    abort "missing options: #{missing.join(', ')}" unless missing.empty?

    OrocosRock::LicenseCorpus.stage(options)
    warn "Staged deterministic #{options.fetch(:platform)} license corpora."
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
