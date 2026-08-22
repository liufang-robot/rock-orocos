#!/usr/bin/env ruby

require "yaml"

ACTION_PINS = {
  "actions/checkout" => "d23441a48e516b6c34aea4fa41551a30e30af803",
  "prefix-dev/setup-pixi" => "f00437f565399d418b0acc85936d12c1fb668347",
  "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact" => "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
}.freeze

ACTION_COUNTS = {
  "actions/checkout" => 2,
  "prefix-dev/setup-pixi" => 2,
  "actions/upload-artifact" => 2,
  "actions/download-artifact" => 1
}.freeze

def normalize(value)
  value.to_s.gsub(/\s+/, " ").strip
end

def pinned_action(name)
  "#{name}@#{ACTION_PINS.fetch(name)}"
end

def check_release_checkout(steps, name, errors)
  checkout = steps[0] || {}
  unless checkout["uses"] == pinned_action("actions/checkout") &&
         checkout.fetch("with", {}) == {
           "ref" => "$" + "{{ github.sha }}",
           "fetch-depth" => 0,
           "persist-credentials" => false
         }
    errors << "#{name} checkout must use the event SHA, full history, and no credentials"
  end

  ancestry = steps[1] || {}
  unless ancestry["name"] == "Verify release commit is reachable from main" &&
         ancestry["if"] == "github.event_name == 'release'" &&
         ancestry["shell"] == "bash" &&
         ancestry["run"].to_s.include?("git fetch --no-tags --prune --no-recurse-submodules") &&
         ancestry["run"].to_s.include?('git merge-base --is-ancestor "$GITHUB_SHA" "$protected_main_ref"')
    errors << "#{name} must fail closed against freshly fetched protected main"
  end
end

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github", "workflows", "linux-packages.yml")
recipe_path = File.join(root, "packaging", "conda", "recipe-linux.yaml")
build_path = File.join(root, "packaging", "conda", "build-linux.sh")
sanitizer_path = File.join(root, "packaging", "conda", "sanitize-linux-prefix.rb")
development_test_path = File.join(root, "packaging", "conda", "test-dev-linux.sh")
release_path = File.join(root, "tools", "prepare-linux-conda-release.rb")
consumer_path = File.join(root, "tools", "test-linux-conda-consumer.sh")
errors = []

if !File.file?(workflow_path)
  errors << "missing .github/workflows/linux-packages.yml"
else
  contents = File.read(workflow_path)
  workflow = YAML.safe_load(contents, aliases: true)
  triggers = workflow["on"] || workflow[true] || {}
  jobs = workflow.fetch("jobs", {})
  unless jobs.keys.sort == %w[build-packages publish-packages]
    errors << "Linux package CI must define exactly build-packages and publish-packages"
  end

  pull_request = triggers.fetch("pull_request", {}) || {}
  push = triggers.fetch("push", {}) || {}
  release = triggers.fetch("release", {}) || {}
  errors << "Linux package CI must run on pull requests" unless triggers.key?("pull_request")
  errors << "Linux package CI pushes must be limited to main" unless Array(push["branches"]) == ["main"]
  errors << "Linux package CI must support manual dispatch" unless triggers.key?("workflow_dispatch")
  unless Array(release["types"]) == ["published"]
    errors << "Linux package CI must publish only from a published GitHub Release"
  end

  required_paths = %w[
    .github/workflows/linux-packages.yml
    autoproj/**
    examples/pixi-consumer/**
    packaging/**
    tools/**
    pixi.toml
    pixi.lock
  ]
  {
    "pull requests" => Array(pull_request["paths"]),
    "main pushes" => Array(push["paths"])
  }.each do |trigger_name, paths|
    required_paths.each do |path|
      errors << "Linux package CI #{trigger_name} must watch #{path}" unless paths.include?(path)
    end
  end

  unless workflow.fetch("permissions", {}) == { "contents" => "read" }
    errors << "Linux package CI top-level permissions must be contents: read only"
  end
  unless workflow.dig("env", "PREFIX_CHANNEL") == "liufang-robot/orocos" &&
         workflow.dig("env", "PUBLIC_CHANNEL_URL") == "https://prefix.dev/liufang-robot/orocos"
    errors << "Linux package CI must use the canonical Prefix channel"
  end

  build = jobs.fetch("build-packages", {})
  publish = jobs.fetch("publish-packages", {})
  expected_guard = "github.event.action == 'published' && " \
                   "github.event.release.prerelease == false && " \
                   "github.repository == 'liufang-robot/rock-orocos'"
  unless normalize(build["if"]) == "github.event_name != 'release' || (#{expected_guard})"
    errors << "Linux package build must reject unauthorized release events exactly"
  end
  unless normalize(publish["if"]) == "github.event_name == 'release' && #{expected_guard}"
    errors << "Linux Prefix publication must require the canonical release event exactly"
  end
  unless build["runs-on"] == "ubuntu-24.04" && build["timeout-minutes"].to_i >= 180
    errors << "Linux package build must use ubuntu-24.04 with a release-sized timeout"
  end
  errors << "Linux Prefix publication must depend on the verified build" unless publish["needs"] == "build-packages"
  unless publish.fetch("permissions", {}) == {
    "contents" => "read", "id-token" => "write"
  }
    errors << "Linux Prefix publication must grant only contents: read and id-token: write"
  end
  unless contents.scan(/^\s+id-token:\s+write\s*$/).size == 1
    errors << "Linux Prefix OIDC permission must exist only in the publish job"
  end

  build_steps = Array(build["steps"])
  publish_steps = Array(publish["steps"])
  check_release_checkout(build_steps, "Linux package build", errors)
  check_release_checkout(publish_steps, "Linux Prefix publication", errors)
  build_runs = build_steps.filter_map { |step| step["run"] }.join("\n")
  publish_runs = publish_steps.filter_map { |step| step["run"] }.join("\n")
  all_runs = "#{build_runs}\n#{publish_runs}"

  {
    "locked Pixi setup" => "environments: package",
    "source-lock validation" => "tools/linux-source-lock.rb validate",
    "recipe render" => "pixi run --locked linux-package-render",
    "package build and tests" => "pixi run --locked linux-package-build",
    "release staging" => "tools/prepare-linux-conda-release.rb",
    "local consumer test" => "--local-channel packaging/conda/output"
  }.each do |contract, token|
    errors << "Linux package build is missing #{contract}" unless contents.include?(token)
  end

  unless publish_runs.include?("rattler-build upload prefix") &&
         publish_runs.include?('--channel "$PREFIX_CHANNEL"') &&
         publish_runs.include?('--channel-url "$PUBLIC_CHANNEL_URL"')
    errors << "Linux Prefix publication must upload and test the canonical public channel"
  end
  if publish_runs.include?("--force") || publish_runs.include?("--skip-existing")
    errors << "Linux Prefix publication must not replace or skip immutable package filenames"
  end
  if contents.include?("PREFIX_API_KEY") || contents.match?(/secrets\./)
    errors << "Linux Prefix publication must use OIDC instead of stored secrets"
  end
  if all_runs.include?("$" + "{{")
    errors << "Linux package CI must pass event values through environment variables"
  end

  uses = jobs.values.flat_map do |job|
    Array(job["steps"]).filter_map { |step| step["uses"] }
  end
  expected_uses = ACTION_COUNTS.to_h do |action, count|
    [pinned_action(action), count]
  end
  unless uses.tally == expected_uses
    errors << "Linux package CI actions must equal the approved full-SHA selections"
  end
end

if !File.file?(build_path)
  errors << "missing packaging/conda/build-linux.sh"
elsif !File.read(build_path).include?('export OROCOS_ROCK_BUILD_TOOLS_PREFIX="$BUILD_PREFIX"')
  errors << "Linux build must expose Rattler build tools to the isolated Autoproj environment"
elsif !File.read(build_path).include?('export OROCOS_ROCK_DEPENDENCY_PREFIX="$PREFIX"')
  errors << "Linux build must expose Rattler host dependencies to the isolated Autoproj environment"
elsif !File.read(build_path).include?('"$PREFIX" "$BUILD_PREFIX" "$repository_root" "$temporary_home"')
  errors << "Linux build must sanitize package-owned files against all disposable prefixes"
end

errors << "missing packaging/conda/sanitize-linux-prefix.rb" unless File.file?(sanitizer_path)

if !File.file?(recipe_path)
  errors << "missing packaging/conda/recipe-linux.yaml"
else
  recipe_contents = File.read(recipe_path)
  recipe = YAML.safe_load(recipe_contents, aliases: true)
  package_outputs = Array(recipe["outputs"]).filter_map do |output|
    name = output.dig("package", "name")
    [name, output] if name
  end.to_h

  %w[orocos orocos-dev].each do |name|
    errors << "Linux recipe must define #{name}" unless package_outputs.key?(name)
  end

  python_requirement = "python >=3.11,<3.15"
  runtime_requirements = Array(package_outputs.dig("orocos", "requirements", "run"))
  runtime_python_requirements = runtime_requirements.grep(/\Apython(?:\s|[<>=!~]|\z)/)
  unless runtime_python_requirements.empty?
    errors << "Linux orocos runtime requirements must not include Python"
  end

  development_requirements = Array(package_outputs.dig("orocos-dev", "requirements", "run"))
  development_python_requirements = development_requirements.grep(/\Apython(?:\s|[<>=!~]|\z)/)
  unless development_python_requirements == [python_requirement]
    errors << "Linux orocos-dev must require exactly #{python_requirement}"
  end

  {
    "linux-64 source build" => "build-linux.sh",
    "prefix sanitizer" => "sanitize-linux-prefix.rb",
    "compatible Boost SDK constraint" => "boost-cpp >=1.84,<1.85",
    "compatible Boost runtime constraint" => "libboost >=1.84,<1.85",
    "exact runtime dependency" => "pin_subpackage('orocos', exact=True)",
    "runtime description" => "A relocatable Linux Orocos runtime",
    "development description" => "Headers, CMake and pkg-config metadata",
    "runtime Ruby exclusion" => "toolchain/lib/ruby/3.4.0/x86_64-linux/typelib_ruby.so",
    "published documentation" => "https://liufang-robot.github.io/rock-orocos/"
  }.each do |contract, token|
    errors << "Linux recipe is missing #{contract}" unless recipe_contents.include?(token)
  end
end

if !File.file?(development_test_path)
  errors << "missing packaging/conda/test-dev-linux.sh"
else
  development_test_lines = File.readlines(development_test_path).map(&:strip)
  {
    "installed open62541 generator" =>
      'status_code_generator="$PREFIX/toolchain/share/open62541/generate_statuscode_descriptions.py"',
    "installed open62541 status-code schema" =>
      'status_code_csv="$PREFIX/toolchain/share/open62541/schema/StatusCode.csv"',
    "temporary open62541 generator directory" =>
      'temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/orocos-open62541-generator.XXXXXX")"',
    "safe temporary-directory cleanup" => 'rm -rf -- "$temporary_directory"',
    "temporary-directory cleanup function" => "cleanup() {",
    "temporary-directory EXIT trap" => "trap cleanup EXIT",
    "temporary generator output base" =>
      'status_code_output="$temporary_directory/statuscode_descriptions"',
    "prefix Python generator execution" =>
      '"$PREFIX/bin/python" "$status_code_generator" "$status_code_csv" "$status_code_output"',
    "generated C source path" => 'generated_c="${status_code_output}.c"',
    "generated C header path" => 'generated_h="${status_code_output}.h"',
    "nonempty generated C source" => '[ -s "$generated_c" ]',
    "nonempty generated C header" => '[ -s "$generated_h" ]',
    "generated status-code function" => 'grep -q "UA_StatusCode_name" "$generated_c"',
    "generated status-code constant" =>
      'grep -q "UA_STATUSCODE_BADUNEXPECTEDERROR" "$generated_h"'
  }.each do |contract, line|
    unless development_test_lines.include?(line)
      errors << "Linux development package test is missing #{contract}"
    end
  end
end

if !File.file?(release_path)
  errors << "missing tools/prepare-linux-conda-release.rb"
else
  release = File.read(release_path)
  %w[linux-64 SHA256SUMS.txt source-lock.json release-manifest.json].each do |token|
    errors << "Linux release staging must enforce #{token}" unless release.include?(token)
  end
  errors << "Linux release staging must not publish packages" if release.include?("upload prefix")
end

if !File.file?(consumer_path)
  errors << "missing tools/test-linux-conda-consumer.sh"
else
  consumer = File.read(consumer_path)
  %w[
    --force-reinstall
    dev-env.sh
    orogen
    typegen
    deployer-opcua-gnulinux
    TYPELIB_PLUGIN_PATH
    OROCOS_PIXI_ACTIVATION_SCRIPT
    activate-orocos.sh
  ].each do |token|
    errors << "Linux consumer test must check #{token}" unless consumer.include?(token)
  end

  activation_sources = consumer.scan(
    /^[ \t]*\.[ \t]+"\$OROCOS_PIXI_ACTIVATION_SCRIPT"[ \t]*$/
  )
  unless activation_sources.size == 2
    errors << "Linux consumer test must source the shared Pixi activation wrapper exactly twice"
  end

  activation_export =
    'export OROCOS_PIXI_ACTIVATION_SCRIPT="$repository_root/examples/pixi-consumer/scripts/activate-orocos.sh"'
  unless consumer.lines.any? { |line| line.strip == activation_export }
    errors << "Linux consumer test must export the project-relative Pixi activation wrapper"
  end

  if consumer.match?(
    /^[ \t]*\.[ \t]+[^\n]*\$(?:\{CONDA_PREFIX\}|CONDA_PREFIX)\/(?:dev-)?env\.sh[^\n]*$/
  )
    errors << "Linux consumer test must not source installed activation scripts directly"
  end
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end
