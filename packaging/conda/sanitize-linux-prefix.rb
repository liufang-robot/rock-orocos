#!/usr/bin/env ruby

require "fileutils"
require "optparse"

options = {}
OptionParser.new do |parser|
  parser.on("--prefix PATH") { |value| options[:prefix] = value }
  parser.on("--build-prefix PATH") { |value| options[:build_prefix] = value }
  parser.on("--repository-root PATH") { |value| options[:repository_root] = value }
  parser.on("--temporary-home PATH") { |value| options[:temporary_home] = value }
end.parse!

required = %i[prefix build_prefix repository_root temporary_home]
missing = required.reject { |name| options.key?(name) }
raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?

paths = options.transform_values { |path| File.realpath(path) }
prefix = paths.fetch(:prefix)
build_prefix = paths.fetch(:build_prefix)
repository_root = paths.fetch(:repository_root)
temporary_home = paths.fetch(:temporary_home)
toolchain = File.join(prefix, "toolchain")
raise "missing installed toolchain directory: #{toolchain}" unless File.directory?(toolchain)

FileUtils.rm_rf(File.join(toolchain, "gems", "cache"))
FileUtils.rm_rf(File.join(toolchain, "log"))

owned_files = [File.join(prefix, "env.sh"), File.join(prefix, "dev-env.sh")]
owned_files.concat(
  Dir.glob(File.join(toolchain, "**", "*"), File::FNM_DOTMATCH)
     .select { |path| File.file?(path) }
)

sysroots = Dir.glob(File.join(build_prefix, "*", "sysroot")).select do |path|
  File.directory?(path)
end

owned_files.each do |path|
  contents = File.binread(path)
  next if contents.include?("\0")

  updated = contents.gsub(
    /^#!#{Regexp.escape(File.join(build_prefix, "bin", "ruby"))}$/,
    "#!/usr/bin/env ruby"
  )
  sysroots.each do |sysroot|
    include_dir = File.join(sysroot, "usr", "include")
    library_dir = File.join(sysroot, "usr", "lib")
    updated.gsub!(";#{include_dir}", "")
    updated.gsub!("-I#{include_dir}", "")
    updated.gsub!(" -L#{library_dir}", "")
    %w[libpthread.a libpthread.so].each do |library|
      updated.gsub!(File.join(library_dir, library), "pthread")
    end
  end
  updated.gsub!(
    %r{uri="file://#{Regexp.escape(repository_root)}/[^"]*/orocos\.ent"},
    'uri="orocos.ent"'
  )
  File.binwrite(path, updated) if updated != contents
end

forbidden_paths = [build_prefix, temporary_home, repository_root]
owned_files.each do |path|
  contents = File.binread(path)
  next if contents.include?("\0")

  residual = contents.gsub(prefix, "")
  forbidden = forbidden_paths.find { |candidate| residual.include?(candidate) }
  next unless forbidden

  raise "installed text file contains disposable path #{forbidden}: #{path}"
end

warn "Sanitized #{owned_files.size} Linux Orocos package files."
