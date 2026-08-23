#!/usr/bin/env ruby

require "find"
require "open3"
require "optparse"

Options = Struct.new(:prefix, :maximum_version, :readelf, keyword_init: true)

def parse_options
  options = Options.new(maximum_version: "2.17", readelf: "")
  OptionParser.new do |parser|
    parser.on("--prefix PATH") { |value| options.prefix = value }
    parser.on("--maximum-version VERSION") { |value| options.maximum_version = value }
    parser.on("--readelf PATH") { |value| options.readelf = value }
  end.parse!
  abort "--prefix is required" if options.prefix.to_s.empty?
  unless options.maximum_version.match?(/\A\d+(?:\.\d+)+\z/)
    abort "maximum GLIBC version must contain only numeric components"
  end

  options
end

def executable_path(command)
  return command if command.include?(File::SEPARATOR) && File.executable?(command)

  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
    candidate = File.join(directory, command)
    return candidate if File.file?(candidate) && File.executable?(candidate)
  end
  nil
end

def find_readelf(explicit)
  candidates = [explicit, ENV.fetch("READELF", "")]
  build_prefix = ENV.fetch("BUILD_PREFIX", "")
  candidates.concat(Dir[File.join(build_prefix, "bin", "*-readelf")].sort) unless build_prefix.empty?
  candidates << "readelf"
  candidates.reject(&:empty?).each do |candidate|
    resolved = executable_path(candidate)
    return resolved if resolved
  end
  abort "readelf is required for the Linux GLIBC compatibility check"
end

def version_components(version)
  version.split(".").map(&:to_i)
end

def newer_version?(version, maximum)
  width = [version.size, maximum.size].max
  ((version + [0] * width).first(width) <=>
    (maximum + [0] * width).first(width)) == 1
end

options = parse_options
prefix = File.expand_path(options.prefix)
abort "prefix is not a directory: #{prefix}" unless File.directory?(prefix)

readelf = find_readelf(options.readelf)
maximum = version_components(options.maximum_version)
elf_count = 0
versioned_elf_count = 0
offenders = []

Find.find(prefix) do |path|
  status = File.lstat(path)
  next if status.symlink? || !status.file?
  next unless File.binread(path, 4) == "\x7FELF".b

  elf_count += 1
  output, command_status = Open3.capture2e(readelf, "--wide", "--version-info", path)
  abort "readelf failed for #{path}:\n#{output}" unless command_status.success?

  versions = output.scan(/\bGLIBC_(\d+(?:\.\d+)+)\b/).flatten.uniq
  versioned_elf_count += 1 unless versions.empty?
  versions.each do |version|
    offenders << [path, version] if newer_version?(version_components(version), maximum)
  end
end

abort "no ELF files found below #{prefix}" if elf_count.zero?
if offenders.any?
  details = offenders.sort.map do |path, version|
    "#{path.delete_prefix("#{prefix}/")}: requires GLIBC_#{version}"
  end
  abort "Linux package exceeds the GLIBC_#{options.maximum_version} baseline:\n#{details.join("\n")}"
end

puts "Checked #{elf_count} ELF files (#{versioned_elf_count} with GLIBC versions); " \
     "none require newer than GLIBC_#{options.maximum_version}."
