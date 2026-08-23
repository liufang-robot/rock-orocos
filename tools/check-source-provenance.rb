#!/usr/bin/env ruby

require "json"
require "yaml"

module OrocosRock
  module SourceProvenance
    SOURCE_ORGANIZATION = "liufang-robot"

    FIRST_PARTY_REPOSITORIES = {
      "farbot" => "farbot",
      "rtlog-cpp" => "rtlog-cpp",
      "rtt" => "rtt",
      "rtt_opcua" => "rtt_opcua",
      "ocl" => "ocl",
      "utilmm" => "utilmm",
      "typelib" => "tools-typelib",
      "rtt_typelib" => "tools-rtt_typelib",
      "orogen" => "tools-orogen"
    }.transform_values do |repository|
      "https://github.com/#{SOURCE_ORGANIZATION}/#{repository}.git"
    end.freeze

    THIRD_PARTY_REPOSITORIES = {
      "open62541" => "https://github.com/open62541/open62541.git",
      "open62541pp" => "https://github.com/open62541pp/open62541pp.git",
      "utilrb" => "https://github.com/rock-core/tools-utilrb.git",
      "metaruby" => "https://github.com/rock-core/tools-metaruby.git",
      "rock-package-set" => "https://github.com/rock-core/package_set.git",
      "vcpkg" => "https://github.com/microsoft/vcpkg.git"
    }.freeze

    WINDOWS_PARAMETERS = {
      "farbot" => "FarbotRepository",
      "rtlog-cpp" => "RtlogRepository",
      "rtt" => "RttRepository",
      "open62541" => "Open62541Repository",
      "open62541pp" => "Open62541ppRepository",
      "rtt_opcua" => "RttOpcuaRepository",
      "ocl" => "OclRepository",
      "utilmm" => "UtilmmRepository",
      "typelib" => "TypelibRepository",
      "rtt_typelib" => "RttTypelibRepository",
      "utilrb" => "UtilrbRepository",
      "metaruby" => "MetarubyRepository",
      "orogen" => "OrogenRepository",
      "vcpkg" => "VcpkgRepository"
    }.freeze

    AUTOPROJ_SECTIONS = %w[version_control overrides].freeze
    APPROVED_PACKAGE_SETS = [
      {
        "type" => "git",
        "url" => "https://github.com/rock-core/package_set.git"
      }
    ].freeze

    module_function

    def validate(root)
      errors = []
      repositories = FIRST_PARTY_REPOSITORIES.merge(THIRD_PARTY_REPOSITORIES)
      errors.concat(validate_autoproj(root, repositories))
      check_source_lock(root, repositories, errors)
      check_windows_defaults(root, repositories, errors)
      errors
    rescue JSON::ParserError, Psych::SyntaxError, KeyError => e
      ["source provenance input is invalid: #{e.message}"]
    end

    def validate_autoproj(root, repositories = FIRST_PARTY_REPOSITORIES.merge(THIRD_PARTY_REPOSITORIES))
      errors = []
      check_autoproj(root, repositories, errors)
      check_package_set(root, errors)
      errors
    rescue Psych::SyntaxError, KeyError => e
      ["source provenance input is invalid: #{e.message}"]
    end

    def expected_autoproj_sources(repositories)
      {
        "version_control" => {
          "farbot" => { "type" => "git", "url" => repositories.fetch("farbot"), "branch" => "master" },
          "rtlog-cpp" => { "type" => "git", "url" => repositories.fetch("rtlog-cpp"), "branch" => "main" },
          "open62541" => { "type" => "git", "url" => repositories.fetch("open62541"), "tag" => "v1.4.15" },
          "open62541pp" => { "type" => "git", "url" => repositories.fetch("open62541pp"), "tag" => "v0.21.2" },
          "rtt_opcua" => { "type" => "git", "url" => repositories.fetch("rtt_opcua"), "branch" => "dev" }
        },
        "overrides" => {
          "rtt" => { "type" => "git", "url" => repositories.fetch("rtt"), "branch" => "dev" },
          "ocl" => { "type" => "git", "url" => repositories.fetch("ocl"), "branch" => "dev" },
          "orogen" => {
            "type" => "git",
            "url" => repositories.fetch("orogen"),
            "branch" => "dev",
            "commit" => "3346b6ac682ad772b57d07b2386cdaef47e4abbe"
          },
          "typelib" => { "type" => "git", "url" => repositories.fetch("typelib"), "branch" => "dev" },
          "utilmm" => { "type" => "git", "url" => repositories.fetch("utilmm"), "branch" => "dev" },
          "utilrb" => { "type" => "git", "url" => repositories.fetch("utilrb"), "branch" => "master" },
          "tools/metaruby" => {
            "type" => "git",
            "url" => repositories.fetch("metaruby"),
            "branch" => "master"
          },
          "rtt_typelib" => {
            "type" => "git",
            "url" => repositories.fetch("rtt_typelib"),
            "branch" => "dev"
          }
        }
      }
    end

    def check_autoproj(root, repositories, errors)
      selection = YAML.safe_load_file(File.join(root, "autoproj", "overrides.yml"))
      unless selection.is_a?(Hash)
        errors << "autoproj source selection must be a mapping"
        return
      end

      unknown_sections = selection.keys - AUTOPROJ_SECTIONS
      unless unknown_sections.empty?
        errors << "autoproj source selection contains unauthorized section(s): #{unknown_sections.sort.join(', ')}"
      end

      expected_autoproj_sources(repositories).each do |section, expected_sources|
        entries = selection.fetch(section, [])
        unless entries.is_a?(Array)
          errors << "autoproj #{section} must be a list"
          next
        end

        selectors = []
        entries.each_with_index do |entry, index|
          unless entry.is_a?(Hash)
            errors << "autoproj #{section} entry #{index + 1} must be a mapping"
            next
          end

          selector_keys = entry.filter_map { |key, value| key.to_s if value.nil? }
          unless selector_keys.size == 1
            errors << "autoproj #{section} entry #{index + 1} must define exactly one package selector"
            next
          end

          selector = selector_keys.first
          selectors << selector
          unless expected_sources.key?(selector)
            errors << "autoproj #{section} contains unauthorized selector #{selector}"
            next
          end

          actual = entry.reject { |key, _value| key.to_s == selector }
          expected = expected_sources.fetch(selector)
          next if actual == expected

          source_name = selector.delete_prefix("tools/")
          errors << "autoproj source #{source_name}: expected #{expected.inspect}, got #{actual.inspect}"
        end

        selectors.tally.each do |selector, count|
          next unless count > 1

          errors << "autoproj #{section} contains duplicate selector #{selector}"
        end
        (expected_sources.keys - selectors).each do |selector|
          errors << "autoproj #{section} is missing approved selector #{selector}"
        end
      end
    end

    def check_source_lock(root, repositories, errors)
      document = JSON.parse(File.read(File.join(root, "packaging", "source-lock.json")))
      actual = document.fetch("sources").to_h { |source| [source.fetch("name"), source.fetch("repository")] }
      unknown = actual.keys - repositories.keys
      unless unknown.empty?
        errors << "source lock contains unexpected source(s): #{unknown.sort.join(', ')}"
      end
      repositories.each do |package, expected|
        errors << "source lock #{package}: expected #{expected}, got #{actual[package].inspect}" unless actual[package] == expected
      end
    end

    def check_windows_defaults(root, repositories, errors)
      script = File.read(File.join(root, "tools", "build-windows-msvc.ps1"))
      WINDOWS_PARAMETERS.each do |package, parameter|
        expected = repositories.fetch(package)
        token = %([string]$#{parameter} = "#{expected}")
        errors << "Windows default #{parameter}: expected #{expected}" unless script.include?(token)
      end
    end

    def check_package_set(root, errors)
      manifest = YAML.safe_load_file(File.join(root, "autoproj", "manifest"))
      package_sets = manifest.fetch("package_sets")
      return if package_sets == APPROVED_PACKAGE_SETS

      errors << "Autoproj package sets must equal the approved list: expected " \
                "#{APPROVED_PACKAGE_SETS.inspect}, got #{package_sets.inspect}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  errors = OrocosRock::SourceProvenance.validate(root)
  unless errors.empty?
    warn errors.join("\n")
    exit 1
  end
end
