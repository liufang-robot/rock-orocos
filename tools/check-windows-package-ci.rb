#!/usr/bin/env ruby

require "yaml"

ACTION_PINS = {
  "actions/checkout" => "d23441a48e516b6c34aea4fa41551a30e30af803",
  "prefix-dev/setup-pixi" => "f00437f565399d418b0acc85936d12c1fb668347",
  "actions/cache" => "55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
  "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact" => "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
}.freeze

ACTION_COUNTS = {
  "actions/checkout" => 2,
  "prefix-dev/setup-pixi" => 2,
  "actions/cache" => 1,
  "actions/upload-artifact" => 2,
  "actions/download-artifact" => 1
}.freeze

ANCESTRY_SCRIPT = <<~'POWERSHELL'
  $protectedMainRef = "refs/remotes/origin/release-protected-main"
  & git fetch --no-tags --prune --no-recurse-submodules origin `
    "refs/heads/main:$protectedMainRef"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch protected main."
  }
  & git merge-base --is-ancestor $env:GITHUB_SHA $protectedMainRef
  if ($LASTEXITCODE -ne 0) {
    throw "Release commit $env:GITHUB_SHA is not reachable from protected main."
  }
POWERSHELL

def normalize_expression(value)
  value.to_s.gsub(/\s+/, " ").strip
end

def normalize_script(value)
  value.to_s.lines.map(&:rstrip).join("\n").strip
end

def pinned_action(action)
  "#{action}@#{ACTION_PINS.fetch(action)}"
end

def powershell_here_string(contents, variable)
  match = contents.match(/^\$#{Regexp.escape(variable)} = @'\r?\n(?<body>.*?)^'@\r?$/m)
  match && match[:body]
end

def check_release_checkout_and_ancestry(steps, job_name, errors)
  checkout = steps[0]
  ancestry = steps[1]
  unless checkout && checkout["uses"] == pinned_action("actions/checkout")
    errors << "#{job_name} must start with the pinned checkout action"
    return
  end
  expected_checkout = {
    "ref" => "${{ github.sha }}",
    "fetch-depth" => 0,
    "persist-credentials" => false
  }
  unless checkout.fetch("with", {}) == expected_checkout
    errors << "#{job_name} checkout must use the event SHA, full history, and no persisted credentials"
  end

  unless ancestry && ancestry["name"] == "Verify release commit is reachable from main"
    errors << "#{job_name} must check release ancestry immediately after checkout"
    return
  end
  unless normalize_expression(ancestry["if"]) == "github.event_name == 'release'"
    errors << "#{job_name} ancestry check must run for every release event"
  end
  errors << "#{job_name} ancestry check must use PowerShell" unless ancestry["shell"] == "pwsh"
  unless normalize_script(ancestry["run"]) == normalize_script(ANCESTRY_SCRIPT)
    errors << "#{job_name} ancestry check must fail closed against freshly fetched protected main"
  end
end

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github", "workflows", "windows-packages.yml")
recipe_path = File.join(root, "packaging", "conda", "recipe.yaml")
staging_path = File.join(root, "tools", "prepare-windows-conda-release.ps1")
consumer_path = File.join(root, "tools", "test-windows-conda-consumer.ps1")
activation_path = File.join(root, "examples", "pixi-consumer", "scripts", "activate-orocos.ps1")
errors = []

unless File.file?(workflow_path)
  errors << "missing .github/workflows/windows-packages.yml"
else
  contents = File.read(workflow_path)
  workflow = YAML.safe_load(contents, aliases: true)
  triggers = workflow["on"] || workflow[true]
  jobs = workflow.fetch("jobs", {})
  expected_job_names = %w[build-packages publish-packages]
  unless jobs.keys.sort == expected_job_names.sort
    errors << "Windows package CI must define exactly the approved jobs"
  end
  build = jobs.fetch("build-packages", {})
  publish = jobs.fetch("publish-packages", {})
  workflow_runs = jobs.values.flat_map do |job|
    Array(job["steps"]).filter_map { |step| step["run"] }
  end.join("\n")

  unless triggers.is_a?(Hash)
    errors << "Windows package CI must define structured workflow triggers"
    triggers = {}
  end

  pull_request = triggers.fetch("pull_request", {}) || {}
  push = triggers.fetch("push", {}) || {}
  release = triggers.fetch("release", {}) || {}
  errors << "Windows package CI must run on pull requests" unless triggers.key?("pull_request")
  errors << "Windows package CI must run on pushes" unless triggers.key?("push")
  errors << "Windows package CI pushes must be limited to main" unless Array(push["branches"]) == ["main"]
  errors << "Windows package CI must build on manual dispatch" unless triggers.key?("workflow_dispatch")
  unless triggers.key?("release") && Array(release["types"]) == ["published"]
    errors << "Windows package CI must use the published release event"
  end

  required_paths = %w[
    .github/workflows/windows-packages.yml
    examples/pixi-consumer/**
    packaging/**
    tools/build-windows-msvc.ps1
    tools/check-windows-package-ci.rb
    tools/test-windows-package-ci.rb
    tools/stage-license-corpus.rb
    tools/prepare-windows-conda-release.ps1
    tools/test-windows-conda-consumer.ps1
    tools/test-windows-source-lock.ps1
    tools/windows-source-lock.ps1
    pixi.toml
    pixi.lock
  ]
  {
    "pull requests" => Array(pull_request["paths"]),
    "main pushes" => Array(push["paths"])
  }.each do |trigger_name, paths|
    required_paths.each do |path|
      errors << "Windows package CI #{trigger_name} must watch #{path}" unless paths.include?(path)
    end
    errors << "Windows package CI must not rebuild for docs-only changes" if paths.any? { |path| path.start_with?("docs/") }
  end

  top_permissions = workflow.fetch("permissions", {})
  unless top_permissions == { "contents" => "read" }
    errors << "Windows package CI top-level permissions must be contents: read only"
  end
  errors << "Windows package CI must use the canonical Prefix channel" unless workflow.dig("env", "PREFIX_CHANNEL") == "liufang-robot/orocos"
  errors << "Windows package CI channel must not contain @" if workflow.dig("env", "PREFIX_CHANNEL").to_s.include?("@")
  unless workflow.dig("env", "PUBLIC_CHANNEL_URL") == "https://prefix.dev/liufang-robot/orocos"
    errors << "Windows package CI must define the public consumer channel URL"
  end

  unless build["runs-on"] == "windows-2022" && build["timeout-minutes"].to_i >= 180
    errors << "Windows package build must use windows-2022 with a release-sized timeout"
  end
  build_steps = Array(build["steps"])
  build_runs = build_steps.filter_map { |step| step["run"] }.join("\n")
  build_uses = build_steps.filter_map { |step| step["uses"] }
  expected_repository_name = "liufang-robot/rock-orocos"
  expected_release_guard = "github.event.action == 'published' && " \
                           "github.event.release.prerelease == false && " \
                           "github.repository == '#{expected_repository_name}'"
  expected_build_condition = "github.event_name != 'release' || (#{expected_release_guard})"
  unless normalize_expression(build["if"]) == expected_build_condition
    errors << "Windows package build must reject unauthorized release events exactly"
  end
  check_release_checkout_and_ancestry(build_steps, "Windows package build", errors)
  if build_uses.any? { |action| action.start_with?("ilammy/msvc-dev-cmd@") }
    errors << "Windows package build must not activate MSVC outside the recipe build environment"
  end
  errors << "Windows package build must install the locked package environment" unless contents.include?("environments: package") && contents.include?("locked: true")
  errors << "Windows package build must test the source lock" unless build_runs.include?("tools/test-windows-source-lock.ps1")
  errors << "Windows package build must render the recipe" unless build_runs.include?("pixi run --locked package-render")
  errors << "Windows package build must build and test both packages" unless build_runs.include?("pixi run --locked package-build")
  errors << "Windows package build must prepare a verified release bundle" unless build_runs.include?("tools/prepare-windows-conda-release.ps1") && build_runs.include?("-Mode Stage")
  errors << "Windows package build must test clean local-channel consumers" unless build_runs.include?("tools/test-windows-conda-consumer.ps1") && build_runs.include?("-LocalChannelPath packaging/conda/output")
  upload_artifact = pinned_action("actions/upload-artifact")
  errors << "Windows package build must retain the verified bundle" unless build_uses.include?(upload_artifact) && contents.include?("if-no-files-found: error")
  errors << "Windows package build must retain failure diagnostics" unless build_steps.any? { |step| step["if"] == "failure()" && step["uses"] == upload_artifact }
  errors << "Windows package build must not hide failures" if build["continue-on-error"] == true

  publish_condition = publish["if"].to_s
  errors << "Prefix publication must depend on the verified build" unless publish["needs"] == "build-packages"
  expected_publish_condition = "github.event_name == 'release' && #{expected_release_guard}"
  unless normalize_expression(publish_condition) == expected_publish_condition
    errors << "Prefix publication condition must exactly require the approved release event and repository"
  end
  unless publish.fetch("permissions", {}) == { "contents" => "read", "id-token" => "write" }
    errors << "Prefix publication must grant only contents: read and id-token: write"
  end
  errors << "OIDC write permission must exist only in the publish job" unless contents.scan(/^\s+id-token:\s+write\s*$/).count == 1

  publish_steps = Array(publish["steps"])
  publish_runs = publish_steps.filter_map { |step| step["run"] }.join("\n")
  publish_uses = publish_steps.filter_map { |step| step["uses"] }
  check_release_checkout_and_ancestry(publish_steps, "Prefix publication", errors)
  errors << "Prefix publication must download the verified bundle" unless publish_uses.include?(pinned_action("actions/download-artifact"))
  verify_step = publish_steps.find do |step|
    step["name"] == "Verify release tag, commit, metadata, and checksums"
  end
  unless verify_step && verify_step.fetch("env", {}) == {
    "EXPECTED_RELEASE_TAG" => "${{ github.event.release.tag_name }}"
  }
    errors << "Prefix publication must pass the release tag through EXPECTED_RELEASE_TAG"
  end
  if workflow_runs.include?("${{")
    errors << "Windows package CI must not interpolate GitHub expressions into run scripts"
  end
  unless publish_runs.include?("-ExpectedTag $env:EXPECTED_RELEASE_TAG")
    errors << "Prefix publication must read the release tag from EXPECTED_RELEASE_TAG"
  end
  unless publish_runs.include?("-Mode Verify") &&
         publish_runs.include?("-ExpectedRepositoryCommit $env:GITHUB_SHA")
    errors << "Prefix publication must verify the tag, commit, metadata, and checksums"
  end
  unless publish_runs.include?("rattler-build upload prefix") &&
         publish_runs.include?("--channel $env:PREFIX_CHANNEL")
    errors << "Prefix publication must upload the manifest-selected files to the canonical channel"
  end
  if publish_runs.include?("--force") || publish_runs.include?("--skip-existing")
    errors << "Prefix publication must fail on an existing immutable filename"
  end
  if contents.include?("PREFIX_API_KEY") || contents.match?(/secrets\./)
    errors << "Prefix publication must use Repository Access OIDC, not a stored API key"
  end
  unless publish_runs.include?("tools/test-windows-conda-consumer.ps1") &&
         publish_runs.include?("-ChannelUrl $env:PUBLIC_CHANNEL_URL") &&
         publish_runs.include?("-Attempts 6")
    errors << "Prefix publication must test clean consumers through the public channel"
  end

  all_uses = jobs.values.flat_map do |job|
    Array(job["steps"]).filter_map { |step| step["uses"] }
  end
  expected_uses = ACTION_COUNTS.to_h do |action, count|
    [pinned_action(action), count]
  end
  unless all_uses.tally == expected_uses
    errors << "Windows package CI actions must equal the approved full-SHA selections: " \
              "expected #{expected_uses.inspect}, got #{all_uses.tally.inspect}"
  end
end

unless File.file?(recipe_path)
  errors << "missing packaging/conda/recipe.yaml"
else
  recipe = File.read(recipe_path)
  unless recipe.include?(%q{${{ compiler('cxx') }}})
    errors << "Windows package recipe must activate the MSVC x64 build environment"
  end
  expected_repository = "https://github.com/liufang-robot/rock-orocos"
  expected_documentation = "https://liufang-robot.github.io/rock-orocos/"
  {
    "homepage" => expected_repository,
    "repository" => expected_repository,
    "documentation" => expected_documentation
  }.each do |field, expected|
    token = "#{field}: #{expected}"
    errors << "Windows package recipe must define #{token}" unless recipe.include?(token)
  end
  unless recipe.include?("    - liufang-robot")
    errors << "Windows package recipe must identify liufang-robot as maintainer"
  end
  [
    "A relocatable Windows Orocos runtime",
    "Headers, CMake and pkg-config metadata",
    "description:"
  ].each do |token|
    errors << "Windows package recipe must define package descriptions" unless recipe.include?(token)
  end
end

unless File.file?(staging_path)
  errors << "missing tools/prepare-windows-conda-release.ps1"
else
  staging = File.read(staging_path)
  {
    "structured package inspection" => "rattler-build package inspect",
    "runtime/development package set" => '@("orocos", "orocos-dev")',
    "exact runtime dependency" => '"orocos ==$version $($runtime.Metadata.index.build)"',
    "package path overlap check" => "HashSet[string]",
    "module-independent artifact checksums" =>
      "[System.Security.Cryptography.SHA256]::Create()",
    "source lock in the release manifest" => "source_lock",
    "the win-64 target platform" => 'target_platform -cne "win-64"',
    "a full repository commit" => 'repository_commit -cnotmatch "^[0-9a-f]{40}$"',
    "local repodata verification" => "Test-LocalRepodata",
    "immutable checksum manifest" => "SHA256SUMS.txt"
  }.each do |contract, token|
    errors << "release staging must enforce #{contract}" unless staging.include?(token)
  end
  if staging.match?(/\bGet-FileHash\b/)
    errors << "release staging must not depend on the optional Get-FileHash cmdlet"
  end
  unless staging.include?('[string]$Channel = "liufang-robot/orocos"')
    errors << "release staging must use the canonical Prefix channel"
  end
  errors << "release staging must not publish packages" if staging.include?("upload prefix")
end

unless File.file?(consumer_path)
  errors << "missing tools/test-windows-conda-consumer.ps1"
else
  consumer = File.read(consumer_path)
  {
    "an exact runtime build" => '"orocos==$($runtime.version)=$($runtime.build)"',
    "an exact development build" => '"orocos-dev==$($development.version)=$($development.build)"',
    "a clean Pixi package cache" => "PIXI_CACHE_DIR",
    "OroGen" => "orogen --version",
    "Typegen" => "typegen --help",
    "the OPC UA deployer" => "deployer-opcua-win32.exe --check --no-consolelog"
  }.each do |contract, token|
    errors << "consumer smoke test must check #{contract}" unless consumer.include?(token)
  end

  activation_sources = consumer.scan(
    /^[ \t]*\.[ \t]+\$env:OROCOS_PIXI_ACTIVATION_SCRIPT[ \t]*\r?$/
  )
  unless activation_sources.size == 2
    errors << "consumer smoke test must source the shared Pixi activation wrapper exactly twice"
  end

  activation_resolution =
    'Join-Path $PSScriptRoot "..\examples\pixi-consumer\scripts\activate-orocos.ps1"'
  unless consumer.lines.any? { |line| line.strip == activation_resolution }
    errors << "consumer smoke test must resolve the project-relative PowerShell wrapper"
  end

  if consumer.match?(
    /^[ \t]*\.[ \t]+[^\r\n]*Library[\\\/](?:dev-)?env\.ps1\b[^\r\n]*\r?$/i
  )
    errors << "consumer smoke test must not source installed activation scripts directly"
  end

  {
    "runtime" => powershell_here_string(consumer, "runtimeCommand"),
    "development" => powershell_here_string(consumer, "developmentCommand")
  }.each do |command, body|
    unless body&.match?(/^[ \t]*\$ErrorActionPreference[ \t]*=[ \t]*"Stop"[ \t]*\r?$/)
      errors << "consumer smoke test #{command} child must stop on PowerShell errors"
    end
  end
end

unless File.file?(activation_path)
  errors << "missing examples/pixi-consumer/scripts/activate-orocos.ps1"
else
  activation = File.read(activation_path)
  activation_lines = activation.lines.map(&:strip)
  library_selector =
    '$libraryPrefix = Join-Path -Path $env:CONDA_PREFIX -ChildPath "Library"'
  {
    "the runtime activation contract" => [
      library_selector,
      '$runtimeScript = Join-Path -Path $libraryPrefix -ChildPath "env.ps1"'
    ],
    "the development activation contract" => [
      library_selector,
      '$developmentScript = Join-Path -Path $libraryPrefix -ChildPath "dev-env.ps1"'
    ]
  }.each do |contract, required_lines|
    unless required_lines.all? { |line| activation_lines.include?(line) }
      errors << "consumer activation wrapper must check #{contract}"
    end
  end
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
