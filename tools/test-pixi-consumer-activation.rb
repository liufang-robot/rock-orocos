#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
EXAMPLE = File.join(ROOT, "examples", "pixi-consumer")
MANIFEST = File.join(EXAMPLE, "pixi.toml")
UNIX_SCRIPT = File.join(EXAMPLE, "scripts", "activate-orocos.sh")
WINDOWS_SCRIPT = File.join(EXAMPLE, "scripts", "activate-orocos.ps1")

def assert(condition, message)
  raise message unless condition
end

def activate(prefix)
  command = '. "$1"; activation_status=$?; printf "%s" "${OROCOS_ACTIVATION_TEST:-}"; exit "$activation_status"'
  Open3.capture3(
    { "CONDA_PREFIX" => prefix },
    "bash",
    "-c",
    command,
    "activation-test",
    UNIX_SCRIPT
  )
end

[MANIFEST, UNIX_SCRIPT, WINDOWS_SCRIPT].each do |path|
  assert(File.file?(path), "missing consumer activation file: #{path}")
end

manifest = File.read(MANIFEST)
[
  'channels = ["https://prefix.dev/liufang-robot/orocos", "conda-forge"]',
  'orocos-dev = "==0.1.0"',
  "[target.unix.activation]",
  'scripts = ["scripts/activate-orocos.sh"]',
  "[target.win.activation]",
  'scripts = ["scripts/activate-orocos.ps1"]'
].each do |token|
  assert(manifest.include?(token), "missing Pixi consumer contract token: #{token}")
end

Dir.mktmpdir("orocos-consumer-activation") do |directory|
  runtime_prefix = File.join(directory, "runtime prefix")
  FileUtils.mkdir_p(runtime_prefix)
  File.write(File.join(runtime_prefix, "env.sh"), "export OROCOS_ACTIVATION_TEST=runtime\n")

  stdout, stderr, status = activate(runtime_prefix)
  assert(status.success?, "runtime activation failed: #{stderr}")
  assert(stdout == "runtime", "runtime activation selected the wrong environment: #{stdout.inspect}")

  development_prefix = File.join(directory, "development prefix")
  FileUtils.mkdir_p(development_prefix)
  File.write(File.join(development_prefix, "env.sh"), "export OROCOS_ACTIVATION_TEST=runtime\n")
  File.write(File.join(development_prefix, "dev-env.sh"), "export OROCOS_ACTIVATION_TEST=development\n")

  stdout, stderr, status = activate(development_prefix)
  assert(status.success?, "development activation failed: #{stderr}")
  assert(stdout == "development", "development activation did not prefer dev-env.sh: #{stdout.inspect}")

  empty_prefix = File.join(directory, "empty prefix")
  FileUtils.mkdir_p(empty_prefix)

  _stdout, stderr, status = activate(empty_prefix)
  assert(!status.success?, "activation unexpectedly succeeded for an empty prefix")
  assert(
    stderr.include?("does not contain an Orocos package"),
    "empty-prefix failure did not explain the missing Orocos package: #{stderr.inspect}"
  )
end

_stdout, stderr, status = activate(nil)
assert(!status.success?, "activation unexpectedly succeeded without CONDA_PREFIX")
assert(
  stderr.include?("CONDA_PREFIX is not set"),
  "missing-CONDA_PREFIX failure did not explain the problem: #{stderr.inspect}"
)

windows_script = File.read(WINDOWS_SCRIPT)
[
  '$env:CONDA_PREFIX',
  '"Library"',
  '"dev-env.ps1"',
  '"env.ps1"',
  "CONDA_PREFIX is not set",
  "does not contain an Orocos package"
].each do |token|
  assert(windows_script.include?(token), "missing PowerShell selector contract token: #{token}")
end

puts "Pixi consumer activation regression checks passed."
