#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "set"
require "tmpdir"

ARCHIVE_INSPECTOR = File.join(__dir__, "inspect-conda-archive.py")

Options = Struct.new(
  :mode, :package_directory, :release_directory, :source_lock, :channel,
  :repository_commit, :expected_tag, :expected_repository_commit,
  keyword_init: true
)

def parse_options
  options = Options.new(
    mode: "verify",
    package_directory: "packaging/conda/output/linux-64",
    release_directory: "packaging/conda/output/linux-release",
    source_lock: "packaging/source-lock.json",
    channel: "liufang-robot/orocos",
    repository_commit: "",
    expected_tag: "",
    expected_repository_commit: ""
  )
  OptionParser.new do |parser|
    parser.on("--mode MODE", %w[stage verify]) { |value| options.mode = value }
    parser.on("--package-directory PATH") { |value| options.package_directory = value }
    parser.on("--release-directory PATH") { |value| options.release_directory = value }
    parser.on("--source-lock PATH") { |value| options.source_lock = value }
    parser.on("--channel CHANNEL") { |value| options.channel = value }
    parser.on("--repository-commit SHA") { |value| options.repository_commit = value }
    parser.on("--expected-tag TAG") { |value| options.expected_tag = value }
    parser.on("--expected-repository-commit SHA") do |value|
      options.expected_repository_commit = value
    end
  end.parse!
  options
end

def require_file(path)
  absolute = File.expand_path(path)
  raise "required file does not exist: #{absolute}" unless File.file?(absolute)

  absolute
end

def require_directory(path)
  absolute = File.expand_path(path)
  raise "required directory does not exist: #{absolute}" unless File.directory?(absolute)

  absolute
end

def inspect_package(path)
  output, status = Open3.capture2e(
    "rattler-build", "package", "inspect", path, "--all", "--json"
  )
  raise "rattler-build could not inspect #{path}: #{output}" unless status.success?

  JSON.parse(output)
rescue JSON::ParserError => e
  raise "rattler-build returned invalid JSON for #{path}: #{e.message}"
end

def inspect_archive(path)
  output, status = Open3.capture2e("python3", ARCHIVE_INSPECTOR, path)
  raise "independent archive validation failed for #{path}: #{output}" unless status.success?

  JSON.parse(output)
rescue JSON::ParserError => e
  raise "archive inspector returned invalid JSON for #{path}: #{e.message}"
end

def package_records(directory)
  files = Dir[File.join(directory, "*.conda")].sort
  unless files.size == 2
    raise "expected exactly two .conda files in #{directory}, found #{files.size}"
  end

  files.map do |path|
    archive = inspect_archive(path)
    metadata = inspect_package(path)
    archive_paths = archive.fetch("paths")
    inspected_paths = metadata.fetch("paths").fetch("paths").map do |entry|
      { "path" => entry.fetch("_path"), "type" => entry.fetch("path_type") }
    end.sort_by { |entry| [entry.fetch("path"), entry.fetch("type")] }
    unless archive_paths == inspected_paths
      raise "rattler-build path metadata does not match package payload for #{path}"
    end
    {
      path: path,
      filename: File.basename(path),
      bytes: File.size(path),
      sha256: Digest::SHA256.file(path).hexdigest,
      metadata: metadata,
      paths: archive_paths.map { |entry| entry.fetch("path") }
    }
  end
end

def validate_package_set(records)
  names = records.map { |record| record.fetch(:metadata).fetch("index").fetch("name") }
  raise "release package names must be orocos and orocos-dev" unless names.sort == %w[orocos orocos-dev]

  by_name = records.to_h do |record|
    index = record.fetch(:metadata).fetch("index")
    name = index.fetch("name")
    unless index.fetch("subdir") == "linux-64"
      raise "#{record.fetch(:filename)} targets #{index.fetch('subdir')}, expected linux-64"
    end

    expected_filename = "#{name}-#{index.fetch('version')}-#{index.fetch('build')}.conda"
    unless record.fetch(:filename) == expected_filename
      raise "#{record.fetch(:filename)} does not match #{expected_filename}"
    end

    about = record.fetch(:metadata).fetch("about", {})
    %w[summary description].each do |field|
      raise "#{name} package metadata is missing #{field}" if about.fetch(field, "").strip.empty?
    end
    [name, record]
  end

  runtime = by_name.fetch("orocos")
  development = by_name.fetch("orocos-dev")
  runtime_index = runtime.fetch(:metadata).fetch("index")
  development_index = development.fetch(:metadata).fetch("index")
  [runtime_index, development_index].each do |index|
    unless index.fetch("depends").include?("__glibc >=2.17")
      raise "#{index.fetch('name')} must declare the Linux GLIBC 2.17 baseline"
    end
  end
  version = runtime_index.fetch("version")
  unless development_index.fetch("version") == version
    raise "runtime and development package versions do not match"
  end

  runtime_spec = "orocos ==#{version} #{runtime_index.fetch('build')}"
  unless development_index.fetch("depends").include?(runtime_spec)
    raise "orocos-dev must depend on the exact runtime build #{runtime_spec.inspect}"
  end

  overlap = runtime.fetch(:paths).to_set & development.fetch(:paths).to_set
  unless overlap.empty?
    raise "runtime and development packages overlap at #{overlap.size} paths"
  end

  {
    by_name: by_name, runtime: runtime, development: development, version: version
  }
end

def validate_repodata(directory, records)
  repodata_path = require_file(File.join(directory, "repodata.json"))
  packages = JSON.parse(File.read(repodata_path)).fetch("packages.conda")
  records.each do |record|
    entry = packages.fetch(record.fetch(:filename))
    unless entry.fetch("sha256") == record.fetch(:sha256)
      raise "repodata has a stale SHA256 for #{record.fetch(:filename)}"
    end
    unless entry.fetch("size") == record.fetch(:bytes)
      raise "repodata has a stale size for #{record.fetch(:filename)}"
    end
  end
end

def manifest_package(record)
  index = record.fetch(:metadata).fetch("index")
  {
    "name" => index.fetch("name"),
    "version" => index.fetch("version"),
    "build" => index.fetch("build"),
    "build_number" => index.fetch("build_number"),
    "subdir" => index.fetch("subdir"),
    "filename" => record.fetch(:filename),
    "bytes" => record.fetch(:bytes),
    "sha256" => record.fetch(:sha256),
    "paths" => record.fetch(:paths).size,
    "depends" => index.fetch("depends")
  }
end

def expected_checksum_lines(manifest)
  lines = manifest.fetch("packages").sort_by { |entry| entry.fetch("filename") }.map do |entry|
    "#{entry.fetch('sha256')}  #{entry.fetch('filename')}"
  end
  lines << "#{manifest.fetch('source_lock').fetch('sha256')}  source-lock.json"
end

def verify_bundle(directory, source_lock, channel, tag: "", commit: "")
  manifest_path = require_file(File.join(directory, "release-manifest.json"))
  manifest = JSON.parse(File.read(manifest_path))
  raise "release manifest schema_version must be 1" unless manifest.fetch("schema_version") == 1
  raise "release manifest channel does not match #{channel}" unless manifest.fetch("channel") == channel
  unless manifest.fetch("target_platform") == "linux-64"
    raise "release manifest target must be linux-64"
  end
  raise "Prefix channel references must not contain @" if channel.include?("@")
  if !tag.empty? && tag != "v#{manifest.fetch('version')}"
    raise "release tag #{tag} must match v#{manifest.fetch('version')}"
  end
  if !commit.empty? && manifest.fetch("repository_commit") != commit
    raise "release commit does not match #{commit}"
  end

  repository_commit = manifest.fetch("repository_commit")
  unless repository_commit.empty? ||
         repository_commit.match?(/\A[0-9a-f]{40}\z/)
    raise "release manifest repository_commit must be a lowercase 40-character SHA"
  end

  bundled_lock = require_file(File.join(directory, "source-lock.json"))
  expected_lock_hash = Digest::SHA256.file(source_lock).hexdigest
  bundled_lock_hash = Digest::SHA256.file(bundled_lock).hexdigest
  unless bundled_lock_hash == expected_lock_hash
    raise "bundled source lock does not match the release commit"
  end
  unless manifest.fetch("source_lock") == {
    "filename" => "source-lock.json", "sha256" => bundled_lock_hash
  }
    raise "release manifest source-lock checksum is wrong"
  end

  records = package_records(directory)
  package_set = validate_package_set(records)
  unless manifest.fetch("version") == package_set.fetch(:version)
    raise "release manifest version does not match package metadata"
  end
  expected_packages = records.map do |record|
    manifest_package(record)
  end.sort_by { |entry| entry.fetch("name") }
  unless manifest.fetch("packages") == expected_packages
    raise "release manifest package metadata does not match artifacts"
  end

  checksums_path = require_file(File.join(directory, "SHA256SUMS.txt"))
  checksums = File.readlines(checksums_path, chomp: true)
  unless checksums == expected_checksum_lines(manifest)
    raise "SHA256SUMS.txt does not match the release bundle"
  end

  warn "Verified Linux release #{manifest.fetch('version')}: " \
       "#{package_set.fetch(:runtime).fetch(:paths).size} runtime files, " \
       "#{package_set.fetch(:development).fetch(:paths).size} development files."
  manifest
end

def stage_bundle(options, source_lock)
  unless options.repository_commit.empty? ||
         options.repository_commit.match?(/\A[0-9a-f]{40}\z/)
    raise "repository commit must be a lowercase 40-character SHA"
  end

  package_directory = require_directory(options.package_directory)
  records = package_records(package_directory)
  package_set = validate_package_set(records)
  validate_repodata(package_directory, records)

  release_directory = File.expand_path(options.release_directory)
  if File.exist?(release_directory)
    unless File.directory?(release_directory)
      raise "release path is not a directory: #{release_directory}"
    end
    unless Dir.empty?(release_directory)
      raise "release directory must be empty: #{release_directory}"
    end
  end

  parent_directory = File.dirname(release_directory)
  FileUtils.mkdir_p(parent_directory)
  temporary_directory = Dir.mktmpdir(
    ".#{File.basename(release_directory)}.staging-", parent_directory
  )
  begin
    records.each { |record| FileUtils.cp(record.fetch(:path), temporary_directory) }
    FileUtils.cp(source_lock, File.join(temporary_directory, "source-lock.json"))
    source_lock_hash = Digest::SHA256.file(source_lock).hexdigest
    manifest = {
      "schema_version" => 1,
      "channel" => options.channel,
      "target_platform" => "linux-64",
      "version" => package_set.fetch(:version),
      "repository_commit" => options.repository_commit,
      "source_lock" => {
        "filename" => "source-lock.json", "sha256" => source_lock_hash
      },
      "packages" => records.map do |record|
        manifest_package(record)
      end.sort_by { |entry| entry.fetch("name") }
    }
    manifest_path = File.join(temporary_directory, "release-manifest.json")
    File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
    checksums_path = File.join(temporary_directory, "SHA256SUMS.txt")
    File.write(
      checksums_path, "#{expected_checksum_lines(manifest).join("\n")}\n"
    )

    verify_bundle(
      temporary_directory, source_lock, options.channel,
      commit: options.repository_commit
    )
    Dir.rmdir(release_directory) if File.directory?(release_directory)
    File.rename(temporary_directory, release_directory)
    temporary_directory = nil
  ensure
    FileUtils.remove_entry(temporary_directory) if temporary_directory && File.exist?(temporary_directory)
  end
  warn "Prepared Linux release bundle at #{release_directory}"
end

options = parse_options
unless system("rattler-build", "--version", out: File::NULL)
  abort "rattler-build is required; run through the Pixi package environment"
end
source_lock = require_file(options.source_lock)
if options.mode == "stage"
  stage_bundle(options, source_lock)
else
  verify_bundle(
    require_directory(options.release_directory), source_lock, options.channel,
    tag: options.expected_tag, commit: options.expected_repository_commit
  )
end
