#!/usr/bin/env ruby

require "rubygems"

module OrocosRock
  module LockedRubyGems
    Entry = Struct.new(:name, :version, :filename, keyword_init: true)

    AUTOPROJ = [
      Entry.new(name: "autobuild", version: "1.25.2", filename: "autobuild-1.25.2.gem"),
      Entry.new(name: "backports", version: "3.25.3", filename: "backports-3.25.3.gem"),
      Entry.new(name: "bundler", version: "2.6.9", filename: "bundler-2.6.9.gem"),
      Entry.new(name: "concurrent-ruby", version: "1.3.8", filename: "concurrent-ruby-1.3.8.gem"),
      Entry.new(name: "equatable", version: "0.7.0", filename: "equatable-0.7.0.gem"),
      Entry.new(name: "facets", version: "3.1.0", filename: "facets-3.1.0.gem"),
      Entry.new(name: "ffi", version: "1.17.4", filename: "ffi-1.17.4-x86_64-linux-gnu.gem"),
      Entry.new(name: "necromancer", version: "0.5.1", filename: "necromancer-0.5.1.gem"),
      Entry.new(name: "timeout", version: "0.4.3", filename: "timeout-0.4.3.gem"),
      Entry.new(name: "net-protocol", version: "0.2.2", filename: "net-protocol-0.2.2.gem"),
      Entry.new(name: "net-smtp", version: "0.5.1", filename: "net-smtp-0.5.1.gem"),
      Entry.new(name: "pairing_heap", version: "3.1.1", filename: "pairing_heap-3.1.1.gem"),
      Entry.new(name: "parslet", version: "2.0.0", filename: "parslet-2.0.0.gem"),
      Entry.new(name: "pastel", version: "0.7.4", filename: "pastel-0.7.4.gem"),
      Entry.new(name: "rake", version: "13.4.2", filename: "rake-13.4.2.gem"),
      Entry.new(name: "rb-inotify", version: "0.11.1", filename: "rb-inotify-0.11.1.gem"),
      Entry.new(name: "rexml", version: "3.4.4", filename: "rexml-3.4.4.gem"),
      Entry.new(name: "rgl", version: "0.5.10", filename: "rgl-0.5.10.gem"),
      Entry.new(name: "stream", version: "0.5.6", filename: "stream-0.5.6.gem"),
      Entry.new(name: "thor", version: "1.5.0", filename: "thor-1.5.0.gem"),
      Entry.new(name: "tty-color", version: "0.5.2", filename: "tty-color-0.5.2.gem"),
      Entry.new(name: "tty-cursor", version: "0.7.1", filename: "tty-cursor-0.7.1.gem"),
      Entry.new(name: "tty-prompt", version: "0.21.0", filename: "tty-prompt-0.21.0.gem"),
      Entry.new(name: "tty-reader", version: "0.7.0", filename: "tty-reader-0.7.0.gem"),
      Entry.new(name: "tty-screen", version: "0.8.2", filename: "tty-screen-0.8.2.gem"),
      Entry.new(name: "tty-spinner", version: "0.9.3", filename: "tty-spinner-0.9.3.gem"),
      Entry.new(name: "utilrb", version: "3.2.0", filename: "utilrb-3.2.0.gem"),
      Entry.new(name: "wisper", version: "2.0.1", filename: "wisper-2.0.1.gem"),
      Entry.new(name: "xdg", version: "2.2.5", filename: "xdg-2.2.5.gem"),
      Entry.new(name: "autoproj", version: "2.18.1", filename: "autoproj-2.18.1.gem")
    ].freeze

    module_function

    def artifact_paths(cache)
      raise "Ruby gem cache does not exist: #{cache}" unless File.directory?(cache)

      AUTOPROJ.map do |entry|
        path = File.join(cache, entry.filename)
        raise "required file is missing: #{path}" unless File.file?(path)

        path
      end
    end

    def gemfile
      AUTOPROJ.map { |entry| %(gem "#{entry.name}", "= #{entry.version}") }.join("\n")
    end

    def activate_autoproj!
      entries = AUTOPROJ.to_h { |entry| [entry.name, entry] }
      specifications = entries.to_h do |name, entry|
        requirement = Gem::Requirement.new("= #{entry.version}")
        spec = Gem::Specification.find_all_by_name(name, requirement).first
        raise Gem::LoadError, "missing locked gem #{name} #{entry.version}" unless spec

        [name, spec]
      end

      specifications.each_value do |spec|
        spec.runtime_dependencies.each do |dependency|
          locked = specifications[dependency.name]
          unless locked && dependency.requirement.satisfied_by?(locked.version)
            raise Gem::LoadError,
                  "locked gem #{spec.full_name} has an unlocked dependency: #{dependency}"
          end
        end
      end

      activated = {}
      activate = lambda do |name|
        return if activated[name]

        activated[name] = true
        spec = specifications.fetch(name)
        spec.runtime_dependencies.each { |dependency| activate.call(dependency.name) }
        spec.activate
        loaded = Gem.loaded_specs.fetch(name)
        return if loaded.version == spec.version

        raise Gem::LoadError,
              "activated #{loaded.full_name} instead of locked gem #{spec.full_name}"
      end

      AUTOPROJ.each { |entry| activate.call(entry.name) }
      specifications.fetch("autoproj")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.shift
  case mode
  when "paths"
    puts OrocosRock::LockedRubyGems.artifact_paths(ARGV.fetch(0))
  when "gemfile"
    puts OrocosRock::LockedRubyGems.gemfile
  when "activate"
    OrocosRock::LockedRubyGems.activate_autoproj!
  else
    warn "usage: #{File.basename(__FILE__)} paths CACHE|gemfile|activate"
    exit 2
  end
end
