#!/usr/bin/env ruby

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SOURCE_LOCK = File.join(ROOT, "packaging", "source-lock.json")
VALIDATOR = File.join(ROOT, "tools", "linux-source-lock.rb")
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
  "rock-package-set" =>
    ".autoproj/remotes/git_https___github_com_rock_core_package_set_git"
}.freeze

def run_lock(mode, lock_path, root)
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, VALIDATOR, mode, lock_path, root
  )
  ["#{stdout}#{stderr}", status]
end

def run_validation(lock_path)
  run_lock("validate", lock_path, ROOT)
end

def run_git(directory, *arguments)
  output, status = Open3.capture2e("git", "-C", directory, *arguments)
  raise "git #{arguments.join(' ')} failed in #{directory}: #{output}" unless status.success?

  output.strip
end

def build_workspace(root)
  document = JSON.parse(File.read(SOURCE_LOCK))
  sources = document.fetch("sources").to_h { |source| [source.fetch("name"), source] }

  CHECKOUT_PATHS.each do |name, relative_path|
    checkout = File.join(root, relative_path)
    FileUtils.mkdir_p(checkout)
    run_git(checkout, "init", "--quiet")
    File.write(File.join(checkout, "tracked.txt"), "#{name}\n")
    File.write(File.join(checkout, ".gitignore"), "unexpected.txt\n")
    run_git(checkout, "add", "tracked.txt", ".gitignore")
    run_git(
      checkout, "-c", "user.name=Source Lock Test",
      "-c", "user.email=source-lock@example.invalid",
      "commit", "--quiet", "-m", "fixture"
    )
    run_git(checkout, "remote", "add", "origin", sources.fetch(name).fetch("repository"))
    sources.fetch(name)["revision"] = run_git(checkout, "rev-parse", "HEAD")
  end

  lock_path = File.join(root, "source-lock.json")
  File.write(lock_path, "#{JSON.pretty_generate(document)}\n")
  lock_path
end

def with_workspace
  Dir.mktmpdir("orocos-linux-source-lock-") do |root|
    yield root, build_workspace(root)
  end
end

def assert_verify_rejected(label, expected_message)
  with_workspace do |root, lock_path|
    yield root, lock_path
    output, status = run_lock("verify", lock_path, root)
    raise "#{label} was accepted" if status.success?
    unless output.include?(expected_message)
      raise "#{label} failed with #{output.inspect}, expected #{expected_message.inspect}"
    end
  end
end

output, status = run_validation(SOURCE_LOCK)
raise "canonical source lock failed validation: #{output}" unless status.success?
unless output.include?("Validated 14 locked Linux build sources.")
  raise "canonical source lock reported an unexpected source count: #{output.inspect}"
end

mutations = {
  "farbot" => "https://example.invalid/farbot.git",
  "rock-package-set" => "",
  "vcpkg" => "https://example.invalid/vcpkg.git"
}
accepted = []

mutations.each do |name, repository|
  document = JSON.parse(File.read(SOURCE_LOCK))
  source = document.fetch("sources").find { |entry| entry.fetch("name") == name }
  raise "canonical source lock is missing #{name}" unless source

  source["repository"] = repository
  Tempfile.create(["source-lock-#{name}", ".json"]) do |file|
    file.write(JSON.generate(document))
    file.flush
    mutation_output, mutation_status = run_validation(file.path)
    if mutation_status.success?
      accepted << "source lock accepted noncanonical repository for #{name}"
    elsif !mutation_output.include?(name)
      accepted << "source lock rejection did not name #{name}: #{mutation_output.inspect}"
    end
  end
end

document = JSON.parse(File.read(SOURCE_LOCK))
document["unexpected"] = true
Tempfile.create(["source-lock-root-field", ".json"]) do |file|
  file.write(JSON.generate(document))
  file.flush
  mutation_output, mutation_status = run_validation(file.path)
  if mutation_status.success?
    accepted << "source lock accepted an unexpected root field"
  elsif !mutation_output.include?("schema_version and sources")
    accepted << "source lock root-field rejection was unclear: #{mutation_output.inspect}"
  end
end

raise accepted.join("\n") unless accepted.empty?

with_workspace do |root, lock_path|
  build_output = File.join(root, CHECKOUT_PATHS.fetch("farbot"), "build")
  FileUtils.mkdir_p(build_output)
  File.write(File.join(build_output, "CMakeCache.txt"), "generated\n")
  nodeset_cache = File.join(
    root, CHECKOUT_PATHS.fetch("open62541"),
    "tools", "nodeset_compiler", "__pycache__"
  )
  FileUtils.mkdir_p(nodeset_cache)
  File.write(File.join(nodeset_cache, "nodeset.cpython-314.pyc"), "generated\n")
  output, status = run_lock("verify", lock_path, root)
  raise "canonical checkout layout failed verification: #{output}" unless status.success?
  unless output.include?("Verified 14 locked Linux build sources.")
    raise "checkout verification reported an unexpected source count: #{output.inspect}"
  end
end

assert_verify_rejected("missing checkout", "locked source farbot was not checked out") do |root, _lock|
  FileUtils.rm_rf(File.join(root, CHECKOUT_PATHS.fetch("farbot")))
end

assert_verify_rejected("misplaced checkout", "locked source farbot must be checked out at") do |root, _lock|
  source = File.join(root, CHECKOUT_PATHS.fetch("farbot"))
  destination = File.join(root, "misplaced", "farbot")
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.mv(source, destination)
end

assert_verify_rejected("duplicate checkout", "locked source farbot has duplicate checkouts") do |root, _lock|
  source = File.join(root, CHECKOUT_PATHS.fetch("farbot"))
  FileUtils.cp_r(source, File.join(root, "duplicate-farbot"))
end

assert_verify_rejected("wrong revision", "locked source farbot has the wrong revision") do |root, _lock|
  checkout = File.join(root, CHECKOUT_PATHS.fetch("farbot"))
  File.write(File.join(checkout, "tracked.txt"), "new revision\n")
  run_git(checkout, "add", "tracked.txt")
  run_git(
    checkout, "-c", "user.name=Source Lock Test",
    "-c", "user.email=source-lock@example.invalid",
    "commit", "--quiet", "-m", "wrong revision"
  )
end

assert_verify_rejected("tracked dirt", "locked source farbot has tracked changes") do |root, _lock|
  checkout = File.join(root, CHECKOUT_PATHS.fetch("farbot"))
  File.write(File.join(checkout, "tracked.txt"), "dirty\n")
end

assert_verify_rejected(
  "unexpected untracked file", "locked source farbot has unexpected untracked files"
) do |root, _lock|
  checkout = File.join(root, CHECKOUT_PATHS.fetch("farbot"))
  File.write(File.join(checkout, "unexpected.txt"), "not locked\n")
end

puts "Linux source lock tests passed."
