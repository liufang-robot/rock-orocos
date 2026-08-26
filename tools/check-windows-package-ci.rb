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
  "actions/cache" => 2,
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
native_workflow_path = File.join(root, ".github", "workflows", "windows-msvc.yml")
recipe_path = File.join(root, "packaging", "conda", "recipe.yaml")
linux_recipe_path = File.join(root, "packaging", "conda", "recipe-linux.yaml")
build_path = File.join(root, "packaging", "conda", "build.ps1")
runtime_stage_path = File.join(
  root, "packaging", "conda", "stage-runtime-hook.ps1"
)
builder_path = File.join(root, "tools", "build-windows-msvc.ps1")
hook_path = File.join(root, "packaging", "conda", "orocos-activate.bat")
deactivation_hook_path = File.join(
  root, "packaging", "conda", "orocos-deactivate.bat"
)
runtime_test_path = File.join(root, "packaging", "conda", "test-runtime.ps1")
development_test_path = File.join(root, "packaging", "conda", "test-dev.ps1")
staging_path = File.join(root, "tools", "prepare-windows-conda-release.ps1")
consumer_path = File.join(root, "tools", "test-windows-conda-consumer.ps1")
activation_probe_path = File.join(
  root, "tools", "probe-windows-conda-activation.ps1"
)
activation_path = File.join(root, "examples", "pixi-consumer", "scripts", "activate-orocos.ps1")
exporter_path = File.join(root, "tools", "export-windows-env.ps1")
pixi_manifest_path = File.join(root, "pixi.toml")
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
  unless build["name"] == "Windows packages / build and test"
    errors << "Windows package build check must use the platform-first display name"
  end
  unless publish["name"] == "Windows packages / publish to Prefix"
    errors << "Windows package publish check must use the platform-first display name"
  end
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
    tools/probe-windows-conda-activation.ps1
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
  unless workflow.dig("env", "OROCOS_VCPKG_ROOT") ==
         "${{ github.workspace }}/.cache/vcpkg/root"
    errors << "Windows package CI must place the reusable vcpkg root outside disposable package paths"
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
  unless build_runs.include?('Join-Path $env:OROCOS_VCPKG_ROOT') &&
         build_runs.include?('"installed\vcpkg\status"') &&
         build_runs.include?('".orocos-package-cache-ready"')
    errors << "Windows package CI must verify that Rattler populated the configured vcpkg root"
  end
  errors << "Windows package build must prepare a verified release bundle" unless build_runs.include?("tools/prepare-windows-conda-release.ps1") && build_runs.include?("-Mode Stage")
  errors << "Windows package build must test clean local-channel consumers" unless build_runs.include?("tools/test-windows-conda-consumer.ps1") && build_runs.include?("-LocalChannelPath packaging/conda/output")
  upload_artifact = pinned_action("actions/upload-artifact")
  errors << "Windows package build must retain the verified bundle" unless build_uses.include?(upload_artifact) && contents.include?("if-no-files-found: error")
  errors << "Windows package build must retain failure diagnostics" unless build_steps.any? { |step| step["if"] == "failure()" && step["uses"] == upload_artifact }
  errors << "Windows package build must not hide failures" if build["continue-on-error"] == true

  compatibility_step = build_steps.find do |step|
    step["name"] == "Identify vcpkg cache compatibility"
  end
  unless compatibility_step &&
         compatibility_step["id"] == "vcpkg-cache-compatibility" &&
         compatibility_step["shell"] == "pwsh" &&
         compatibility_step["run"].to_s.include?("vswhere.exe") &&
         compatibility_step["run"].to_s.include?("installationVersion") &&
         compatibility_step["run"].to_s.include?('"msvc=$installationVersion" >> $env:GITHUB_OUTPUT')
    errors << "Windows package CI must identify the exact MSVC compatibility boundary for vcpkg caches"
  end

  installed_cache = build_steps.find do |step|
    step["name"] == "Restore installed vcpkg tree"
  end
  expected_installed_key =
    "windows-vcpkg-installed-v1-windows-2022-msvc-" \
    "${{ steps.vcpkg-cache-compatibility.outputs.msvc }}-x64-windows-" \
    "${{ hashFiles('packaging/source-lock.json', 'tools/build-windows-msvc.ps1') }}"
  unless installed_cache &&
         installed_cache["id"] == "vcpkg-installed-cache" &&
         installed_cache["uses"] == pinned_action("actions/cache") &&
         installed_cache.dig("with", "path") == ".cache/vcpkg/root/installed" &&
         installed_cache.dig("with", "key") == expected_installed_key
    errors << "Windows package CI must cache only the exact compatible installed vcpkg tree"
  end
  if installed_cache&.fetch("with", {})&.key?("restore-keys")
    errors << "The installed vcpkg tree must not use compatibility-weakening restore keys"
  end

  artifact_cache = build_steps.find do |step|
    step["name"] == "Restore vcpkg downloads and binary packages"
  end
  expected_artifact_key =
    "windows-vcpkg-artifacts-v2-windows-2022-msvc-" \
    "${{ steps.vcpkg-cache-compatibility.outputs.msvc }}-x64-windows-" \
    "${{ hashFiles('packaging/source-lock.json', 'tools/build-windows-msvc.ps1') }}"
  expected_artifact_restore =
    "windows-vcpkg-artifacts-v2-windows-2022-msvc-" \
    "${{ steps.vcpkg-cache-compatibility.outputs.msvc }}-x64-windows-\n"
  unless artifact_cache &&
         artifact_cache["uses"] == pinned_action("actions/cache") &&
         artifact_cache.dig("with", "path") == ".cache/vcpkg/archives\n.cache/vcpkg/downloads\n" &&
         artifact_cache.dig("with", "key") == expected_artifact_key &&
         artifact_cache.dig("with", "restore-keys") == expected_artifact_restore
    errors << "Windows package CI must isolate vcpkg artifacts by runner, MSVC, triplet, lock, and builder"
  end

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

unless File.file?(builder_path)
  errors << "missing tools/build-windows-msvc.ps1"
else
  builder = File.read(builder_path)
  normalized_builder = builder.gsub("\r\n", "\n")
  install_step = builder.match(
    /^Invoke-Step "Install vcpkg dependencies" \{\r?\n(?<body>.*?)^\}\r?$/m
  )
  if install_step.nil?
    errors << "Windows builder must define the vcpkg dependency install step"
  else
    dependency = '"boost-functional:${VcpkgTriplet}"'
    dependency_count = install_step[:body].lines.count do |line|
      line.strip.delete_suffix(" `") == dependency
    end
    unless dependency_count == 1
      errors << "Windows builder must install boost-functional directly for RTT headers"
    end
  end

  unless normalized_builder.include?("    [switch]$SkipGeneratorSmokeTests,\n")
    errors << "Windows builder must define the package-only generator smoke skip switch"
  end
  unless normalized_builder.include?("    [switch]$SuppressExternalWarnings,\n")
    errors << "Windows builder must define package-only external warning suppression"
  end
  unless normalized_builder.include?('$CMakeGeneratorArguments = @("-G", $Generator)') &&
         normalized_builder.include?('if ($IsVisualStudioGenerator) {') &&
         normalized_builder.include?('$CMakeGeneratorArguments += @("-A", $Platform)') &&
         normalized_builder.include?('--target $CMakeInstallTarget') &&
         normalized_builder.include?('Invoke-Native $RttTypelibTestExecutable')
    errors << "Windows builder must support both Visual Studio and Ninja generator layouts"
  end
  unless normalized_builder.include?('$cxxOptions += "/EHsc"') &&
         normalized_builder.include?(
           '-EnableExceptions:((-not $IsVisualStudioGenerator) -or $SuppressExternalWarnings)'
         )
    errors << "Windows builder must retain C++ exception semantics with custom compiler flags"
  end
  unless normalized_builder.include?('Join-Path $VcpkgInstalled "include"') &&
         normalized_builder.include?("Microsoft Visual Studio|Windows Kits") &&
         normalized_builder.include?('/external:W0') &&
         normalized_builder.scan("@CMakeCompilerFlagArguments").size >= 12
    errors << "Windows builder must suppress only vcpkg and MSVC system-header warnings"
  end
  if normalized_builder.include?("/external:anglebrackets") ||
     normalized_builder.include?("/external:env:INCLUDE")
    errors << "Windows builder must keep maintained Orocos header warnings visible"
  end
  skip_guard = "if (-not $SkipGeneratorSmokeTests) {"
  unless normalized_builder.lines.count { |line| line.strip == skip_guard } == 3
    errors << "Windows builder must guard smoke builds, artifacts, and executions with the skip switch"
  end
  [
    "Generate Windows OroGen smoke project",
    "Build Windows OroGen smoke project",
    "Generate Windows Typegen smoke project",
    "Build Windows Typegen smoke project"
  ].each do |step|
    unless normalized_builder.scan(%(Invoke-Step "#{step}")).size == 1
      errors << "Windows builder must retain the standalone #{step}"
    end
  end
end

if !File.file?(native_workflow_path)
  errors << "missing .github/workflows/windows-msvc.yml"
else
  native_workflow = File.read(native_workflow_path)
  if native_workflow.match?(/^\s*-SkipGeneratorSmokeTests(?:\s|$)/i)
    errors << "Windows native CI must retain generator smoke tests"
  end
  if native_workflow.match?(/^\s*-(?:SuppressExternalWarnings|Generator\s+Ninja)(?:\s|$)/i)
    errors << "Windows native CI must retain Visual Studio and maintained warning coverage"
  end
end

if !File.file?(pixi_manifest_path)
  errors << "missing pixi.toml"
else
  pixi_manifest = File.read(pixi_manifest_path)
  if pixi_manifest.match?(/^\s*"-SkipGeneratorSmokeTests",?\s*$/i)
    errors << "the default Windows build task must retain generator smoke tests"
  end
  if pixi_manifest.match?(/^\s*"-(?:SuppressExternalWarnings|Generator)",?\s*$/i)
    errors << "the default Windows build task must retain Visual Studio and maintained warning coverage"
  end
end

unless File.file?(recipe_path)
  errors << "missing packaging/conda/recipe.yaml"
else
  recipe = File.read(recipe_path)
  version = recipe[/^  version:\s*"([^"]+)"\s*$/, 1]
  build_number = recipe[/^  build_number:\s*(\d+)\s*$/, 1]
  unless build_number
    errors << "Windows package recipe build number must be a non-negative integer"
  end
  if !File.file?(linux_recipe_path)
    errors << "missing packaging/conda/recipe-linux.yaml"
  else
    linux_recipe = File.read(linux_recipe_path)
    linux_version = linux_recipe[/^  version:\s*"([^"]+)"\s*$/, 1]
    linux_build_number = linux_recipe[/^  build_number:\s*(\d+)\s*$/, 1]
    unless version && version == linux_version && build_number == linux_build_number
      errors << "Linux and Windows package recipes must use the same version and build number"
    end
  end
  unless recipe.include?(%q{${{ compiler('cxx') }}})
    errors << "Windows package recipe must activate the MSVC x64 build environment"
  end
  unless recipe.match?(/^\s+- ninja >=1\.12,<2\s*$/)
    errors << "Windows package recipe must provide the locked Ninja build tool"
  end
  [
    'OROCOS_VCPKG_ROOT: ${{ env.get("OROCOS_VCPKG_ROOT", default="") }}',
    'VCPKG_DEFAULT_BINARY_CACHE: ${{ env.get("VCPKG_DEFAULT_BINARY_CACHE", default="") }}',
    'VCPKG_DOWNLOADS: ${{ env.get("VCPKG_DOWNLOADS", default="") }}'
  ].each do |forwarding|
    unless recipe.include?(forwarding)
      errors << "Windows package recipe must explicitly forward isolated vcpkg cache paths"
    end
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

  runtime_output = recipe[/^  - package:\r?\n      name: orocos\r?\n(?<body>.*?)(?=^  - package:|\z)/m, :body]
  development_output = recipe[/^  - package:\r?\n      name: orocos-dev\r?\n(?<body>.*?)(?=^  - package:|\z)/m, :body]
  unless development_output.to_s.match?(/^\s+- script: test-dev\.ps1\s*$/)
    errors << "orocos-dev must run the clean generator package acceptance test"
  end
  {
    "activation" => "packaging/conda/orocos-activate.bat",
    "deactivation" => "packaging/conda/orocos-deactivate.bat"
  }.each do |lifecycle, path|
    unless recipe.scan(/^\s+- #{Regexp.escape(path)}\s*$/).size == 1
      errors << "Windows package recipe must include the Conda #{lifecycle} hook source exactly once"
    end
  end
  unless recipe.include?("        - packaging/conda/stage-runtime-hook.ps1")
    errors << "Windows package recipe must include the runtime hook staging script source"
  end
  unless runtime_output.to_s.match?(
    /^\s+script:\r?\n\s+file: stage-runtime-hook\.ps1\s*$/
  )
    errors << "orocos runtime output must stage its activation hook after build environment activation"
  end
  {
    "Library/env.bat" => "generated batch runtime entrypoint",
    "etc/conda/activate.d/orocos-activate.bat" => "Conda runtime activation hook",
    "etc/conda/deactivate.d/orocos-deactivate.bat" => "Conda runtime deactivation hook"
  }.each do |path, contract|
    runtime_count = runtime_output.to_s.scan(/^\s+- #{Regexp.escape(path)}\s*$/).size
    unless runtime_count >= 2
      errors << "orocos runtime output must own and test the #{contract}"
    end
    development_count = development_output.to_s.scan(/^\s+- #{Regexp.escape(path)}\s*$/).size
    unless development_count == 1
      errors << "orocos-dev output must explicitly exclude the #{contract}"
    end
  end
  if recipe.match?(/^\s+- Library\/dev-env\.bat\s*$/)
    errors << "Windows package recipe must not add dev-env.bat"
  end
end

unless File.file?(build_path)
  errors << "missing packaging/conda/build.ps1"
else
  build_script = File.read(build_path)
  unless build_script.lines.count { |line| line.strip == "-SkipGeneratorSmokeTests" } == 1
    errors << "Windows package staging must skip duplicated generator smoke tests"
  end
  unless build_script.lines.count { |line| line.strip == "-SuppressExternalWarnings `" } == 1 &&
         build_script.lines.count { |line| line.strip == "-Generator Ninja `" } == 1
    errors << "Windows package staging must use Ninja with scoped external warning suppression"
  end
  unless build_script.include?('"OROCOS_VCPKG_ROOT"') &&
         build_script.include?("[IO.Path]::IsPathRooted($configuredVcpkgRoot)") &&
         build_script.include?('$vcpkgRoot = Join-Path $temporaryRoot "v"') &&
         build_script.include?("$vcpkgRoot = [IO.Path]::GetFullPath($configuredVcpkgRoot)") &&
         build_script.include?('Join-Path $vcpkgRoot ".orocos-package-cache-ready"')
    errors << "Windows package staging must use an absolute configured vcpkg root with a disposable fallback"
  end
  if build_script.include?("orocos-activate.bat") ||
     build_script.include?("orocos-deactivate.bat") ||
     build_script.include?('etc\conda\activate.d') ||
     build_script.include?('etc\conda\deactivate.d')
    errors << "Windows shared staging cache must not install runtime lifecycle hooks"
  end
end

if !File.file?(development_test_path)
  errors << "missing packaging/conda/test-dev.ps1"
else
  development_test = File.read(development_test_path)
  unless development_test.include?('Join-Path $bundledVcpkg "include"') &&
         development_test.include?("Microsoft Visual Studio|Windows Kits") &&
         development_test.include?("/external:W0") &&
         development_test.scan("@externalWarningArguments").size == 2
    errors << "Windows development package test must suppress only dependency and SDK warnings"
  end
  unless development_test.include?('$cxxFlags = (@("/EHsc") + $externalOptions) -join " "') &&
         development_test.include?('"-DCMAKE_CXX_FLAGS=$cxxFlags"')
    errors << "Windows development package test must retain MSVC C++ exception semantics"
  end
  if development_test.include?("/external:anglebrackets") ||
     development_test.include?("/external:env:INCLUDE")
    errors << "Windows development package test must keep Orocos header warnings visible"
  end
  unless development_test.match?(
    /Invoke-Native \$orogen .*?cmake --build \$orogenBuild .*?--target INSTALL/m
  )
    errors << "Windows development package test must generate and install a clean OroGen project"
  end
  unless development_test.match?(
    /Invoke-Native \$typegen .*?cmake --build \$typegenBuild .*?--target regen.*?cmake --build \$typegenBuild .*?--target INSTALL/m
  )
    errors << "Windows development package test must generate, regenerate, and install a clean Typegen project"
  end
end

if !File.file?(runtime_stage_path)
  errors << "missing packaging/conda/stage-runtime-hook.ps1"
else
  runtime_stage = File.read(runtime_stage_path)
  {
    "the repository-owned activation hook" =>
      'Join-Path $env:SRC_DIR "packaging\conda\orocos-activate.bat"',
    "the Conda prefix activation directory" =>
      'Join-Path $env:PREFIX "etc\conda\activate.d"',
    "the repository-owned deactivation hook" =>
      'Join-Path $env:SRC_DIR "packaging\conda\orocos-deactivate.bat"',
    "the Conda prefix deactivation directory" =>
      'Join-Path $env:PREFIX "etc\conda\deactivate.d"',
    "the canonical activation hook destination" => "orocos-activate.bat",
    "the canonical deactivation hook destination" => "orocos-deactivate.bat"
  }.each do |contract, token|
    unless runtime_stage.include?(token)
      errors << "Windows runtime output must stage #{contract}"
    end
  end
  unless runtime_stage.scan(/^Copy-Item\b/).size == 2
    errors << "Windows runtime output must copy exactly two lifecycle hooks"
  end
end

if !File.file?(hook_path)
  errors << "missing packaging/conda/orocos-activate.bat"
else
  activation_hook = File.read(hook_path).gsub("\r\n", "\n")
  activation_tokens = [
    "@if defined __OROCOS_ROCK_CONDA_ACTIVE @goto orocos_activate_runtime",
    '@set "__OROCOS_ROCK_PATH_RUNTIME_PLUGIN_PRESENT=1"',
    '@set "__OROCOS_ROCK_RECORD_RUNTIME_PLUGIN=1"',
    '@call "%~dp0..\..\..\Library\env.bat" --conda',
    "@call :orocos_activate_return %ERRORLEVEL%",
    ":orocos_activate_return",
    '@set "__OROCOS_ROCK_RECORD_RUNTIME_PLUGIN="',
    '@call "%~dp0..\deactivate.d\orocos-deactivate.bat"',
    "@exit /b %ERRORLEVEL%"
  ]
  %w[
    OROCOS_PREFIX
    OROCOS_TARGET
    RTT_COMPONENT_PATH
    PKG_CONFIG_LIBDIR
    PKG_CONFIG_PATH
    TYPELIB_PLUGIN_PATH
    CMAKE_PREFIX_PATH
  ].each do |name|
    activation_tokens << %(@set "__OROCOS_ROCK_#{name}_SET=0")
    activation_tokens << %(@set "__OROCOS_ROCK_#{name}_VALUE=%#{name}%")
  end
  unless activation_tokens.all? { |token| activation_hook.include?(token) } &&
         !activation_hook.match?(/powershell(?:\.exe)?/i)
    errors << "Windows package activation hook must preserve lifecycle state, call Library\\env.bat in Conda mode, and propagate failure"
  end
end

if !File.file?(deactivation_hook_path)
  errors << "missing packaging/conda/orocos-deactivate.bat"
else
  deactivation_hook = File.read(deactivation_hook_path).gsub("\r\n", "\n")
  deactivation_tokens = [
    "@if not defined __OROCOS_ROCK_CONDA_ACTIVE @exit /b 0",
    ":orocos_deactivate_next_path_value",
    '@set "PATH=%__OROCOS_ROCK_HOOK_PATH_NEW:~1%"',
    '@set "__OROCOS_ROCK_PATH_RUNTIME_PLUGIN_PRESENT="',
    '@set "__OROCOS_ROCK_RECORD_RUNTIME_PLUGIN="',
    '@set "__OROCOS_ROCK_CONDA_ACTIVE="',
    "@exit /b 0"
  ]
  %w[
    OROCOS_PREFIX
    OROCOS_TARGET
    RTT_COMPONENT_PATH
    PKG_CONFIG_LIBDIR
    PKG_CONFIG_PATH
    TYPELIB_PLUGIN_PATH
    CMAKE_PREFIX_PATH
  ].each do |name|
    deactivation_tokens << %(@set "#{name}=")
    deactivation_tokens <<
      %(@if "%__OROCOS_ROCK_#{name}_SET%"=="1" @set "#{name}=%__OROCOS_ROCK_#{name}_VALUE%")
    deactivation_tokens << %(@set "__OROCOS_ROCK_#{name}_SET=")
    deactivation_tokens << %(@set "__OROCOS_ROCK_#{name}_VALUE=")
  end
  unless deactivation_tokens.all? { |token| deactivation_hook.include?(token) } &&
         !deactivation_hook.match?(/powershell(?:\.exe)?/i)
    errors << "Windows package deactivation hook must restore the pre-activation environment and clean lifecycle state"
  end
end

unless File.file?(exporter_path)
  errors << "missing tools/export-windows-env.ps1"
else
  exporter = File.read(exporter_path)
  {
    "the shared runtime directory model" => "$runtimeDirectoriesBeforeRecursive",
    "the generated batch runtime template" => "$runtimeBatchTemplate = @'",
    "the batch runtime output" => 'Join-Path $Prefix "env.bat"'
  }.each do |contract, token|
      errors << "Windows environment exporter must define #{contract}" unless exporter.include?(token)
  end
  if exporter.include?(%q!"{0}(Join-Path `$Prefix '{1}')," -f!)
    errors << "Windows environment exporter must not emit a trailing comma after the final PowerShell path expression"
  end

  runtime_batch = powershell_here_string(exporter, "runtimeBatchTemplate")
  {
    "self-relative prefix discovery" => '%~dp0.',
    "recursive Orocos directory discovery" => "for /d /r",
    "directory existence filtering" => "if not exist",
    "case-insensitive full-entry membership" =>
      'findstr.exe" /I /L',
    "Conda-owned PATH preservation" =>
      '@if /I not "%~1"=="--conda" @goto orocos_full_runtime_path',
    "the Conda runtime loader directory" =>
      '@call :orocos_add_candidate "%OROCOS_PREFIX%\lib\orocos\@TARGET@\plugins"',
    "activation-owned loader path tracking" =>
      '__OROCOS_ROCK_PATH_RUNTIME_PLUGIN_PRESENT',
    "the full standalone runtime path branch" => ":orocos_full_runtime_path",
    "the package-mode runtime path boundary" => ":orocos_runtime_path_ready",
    "internal failure propagation" => ":orocos_runtime_failed",
    "final assignment failure detection" =>
      '__OROCOS_ROCK_PATH_COMMIT_OK',
    "caller-preserving success" => "exit /b 0"
  }.each do |contract, token|
    unless runtime_batch&.include?(token)
      errors << "generated env.bat must implement #{contract}"
    end
  end
  if runtime_batch&.match?(/\b(?:setlocal|powershell(?:\.exe)?|python(?:\.exe)?)\b/i)
    errors << "generated env.bat must not use scoped activation or non-system helper runtimes"
  end
  unsafe_long_path_tokens = [
    "__OROCOS_ROCK_PATH_OLD",
    "__OROCOS_ROCK_PATH_INPUT",
    "__OROCOS_ROCK_PATH_SCAN",
    "__OROCOS_ROCK_PATH_COMPARE",
    "__OROCOS_ROCK_PATH_COMPARISON",
    '@for /f "tokens=1,* delims=;"',
    "call set"
  ]
  if unsafe_long_path_tokens.any? { |token| runtime_batch&.include?(token) }
    errors << "generated env.bat must not expand inherited PATH-like values while scanning entries"
  end
  boundary_membership_tokens = [
    ":orocos_path_contains_candidate",
    '/L /X /C:"%__OROCOS_ROCK_PATH_NAME%=%~1"',
    '/L /B /C:"%__OROCOS_ROCK_PATH_NAME%=%~1;"',
    '/L /C:";%~1;"',
    '/L /E /C:";%~1"'
  ]
  unless boundary_membership_tokens.all? { |token| runtime_batch&.include?(token) }
    errors << "generated env.bat must match existing candidates as complete case-insensitive entries"
  end
  %w[
    PATH
    RTT_COMPONENT_PATH
    PKG_CONFIG_PATH
    TYPELIB_PLUGIN_PATH
    CMAKE_PREFIX_PATH
  ].each do |name|
    prepend = %(@set "#{name}=%__OROCOS_ROCK_PATH_PREFIX:~1%;%#{name}%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1")
    unless runtime_batch&.include?(prepend) &&
           runtime_batch.scan(/%#{Regexp.escape(name)}%/i).size == 1
      errors << "generated env.bat must preserve inherited #{name} and expand it only for the final prepend"
    end
  end
  if runtime_batch&.match?(/^\s*@?echo\s+off\s*$/i)
    errors << "generated env.bat must not change the caller's echo mode"
  end
end


unless File.file?(runtime_test_path)
  errors << "missing packaging/conda/test-runtime.ps1"
else
  runtime_test = File.read(runtime_test_path)
  {
    "the explicit batch runtime entrypoint" => 'Join-Path $libraryPrefix "env.bat"',
    "the package activation hook" =>
      'Join-Path $condaPrefix "etc\conda\activate.d\orocos-activate.bat"',
    "the package deactivation hook" =>
      'Join-Path $condaPrefix "etc\conda\deactivate.d\orocos-deactivate.bat"',
    "cmd.exe caller activation" => "Invoke-BatchEnvironment",
    "repeated activation" =>
      'Invoke-BatchEnvironment -BatchPath $runtimeBatch -Calls 2',
    "exact consumer path preservation" => "Assert-PathValuePreservedAsSuffix",
    "structured expected path records" => "$expectedPathEntries = @(",
    "a Rattler-length inherited PATH" => "$rattlerPathEntries = @(",
    "Rattler-style command echo" => "-EchoCommands",
    "quiet internal PATH commands" =>
      '$script:BatchActivationOutput -match "__OROCOS_ROCK_PATH_"',
    "internal failure propagation" => "-ExpectedExitCode 1",
    "a relocated prefix containing spaces" => '"orocos activation "',
    "case-insensitive comparisons" => "OrdinalIgnoreCase",
    "recursive runtime discovery" => '"lib\orocos\win32\custom\plugins"'
  }.each do |contract, token|
    errors << "Windows runtime package test must cover #{contract}" unless runtime_test.include?(token)
  end
  unless runtime_test.match?(
    /\$script:BatchActivationElapsed\.TotalSeconds -gt 30(?:\D|$)/
  )
    errors << "Windows runtime package test must cover a bounded activation time"
  end

  exact_path_tokens = [
    "function Assert-EnvironmentValueExact {",
    "[StringComparison]::Ordinal",
    '$hookRuntimePlugins = Join-Path $libraryPrefix "lib\orocos\win32\plugins"',
    '$hookExpectedPath = "$hookRuntimePlugins;$rattlerPath"',
    '-Environment $hookEnvironment -Name "PATH" -Expected $hookExpectedPath',
    '[PSCustomObject]@{ Name = "PATH"; Path = $hookRuntimePlugins }'
  ]
  unless exact_path_tokens.all? { |token| runtime_test.include?(token) } &&
         runtime_test.scan(/\bAssert-EnvironmentValueExact\b/).size >= 2
    errors << "Windows runtime package test must prepend the loader path while preserving Conda PATH"
  end

  conda_discovery_tokens = [
    '$staleHookDiscoveryPath = "C:\stale-orocos-discovery"',
    'OROCOS_PREFIX = "C:\stale-orocos-prefix"',
    'OROCOS_TARGET = "stale-target"',
    'RTT_COMPONENT_PATH = $staleHookDiscoveryPath',
    'PKG_CONFIG_LIBDIR = "C:\stale-pkg-config-libdir"',
    'PKG_CONFIG_PATH = $staleHookDiscoveryPath',
    'TYPELIB_PLUGIN_PATH = $staleHookDiscoveryPath',
    'CMAKE_PREFIX_PATH = $staleHookDiscoveryPath',
    '-Name "OROCOS_PREFIX" -Expected $libraryPrefix',
    '-Name "OROCOS_TARGET" -Expected "win32"',
    '$hookPkgConfig = Join-Path $libraryPrefix "lib\pkgconfig"',
    '$hookTypelib = Join-Path $libraryPrefix "lib\typelib"',
    '$hookRttTypes = Join-Path $libraryPrefix "lib\orocos\win32\types"',
    '$createdHookPkgConfig = -not (Test-Path -LiteralPath $hookPkgConfig',
    'New-Item -ItemType Directory -Path $hookPkgConfig',
    'if ($createdHookPkgConfig) {',
    'Remove-Item -LiteralPath $hookPkgConfig -Force',
    '-Name "PKG_CONFIG_LIBDIR" -Expected $hookPkgConfig',
    '$hookExpectedPathEntries = @(',
    '$hookPreservedPathNames = @(',
    '-ExpectedPath $staleHookDiscoveryPath'
  ]
  unless conda_discovery_tokens.all? { |token| runtime_test.include?(token) }
    errors << "Windows runtime package test must cover Conda-mode discovery variables"
  end

  lifecycle_tokens = [
    "function Assert-EnvironmentAbsent {",
    "function Assert-NoOrocosHookState {",
    '$FollowupBatchPath',
    '$RemoveEnvironmentVariables',
    '-FollowupBatchPath $deactivationHook',
    '-FollowupCalls 2',
    '-RemoveEnvironmentVariables $hookManagedVariables',
    '$restoredHookEnvironment',
    '$unsetHookEnvironment',
    '$preexistingPluginPath = "$hookRuntimePlugins;$rattlerPath"',
    '-Expected $preexistingPluginPath'
  ]
  unless lifecycle_tokens.all? { |token| runtime_test.include?(token) } &&
         runtime_test.scan(/-BatchPath \$activationHook/).size >= 3 &&
         runtime_test.scan(/-FollowupCalls 2/).size >= 2 &&
         runtime_test.scan(/-RemoveEnvironmentVariables \$hookManagedVariables/).size >= 2
    errors << "Windows runtime package test must cover reversible and idempotent package hooks"
  end
end

unless File.file?(activation_probe_path)
  errors << "missing tools/probe-windows-conda-activation.ps1"
else
  activation_probe = File.read(activation_probe_path)
  {
    "Rattler-style command echo" => '"@echo on"',
    "a structured long PATH" => "1..96 | ForEach-Object",
    "repeated activation" => "('call \"{0}\"' -f $activationHook)",
    "paired deactivation" => "('call \"{0}\"' -f $deactivationHook)",
    "internal command-output rejection" =>
      '$activationOutput -match "__OROCOS_ROCK_PATH_"',
    "relocated prefix validation" =>
      '-Name "OROCOS_TEST_ACTIVE_PREFIX"',
    "runtime discovery" =>
      '"@deployer-opcua-win32.exe --check --no-consolelog"',
    "PKG_CONFIG_LIBDIR restoration" =>
      '-Expected $preservedPkgConfigLibdir',
    "unset OROCOS_PREFIX restoration" =>
      'Assert-ValueAbsent -Environment $environment -Name "OROCOS_PREFIX"',
    "unset OROCOS_TARGET restoration" =>
      'Assert-ValueAbsent -Environment $environment -Name "OROCOS_TARGET"'
  }.each do |contract, token|
    unless activation_probe.include?(token)
      errors << "clean consumer activation probe must cover #{contract}"
    end
  end
  unless activation_probe.match?(/^\s*\[int\]\$MaximumSeconds = 30\s*$/)
    errors << "clean consumer activation probe must cover a 30-second default gate"
  end
  unless activation_probe.scan(/\$activationHook\)/).size >= 2 &&
         activation_probe.scan(/\$deactivationHook\)/).size >= 2
    errors << "clean consumer activation probe must repeat both lifecycle hooks"
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
    "the long-PATH activation probe" =>
      "probe-windows-conda-activation.ps1",
    "OroGen" => "orogen --version",
    "Typegen" => "typegen --help",
    "the OPC UA deployer" => "deployer-opcua-win32.exe --check --no-consolelog"
  }.each do |contract, token|
    errors << "consumer smoke test must check #{contract}" unless consumer.include?(token)
  end
  encoded_command_transport = [
    "$encodedCommand = [Convert]::ToBase64String(",
    "[Text.Encoding]::Unicode.GetBytes($Command)",
    '"-EncodedCommand", $encodedCommand'
  ]
  unless encoded_command_transport.all? { |token| consumer.include?(token) }
    errors << "consumer smoke test must encode child PowerShell commands"
  end

  activation_sources = consumer.scan(
    /^[ \t]*\.[ \t]+\$env:OROCOS_PIXI_ACTIVATION_SCRIPT[ \t]*\r?$/
  )
  unless activation_sources.size == 1
    errors << "consumer smoke test must source the shared Pixi activation wrapper only for development"
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

  runtime_body = powershell_here_string(consumer, "runtimeCommand")
  development_body = powershell_here_string(consumer, "developmentCommand")
  if runtime_body&.include?("OROCOS_PIXI_ACTIVATION_SCRIPT") ||
     runtime_body&.match?(/(?:dev-)?env\.ps1/i)
    errors << "runtime consumer must rely only on package-owned activation"
  end
  unless development_body&.scan(
      /^[ \t]*\.[ \t]+\$env:OROCOS_PIXI_ACTIVATION_SCRIPT[ \t]*\r?$/
    )&.size == 1
    errors << "development consumer must source the shared Pixi activation wrapper once"
  end
  {
    "the package-owned runtime prefix" => "$expectedPrefix",
    "the activated Orocos prefix" => "$env:OROCOS_PREFIX",
    "the win32 target" => '$env:OROCOS_TARGET -ne "win32"',
    "case-insensitive relocated-prefix comparison" => "OrdinalIgnoreCase",
    "runtime command discovery" => "Get-Command deployer-opcua-win32.exe"
  }.each do |contract, token|
    unless runtime_body&.include?(token)
      errors << "runtime consumer must check #{contract}"
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
