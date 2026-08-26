#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FIXTURE_PATHS = %w[
  .github/workflows/windows-packages.yml
  .github/workflows/windows-msvc.yml
  examples/pixi-consumer/scripts/activate-orocos.ps1
  packaging/conda/build.ps1
  packaging/conda/orocos-activate.bat
  packaging/conda/orocos-deactivate.bat
  packaging/conda/recipe-linux.yaml
  packaging/conda/recipe.yaml
  packaging/conda/stage-runtime-hook.ps1
  packaging/conda/test-dev.ps1
  packaging/conda/test-runtime.ps1
  pixi.toml
  tools/check-windows-package-ci.rb
  tools/build-windows-msvc.ps1
  tools/export-windows-env.ps1
  tools/prepare-windows-conda-release.ps1
  tools/probe-windows-conda-activation.ps1
  tools/test-windows-conda-consumer.ps1
].freeze

MUTABLE_ACTIONS = {
  "actions/checkout" => "v6",
  "prefix-dev/setup-pixi" => "v0.10.1",
  "actions/cache" => "v6",
  "actions/upload-artifact" => "v7",
  "actions/download-artifact" => "v8"
}.freeze

def with_fixture
  Dir.mktmpdir("orocos-windows-package-ci-") do |root|
    FIXTURE_PATHS.each do |relative|
      destination = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(ROOT, relative), destination)
    end
    yield root
  end
end

def run_checker(root)
  Open3.capture3(
    RbConfig.ruby,
    File.join(root, "tools", "check-windows-package-ci.rb"),
    chdir: root
  )
end

def remove_ancestry_step(contents, occurrence)
  pattern = /^      - name: Verify release commit is reachable from main\n.*?(?=^      - name:|\z)/m
  matches = contents.to_enum(:scan, pattern).map { Regexp.last_match }
  match = matches[occurrence]
  return contents unless match

  contents[0...match.begin(0)] + contents[match.end(0)..]
end

def mutate_publish_job(contents)
  publish_index = contents.index("  publish-packages:")
  return contents unless publish_index

  contents[0...publish_index] + yield(contents[publish_index..])
end

def replace_occurrence(contents, needle, replacement, occurrence)
  offset = 0
  index = nil
  (occurrence + 1).times do
    index = contents.index(needle, offset)
    return contents unless index

    offset = index + needle.length
  end
  contents[0...index] + replacement + contents[(index + needle.length)..]
end

def replace_normalized(contents, needle, replacement)
  line_ending = contents.include?("\r\n") ? "\r\n" : "\n"
  normalized = contents.gsub("\r\n", "\n")
  normalized.sub(needle, replacement).gsub("\n", line_ending)
end

with_fixture do |root|
  _stdout, stderr, status = run_checker(root)
  raise "real Windows package policy is invalid:\n#{stderr}" unless status.success?
end

publish_condition_error =
  "Prefix publication condition must exactly require the approved release event and repository"
license_stager_trigger = %(      - "tools/stage-license-corpus.rb"\n)
mutations = {
  "non-platform-first package build name" => [
    "Windows package build check must use the platform-first display name",
    lambda do |contents|
      contents.sub(
        "name: Windows packages / build and test",
        "name: Build And Test Windows Packages"
      )
    end
  ],
  "non-platform-first package publish name" => [
    "Windows package publish check must use the platform-first display name",
    lambda do |contents|
      contents.sub(
        "name: Windows packages / publish to Prefix",
        "name: Publish Windows Packages To Prefix"
      )
    end
  ],
  "missing license stager pull-request trigger" => [
    "Windows package CI pull requests must watch tools/stage-license-corpus.rb",
    lambda do |contents|
      replace_occurrence(contents, license_stager_trigger, "", 0)
    end
  ],
  "missing license stager push trigger" => [
    "Windows package CI main pushes must watch tools/stage-license-corpus.rb",
    lambda do |contents|
      replace_occurrence(contents, license_stager_trigger, "", 1)
    end
  ],
  "release tag interpolation in build PowerShell" => [
    "Windows package CI must not interpolate GitHub expressions into run scripts",
    lambda do |contents|
      contents.sub(
        "run: pixi run --locked package-render",
        'run: pixi run --locked package-render "${{ github.event.release.tag_name }}"'
      )
    end
  ],
  "release tag bracket interpolation in build PowerShell" => [
    "Windows package CI must not interpolate GitHub expressions into run scripts",
    lambda do |contents|
      contents.sub(
        "run: pixi run --locked package-render",
        %q{run: pixi run --locked package-render "${{ github.event['release']['tag_name'] }}"}
      )
    end
  ],
  "release tag interpolation in PowerShell" => [
    "Windows package CI must not interpolate GitHub expressions into run scripts",
    lambda do |contents|
      contents.sub(
        /-ExpectedTag\s+(?:\$env:EXPECTED_RELEASE_TAG|"\$\{\{ github\.event\.release\.tag_name \}\}")/,
        '-ExpectedTag "${{ github.event.release.tag_name }}"'
      )
    end
  ],
  "release object interpolation in build PowerShell" => [
    "Windows package CI must not interpolate GitHub expressions into run scripts",
    lambda do |contents|
      contents.sub(
        "run: pixi run --locked package-render",
        'run: pixi run --locked package-render "${{ toJSON(github.event.release) }}"'
      )
    end
  ],
  "release condition with || true" => [
    publish_condition_error,
    lambda do |contents|
      mutate_publish_job(contents) do |publish_job|
        publish_job.sub(/github\.repository == '[^']+'/) { |guard| "#{guard} || true" }
      end
    end
  ],
  "release condition with || replacing &&" => [
    publish_condition_error,
    lambda do |contents|
      contents.sub("github.event_name == 'release' &&", "github.event_name == 'release' ||")
    end
  ],
  "negated prerelease guard" => [
    publish_condition_error,
    lambda do |contents|
      mutate_publish_job(contents) do |publish_job|
        publish_job.sub(
          "github.event.release.prerelease == false",
          "!(github.event.release.prerelease == false)"
        )
      end
    end
  ],
  "weakened repository guard" => [
    publish_condition_error,
    lambda do |contents|
      mutate_publish_job(contents) do |publish_job|
        publish_job.sub(/github\.repository == '[^']+'/) do |guard|
          "(#{guard} || github.repository_owner == 'wrong-owner')"
        end
      end
    end
  ],
  "weakened event guard" => [
    publish_condition_error,
    lambda do |contents|
      mutate_publish_job(contents) do |publish_job|
        publish_job.sub(
          "github.event_name == 'release'",
          "(github.event_name == 'release' || github.event_name == 'workflow_dispatch')"
        )
      end
    end
  ],
  "missing build release gate" => [
    "Windows package build must reject unauthorized release events exactly",
    lambda do |contents|
      contents.sub(
        /^(  build-packages:\n    name:[^\n]*\n)    if: >-\n(?:      [^\n]*\n)+(?=    runs-on:)/,
        "\\1"
      )
    end
  ],
  "missing build ancestry check" => [
    "Windows package build must check release ancestry immediately after checkout",
    ->(contents) { remove_ancestry_step(contents, 0) }
  ],
  "missing publish ancestry check" => [
    "Prefix publication must check release ancestry immediately after checkout",
    ->(contents) { remove_ancestry_step(contents, 1) }
  ],
  "weakened ancestry command" => [
    "Windows package build ancestry check must fail closed against freshly fetched protected main",
    lambda do |contents|
      contents.sub(
        "git merge-base --is-ancestor $env:GITHUB_SHA $protectedMainRef",
        "git merge-base $env:GITHUB_SHA $protectedMainRef"
      )
    end
  ],
  "shallow checkout" => [
    "Windows package build checkout must use the event SHA, full history, and no persisted credentials",
    ->(contents) { contents.sub("fetch-depth: 0", "fetch-depth: 1") }
  ],
  "unapproved reusable workflow job" => [
    "Windows package CI must define exactly the approved jobs",
    lambda do |contents|
      contents + "\n  unapproved-publish:\n" \
                 "    uses: attacker/example/.github/workflows/publish.yml@main\n" \
                 "    secrets: inherit\n" \
                 "    permissions: write-all\n"
    end
  ],
  "missing persistent vcpkg root" => [
    "Windows package CI must place the reusable vcpkg root outside disposable package paths",
    ->(contents) { contents.sub(/^  OROCOS_VCPKG_ROOT:.*\n/, "") }
  ],
  "installed vcpkg cache includes the checkout" => [
    "Windows package CI must cache only the exact compatible installed vcpkg tree",
    ->(contents) { contents.sub("path: .cache/vcpkg/root/installed", "path: .cache/vcpkg/root") }
  ],
  "installed vcpkg cache omits the source lock" => [
    "Windows package CI must cache only the exact compatible installed vcpkg tree",
    lambda do |contents|
      contents.sub(
        "hashFiles('packaging/source-lock.json', 'tools/build-windows-msvc.ps1')",
        "hashFiles('tools/build-windows-msvc.ps1')"
      )
    end
  ],
  "installed vcpkg cache uses a fallback key" => [
    "The installed vcpkg tree must not use compatibility-weakening restore keys",
    lambda do |contents|
      contents.sub(
        /^(          key: windows-vcpkg-installed[^\n]+\n)/,
        "\\1          restore-keys: windows-vcpkg-installed-v1-\n"
      )
    end
  ],
  "vcpkg caches omit the MSVC boundary" => [
    "Windows package CI must cache only the exact compatible installed vcpkg tree",
    lambda do |contents|
      contents.sub(
        '${{ steps.vcpkg-cache-compatibility.outputs.msvc }}',
        'unknown-msvc'
      )
    end
  ],
  "missing vcpkg MSVC identification" => [
    "Windows package CI must identify the exact MSVC compatibility boundary for vcpkg caches",
    ->(contents) { contents.sub("vswhere.exe", "compiler-locator.exe") }
  ],
  "missing reusable vcpkg verification" => [
    "Windows package CI must verify that Rattler populated the configured vcpkg root",
    ->(contents) { contents.sub('"installed\vcpkg\status"', '"missing\vcpkg\status"') }
  ]
}

MUTABLE_ACTIONS.each do |action, tag|
  mutations["mutable #{action} selection"] = [
    "Windows package CI actions must equal the approved full-SHA selections",
    lambda do |contents|
      contents.sub(/#{Regexp.escape(action)}@[^\s#]+/, "#{action}@#{tag}")
    end
  ]
end

shared_source = '    . $env:OROCOS_PIXI_ACTIVATION_SCRIPT'
child_error_preference = '    $ErrorActionPreference = "Stop"'
activation_probe_call =
  '    & $env:OROCOS_CONDA_ACTIVATION_PROBE -CondaPrefix $env:CONDA_PREFIX'
consumer_mutations = {
  "missing long-PATH activation probe" => [
    "consumer smoke test must check the long-PATH activation probe",
    lambda do |contents|
      contents.sub(
        "probe-windows-conda-activation.ps1",
        "missing-windows-conda-activation.ps1"
      )
    end
  ],
  "runtime consumer skips activation probe" => [
    "consumer smoke test must probe package activation in runtime and development environments",
    lambda do |contents|
      replace_occurrence(contents, activation_probe_call, "", 0)
    end
  ],
  "development consumer skips activation probe" => [
    "consumer smoke test must probe package activation in runtime and development environments",
    lambda do |contents|
      replace_occurrence(contents, activation_probe_call, "", 1)
    end
  ],
  "runtime shared wrapper source" => [
    "runtime consumer must rely only on package-owned activation",
    lambda do |contents|
      replace_occurrence(
        contents,
        child_error_preference,
        "#{child_error_preference}\n#{shared_source}",
        0
      )
    end
  ],
  "missing development shared wrapper source" => [
    "consumer smoke test must source the shared Pixi activation wrapper only for development",
    ->(contents) { contents.sub(/^#{Regexp.escape(shared_source)}\r?\n/, "") }
  ],
  "direct runtime installed activation source" => [
    "consumer smoke test must not source installed activation scripts directly",
    lambda do |contents|
      replace_occurrence(
        contents,
        child_error_preference,
        "#{child_error_preference}\n" +
          %q{    . (Join-Path $env:CONDA_PREFIX 'Library\env.ps1')},
        0
      )
    end
  ],
  "direct development installed activation source" => [
    "consumer smoke test must not source installed activation scripts directly",
    lambda do |contents|
      replace_occurrence(
        contents,
        shared_source,
        %q{    . (Join-Path $env:CONDA_PREFIX 'Library\dev-env.ps1')},
        0
      )
    end
  ],
  "wrong project-relative activation wrapper path" => [
    "consumer smoke test must resolve the project-relative PowerShell wrapper",
    lambda do |contents|
      contents.sub(
        '        Join-Path $PSScriptRoot "..\examples\pixi-consumer\scripts\activate-orocos.ps1"',
        '        Join-Path $PSScriptRoot "..\examples\wrong-consumer\scripts\activate-orocos.ps1"'
      )
    end
  ],
  "missing runtime child terminating-error preference" => [
    "consumer smoke test runtime child must stop on PowerShell errors",
    ->(contents) { replace_occurrence(contents, child_error_preference, "", 0) }
  ],
  "missing development child terminating-error preference" => [
    "consumer smoke test development child must stop on PowerShell errors",
    ->(contents) { replace_occurrence(contents, child_error_preference, "", 1) }
  ],
  "missing runtime prefix assertion" => [
    "runtime consumer must check the package-owned runtime prefix",
    ->(contents) { contents.gsub("$expectedPrefix", "$wrongPrefix") }
  ],
  "weakened runtime target assertion" => [
    "runtime consumer must check the win32 target",
    ->(contents) { contents.sub('$env:OROCOS_TARGET -ne "win32"', '$env:OROCOS_TARGET -ne "wrong"') }
  ],
  "case-sensitive runtime prefix comparison" => [
    "runtime consumer must check case-insensitive relocated-prefix comparison",
    ->(contents) { contents.sub("OrdinalIgnoreCase", "Ordinal") }
  ],
  "raw child command transport" => [
    "consumer smoke test must encode child PowerShell commands",
    lambda do |contents|
      contents.sub('"-EncodedCommand", $encodedCommand', '"-Command", $Command')
    end
  ],
  "UTF-8 child command encoding" => [
    "consumer smoke test must encode child PowerShell commands",
    lambda do |contents|
      contents.sub(
        "[Text.Encoding]::Unicode.GetBytes($Command)",
        "[Text.Encoding]::UTF8.GetBytes($Command)"
      )
    end
  ]
}

wrapper_mutations = {
  "changed runtime activation filename" => [
    "consumer activation wrapper must check the runtime activation contract",
    ->(contents) { contents.sub('-ChildPath "env.ps1"', '-ChildPath "missing-env.ps1"') }
  ],
  "removed runtime activation selector" => [
    "consumer activation wrapper must check the runtime activation contract",
    ->(contents) { contents.sub(/^\$runtimeScript = .*\r?\n/, "") }
  ],
  "changed development activation filename" => [
    "consumer activation wrapper must check the development activation contract",
    ->(contents) { contents.sub('-ChildPath "dev-env.ps1"', '-ChildPath "missing-dev-env.ps1"') }
  ],
  "removed development activation selector" => [
    "consumer activation wrapper must check the development activation contract",
    ->(contents) { contents.sub(/^\$developmentScript = .*\r?\n/, "") }
  ]
}

recipe_mutations = {
  "desynchronized Windows package version" => [
    "Linux and Windows package recipes must use the same version and build number",
    lambda do |contents|
      contents.sub(
        /^  version: "[^"]+"$/,
        '  version: "999.0.0"'
      )
    end
  ],
  "negative Windows build number" => [
    "Windows package recipe build number must be a non-negative integer",
    lambda do |contents|
      contents.sub(
        /^  build_number: \d+$/,
        "  build_number: -1"
      )
    end
  ],
  "missing runtime batch package ownership" => [
    "orocos runtime output must own and test the generated batch runtime entrypoint",
    lambda do |contents|
      replace_occurrence(contents, "          - Library/env.bat\n", "", 0)
    end
  ],
  "missing runtime hook package ownership" => [
    "orocos runtime output must own and test the Conda runtime activation hook",
    lambda do |contents|
      replace_occurrence(
        contents,
        "          - etc/conda/activate.d/orocos-activate.bat\n",
        "",
        0
      )
    end
  ],
  "missing runtime deactivation hook package ownership" => [
    "orocos runtime output must own and test the Conda runtime deactivation hook",
    lambda do |contents|
      replace_occurrence(
        contents,
        "          - etc/conda/deactivate.d/orocos-deactivate.bat\n",
        "",
        0
      )
    end
  ],
  "development package claims runtime batch" => [
    "orocos-dev output must explicitly exclude the generated batch runtime entrypoint",
    lambda do |contents|
      replace_occurrence(contents, "              - Library/env.bat\n", "", 1)
    end
  ],
  "missing activation hook recipe source" => [
    "Windows package recipe must include the Conda activation hook source exactly once",
    ->(contents) { contents.sub("        - packaging/conda/orocos-activate.bat\n", "") }
  ],
  "missing deactivation hook recipe source" => [
    "Windows package recipe must include the Conda deactivation hook source exactly once",
    ->(contents) { contents.sub("        - packaging/conda/orocos-deactivate.bat\n", "") }
  ],
  "development package claims runtime deactivation hook" => [
    "orocos-dev output must explicitly exclude the Conda runtime deactivation hook",
    lambda do |contents|
      replace_occurrence(
        contents,
        "              - etc/conda/deactivate.d/orocos-deactivate.bat\n",
        "",
        1
      )
    end
  ],
  "missing runtime hook staging script source" => [
    "Windows package recipe must include the runtime hook staging script source",
    ->(contents) { contents.sub("        - packaging/conda/stage-runtime-hook.ps1\n", "") }
  ],
  "missing runtime output hook staging script" => [
    "orocos runtime output must stage its activation hook after build environment activation",
    ->(contents) { contents.sub("        file: stage-runtime-hook.ps1\n", "") }
  ],
  "missing clean development package acceptance" => [
    "orocos-dev must run the clean generator package acceptance test",
    ->(contents) { contents.sub(/^\s+- script: test-dev\.ps1\r?\n/, "") }
  ],
  "recipe omits isolated vcpkg cache forwarding" => [
    "Windows package recipe must explicitly forward isolated vcpkg cache paths",
    ->(contents) { contents.sub(/^\s+OROCOS_VCPKG_ROOT:.*\r?\n/, "") }
  ],
  "recipe omits Ninja" => [
    "Windows package recipe must provide the locked Ninja build tool",
    ->(contents) { contents.sub(/^\s+- ninja .*\r?\n/, "") }
  ]
}

build_mutations = {
  "activation hook staged by shared build cache" => [
    "Windows shared staging cache must not install runtime lifecycle hooks",
    lambda do |contents|
      contents + "\n" +
        '$activationHookSource = Join-Path $repositoryRoot "packaging\conda\orocos-activate.bat"' +
        "\n"
    end
  ],
  "package staging retains duplicate generator smoke tests" => [
    "Windows package staging must skip duplicated generator smoke tests",
    ->(contents) { contents.sub(/^\s*-SkipGeneratorSmokeTests\r?\n/, "") }
  ],
  "package staging ignores the persistent vcpkg root" => [
    "Windows package staging must use an absolute configured vcpkg root with a disposable fallback",
    ->(contents) { contents.sub('"OROCOS_VCPKG_ROOT"', '"IGNORED_VCPKG_ROOT"') }
  ],
  "package staging omits the cache readiness marker" => [
    "Windows package staging must use an absolute configured vcpkg root with a disposable fallback",
    ->(contents) { contents.sub('".orocos-package-cache-ready"', '".missing-cache-marker"') }
  ],
  "package staging falls back to Visual Studio" => [
    "Windows package staging must use Ninja with scoped external warning suppression",
    ->(contents) { contents.sub("-Generator Ninja", '-Generator "Visual Studio 17 2022"') }
  ],
  "package staging omits scoped warning suppression" => [
    "Windows package staging must use Ninja with scoped external warning suppression",
    ->(contents) { contents.sub(/^\s*-SuppressExternalWarnings\s*`?\r?\n/, "") }
  ]
}

development_test_mutations = {
  "development package omits the OroGen install" => [
    "Windows development package test must generate and install a clean OroGen project",
    ->(contents) { contents.sub("cmake --build $orogenBuild", "cmake --build $wrongBuild") }
  ],
  "development package omits Typegen regeneration" => [
    "Windows development package test must generate, regenerate, and install a clean Typegen project",
    ->(contents) { contents.sub("--target regen", "--target wrong") }
  ],
  "development package suppresses maintained angle headers" => [
    "Windows development package test must keep Orocos header warnings visible",
    lambda do |contents|
      contents.sub(
        '$externalOptions += "/external:W0"',
        '$externalOptions += "/external:anglebrackets /external:W0"'
      )
    end
  ],
  "development package omits C++ exception semantics" => [
    "Windows development package test must retain MSVC C++ exception semantics",
    ->(contents) { contents.sub('/EHsc', '/EHs-') }
  ]
}

native_workflow_mutations = {
  "native workflow skips generator smoke tests" => [
    "Windows native CI must retain generator smoke tests",
    lambda do |contents|
      replace_normalized(
        contents,
        '-OrogenRef "$env:OROGEN_REF" 2>&1 |',
        "-OrogenRef \"$env:OROGEN_REF\" `\n            -SkipGeneratorSmokeTests 2>&1 |"
      )
    end
  ],
  "native workflow suppresses maintained warnings" => [
    "Windows native CI must retain Visual Studio and maintained warning coverage",
    lambda do |contents|
      replace_normalized(
        contents,
        '-OrogenRef "$env:OROGEN_REF" 2>&1 |',
        "-OrogenRef \"$env:OROGEN_REF\" `\n            -SuppressExternalWarnings 2>&1 |"
      )
    end
  ]
}

pixi_manifest_mutations = {
  "default Windows task skips generator smoke tests" => [
    "the default Windows build task must retain generator smoke tests",
    lambda do |contents|
      replace_normalized(
        contents,
        '    "tools/build-windows-msvc.ps1",',
        "    \"tools/build-windows-msvc.ps1\",\n    \"-SkipGeneratorSmokeTests\","
      )
    end
  ],
  "default Windows task selects Ninja" => [
    "the default Windows build task must retain Visual Studio and maintained warning coverage",
    lambda do |contents|
      replace_normalized(
        contents,
        '    "tools/build-windows-msvc.ps1",',
        "    \"tools/build-windows-msvc.ps1\",\n    \"-Generator\",\n    \"Ninja\","
      )
    end
  ]
}

runtime_stage_mutations = {
  "activation hook staged below Library prefix" => [
    "Windows runtime output must stage the Conda prefix activation directory",
    lambda do |contents|
      contents.sub(
        'Join-Path $env:PREFIX "etc\conda\activate.d"',
        'Join-Path $env:LIBRARY_PREFIX "etc\conda\activate.d"'
      )
    end
  ],
  "missing runtime activation hook copy" => [
    "Windows runtime output must copy exactly two lifecycle hooks",
    ->(contents) { contents.sub("Copy-Item", "Write-Output") }
  ],
  "deactivation hook staged below Library prefix" => [
    "Windows runtime output must stage the Conda prefix deactivation directory",
    lambda do |contents|
      contents.sub(
        'Join-Path $env:PREFIX "etc\conda\deactivate.d"',
        'Join-Path $env:LIBRARY_PREFIX "etc\conda\deactivate.d"'
      )
    end
  ],
  "missing runtime deactivation hook copy" => [
    "Windows runtime output must copy exactly two lifecycle hooks",
    lambda do |contents|
      replace_occurrence(contents, "Copy-Item", "Write-Output", 1)
    end
  ]
}

hook_mutations = {
  "activation hook calls PowerShell entrypoint" => [
    "Windows package activation hook must preserve lifecycle state, call Library\\env.bat in Conda mode, and propagate failure",
    ->(contents) { contents.sub("Library\\env.bat", "Library\\env.ps1") }
  ],
  "activation hook omits Conda mode" => [
    "Windows package activation hook must preserve lifecycle state, call Library\\env.bat in Conda mode, and propagate failure",
    ->(contents) { contents.sub('Library\\env.bat" --conda', 'Library\\env.bat"') }
  ],
  "activation hook overwrites lifecycle backups" => [
    "Windows package activation hook must preserve lifecycle state, call Library\\env.bat in Conda mode, and propagate failure",
    lambda do |contents|
      contents.sub(
        "@if defined __OROCOS_ROCK_CONDA_ACTIVE @goto orocos_activate_runtime",
        "@rem missing repeated-activation guard"
      )
    end
  ],
  "activation hook does not roll back internal failure" => [
    "Windows package activation hook must preserve lifecycle state, call Library\\env.bat in Conda mode, and propagate failure",
    lambda do |contents|
      contents.sub(
        '@call "%~dp0..\deactivate.d\orocos-deactivate.bat"',
        '@rem missing activation failure rollback'
      )
    end
  ]
}

deactivation_hook_mutations = {
  "deactivation hook keeps the package loader path" => [
    "Windows package deactivation hook must restore the pre-activation environment and clean lifecycle state",
    lambda do |contents|
      contents.sub(
        '@set "PATH=%__OROCOS_ROCK_HOOK_PATH_NEW:~1%"',
        '@rem missing PATH cleanup'
      )
    end
  ],
  "deactivation hook does not restore a discovery variable" => [
    "Windows package deactivation hook must restore the pre-activation environment and clean lifecycle state",
    ->(contents) { contents.sub('@set "RTT_COMPONENT_PATH="', '@rem missing RTT restoration') }
  ],
  "deactivation hook leaks lifecycle state" => [
    "Windows package deactivation hook must restore the pre-activation environment and clean lifecycle state",
    lambda do |contents|
      contents.sub(
        '@set "__OROCOS_ROCK_CONDA_ACTIVE="',
        '@rem leaked lifecycle marker'
      )
    end
  ]
}

exporter_mutations = {
  "PowerShell path model emits a trailing array comma" => [
    "Windows environment exporter must not emit a trailing comma after the final PowerShell path expression",
    lambda do |contents|
      contents.sub(
        %q!"{0}(Join-Path `$Prefix '{1}')" -f!,
        %q!"{0}(Join-Path `$Prefix '{1}')," -f!
      )
    end
  ],
  "missing generated batch output" => [
    "Windows environment exporter must define the batch runtime output",
    ->(contents) { contents.sub('Join-Path $Prefix "env.bat"', 'Join-Path $Prefix "runtime.bat"') }
  ],
  "batch activation uses setlocal" => [
    "generated env.bat must not use scoped activation or non-system helper runtimes",
    ->(contents) { contents.sub("@rem Call this file", "@setlocal\n@rem Call this file") }
  ],
  "batch activation omits the Conda loader path branch" => [
    "generated env.bat must implement Conda-owned PATH preservation",
    lambda do |contents|
      contents.sub(
        '@if /I not "%~1"=="--conda" @goto orocos_full_runtime_path',
        '@rem missing Conda PATH boundary'
      )
    end
  ],
  "batch activation omits the Conda runtime loader directory" => [
    "generated env.bat must implement the Conda runtime loader directory",
    lambda do |contents|
      contents.sub(
        '@call :orocos_add_candidate "%OROCOS_PREFIX%\lib\orocos\@TARGET@\plugins"',
        '@rem missing Conda runtime loader directory'
      )
    end
  ],
  "batch membership loses case-insensitive matching" => [
    "generated env.bat must implement case-insensitive full-entry membership",
    lambda do |contents|
      contents.gsub(
        'findstr.exe" /I /L',
        'findstr.exe" /L'
      )
    end
  ],
  "batch membership expands a subroutine argument inside the pipeline" => [
    "generated env.bat must match existing candidates as complete case-insensitive entries",
    lambda do |contents|
      contents.sub(
        '@set "__OROCOS_ROCK_PATH_CANDIDATE=%~1"',
        '@set "__OROCOS_ROCK_PATH_CANDIDATE="'
      )
    end
  ],
  "batch membership does not escape findstr literal separators" => [
    "generated env.bat must match existing candidates as complete case-insensitive entries",
    lambda do |contents|
      contents.sub(
        /@set "__OROCOS_ROCK_PATH_PATTERN=[^"]+"/,
        '@set "__OROCOS_ROCK_PATH_PATTERN=%__OROCOS_ROCK_PATH_CANDIDATE%"'
      )
    end
  ],
  "batch membership queries an undefined path-like variable" => [
    "generated env.bat must match existing candidates as complete case-insensitive entries",
    lambda do |contents|
      contents.sub(
        '@if not defined %__OROCOS_ROCK_PATH_NAME% @goto orocos_add_candidate_missing',
        '@rem missing undefined-variable guard'
      )
    end
  ],
  "batch membership leaves whitespace before stderr redirection" => [
    "generated env.bat must match existing candidates as complete case-insensitive entries",
    lambda do |contents|
      contents.gsub(
        '@set %__OROCOS_ROCK_PATH_NAME% |',
        '@set %__OROCOS_ROCK_PATH_NAME% 2>nul |'
      )
    end
  ],
  "batch membership loses exact single-entry matching" => [
    "generated env.bat must match existing candidates as complete case-insensitive entries",
    lambda do |contents|
      contents.sub(
        '/L /X /C:"%__OROCOS_ROCK_PATH_NAME%=%__OROCOS_ROCK_PATH_PATTERN%"',
        '/L /C:"%__OROCOS_ROCK_PATH_NAME%=%__OROCOS_ROCK_PATH_PATTERN%"'
      )
    end
  ],
  "batch membership loses middle-entry boundaries" => [
    "generated env.bat must match existing candidates as complete case-insensitive entries",
    lambda do |contents|
      contents.sub(
        '/L /C:";%__OROCOS_ROCK_PATH_PATTERN%;"',
        '/L /C:"%__OROCOS_ROCK_PATH_PATTERN%"'
      )
    end
  ],
  "batch membership reintroduces inherited-value FOR scanning" => [
    "generated env.bat must not expand inherited PATH-like values while scanning entries",
    lambda do |contents|
      replace_normalized(
        contents,
        ":orocos_add_candidate\n",
        %q{:orocos_add_candidate
@for /f "tokens=1,* delims=;" %%E in ("%PATH%") do @set "OROCOS_UNSAFE=%%E"
}
      )
    end
  ],
  "batch membership expands inherited PATH before commit" => [
    "generated env.bat must preserve inherited PATH and expand it only for the final prepend",
    lambda do |contents|
      contents.sub(
        '@set "__OROCOS_ROCK_PATH_PREFIX="',
        '@set "__OROCOS_ROCK_PATH_PREFIX=%PATH%"'
      )
    end
  ],
  "batch activation drops internal failure propagation" => [
    "generated env.bat must implement internal failure propagation",
    lambda do |contents|
      contents.sub(
        /(\r?\n):orocos_runtime_failed(\r?\n)/,
        '\1:orocos_runtime_failure_ignored\2'
      )
    end
  ],
  "batch activation ignores final assignment failure" => [
    "generated env.bat must implement final assignment failure detection",
    lambda do |contents|
      contents.gsub(
        "__OROCOS_ROCK_PATH_COMMIT_OK",
        "OROCOS_PATH_COMMIT_UNCHECKED"
      )
    end
  ],
  "batch activation changes caller echo mode" => [
    "generated env.bat must not change the caller's echo mode",
    lambda do |contents|
      contents.sub(
        "@rem Call this file",
        "@echo off\n@rem Call this file"
      )
    end
  ]
}

runtime_test_mutations = {
  "runtime batch is not called twice" => [
    "Windows runtime package test must cover repeated activation",
    ->(contents) { contents.sub("-BatchPath $runtimeBatch -Calls 2", "-BatchPath $runtimeBatch") }
  ],
  "runtime test skips the package hook" => [
    "Windows runtime package test must cover the package activation hook",
    lambda do |contents|
      contents.sub(
        'Join-Path $condaPrefix "etc\conda\activate.d\orocos-activate.bat"',
        'Join-Path $condaPrefix "missing-orocos-activate.bat"'
      )
    end
  ],
  "runtime test skips the package deactivation hook" => [
    "Windows runtime package test must cover the package deactivation hook",
    lambda do |contents|
      contents.sub(
        'Join-Path $condaPrefix "etc\conda\deactivate.d\orocos-deactivate.bat"',
        'Join-Path $condaPrefix "missing-orocos-deactivate.bat"'
      )
    end
  ],
  "runtime test omits a Rattler-length inherited PATH" => [
    "Windows runtime package test must cover a Rattler-length inherited PATH",
    ->(contents) { contents.sub("$rattlerPathEntries = @(", "$shortPathEntries = @(") }
  ],
  "runtime test omits Rattler command echo" => [
    "Windows runtime package test must cover Rattler-style command echo",
    ->(contents) { contents.gsub("-EchoCommands", "-NoEchoCommands") }
  ],
  "runtime test omits internal command-output rejection" => [
    "Windows runtime package test must cover quiet internal PATH commands",
    lambda do |contents|
      contents.sub(
        '$script:BatchActivationOutput -match "__OROCOS_ROCK_PATH_"',
        '$script:BatchActivationOutput -match "OROCOS_TEST_UNUSED"'
      )
    end
  ],
  "runtime test weakens activation time gate" => [
    "Windows runtime package test must cover a bounded activation time",
    lambda do |contents|
      contents.sub(
        '$script:BatchActivationElapsed.TotalSeconds -gt 30',
        '$script:BatchActivationElapsed.TotalSeconds -gt 300'
      )
    end
  ],
  "runtime test omits internal failure propagation" => [
    "Windows runtime package test must cover internal failure propagation",
    ->(contents) { contents.sub("-ExpectedExitCode 1", "-ExpectedExitCode 0") }
  ],
  "runtime test omits exact consumer path preservation" => [
    "Windows runtime package test must cover exact consumer path preservation",
    lambda do |contents|
      contents.gsub(
        "Assert-PathValuePreservedAsSuffix",
        "Ignore-OriginalPathSuffix"
      )
    end
  ],
  "runtime test omits the Conda loader path prefix" => [
    "Windows runtime package test must prepend the loader path while preserving Conda PATH",
    lambda do |contents|
      contents.sub(
        '$hookExpectedPath = "$hookRuntimePlugins;$rattlerPath"',
        '$hookExpectedPath = $rattlerPath'
      )
    end
  ],
  "runtime test omits Conda discovery-variable coverage" => [
    "Windows runtime package test must cover Conda-mode discovery variables",
    lambda do |contents|
      contents.sub(
        /^\$hookPkgConfig = .*?^}\r?\n(?=\r?\n\$fixtureRoot)/m,
        ""
      )
    end
  ],
  "runtime test synthesizes the development pkg-config directory" => [
    "Windows runtime package test must use the actual split-package pkg-config layout",
    lambda do |contents|
      contents.sub(
        '$hookPkgConfigExpectedCount = 0',
        '$hookPkgConfigExpectedCount = 0' + "\n" +
          'New-Item -ItemType Directory -Path $hookPkgConfig'
      )
    end
  ],
  "runtime test expects the development pkg-config directory" => [
    "Windows runtime package test must cover Conda-mode discovery variables",
    ->(contents) { contents.sub('$hookPkgConfigExpectedCount = 0', '$hookPkgConfigExpectedCount = 1') }
  ],
  "runtime test ignores discovery-path expected counts" => [
    "Windows runtime package test must cover Conda-mode discovery variables",
    ->(contents) { contents.sub('-ExpectedCount $entry.Count', '-ExpectedCount 1') }
  ],
  "runtime test does not repeat deactivation" => [
    "Windows runtime package test must cover reversible and idempotent package hooks",
    ->(contents) { contents.sub("-FollowupCalls 2", "-FollowupCalls 1") }
  ],
  "runtime test inherits variables in the unset fixture" => [
    "Windows runtime package test must cover reversible and idempotent package hooks",
    lambda do |contents|
      contents.sub(
        '-RemoveEnvironmentVariables $hookManagedVariables',
        '-RemoveEnvironmentVariables @()'
      )
    end
  ],
  "runtime test omits hook-state cleanup assertions" => [
    "Windows runtime package test must cover reversible and idempotent package hooks",
    lambda do |contents|
      contents.sub(
        "function Assert-NoOrocosHookState {",
        "function Ignore-OrocosHookState {"
      )
    end
  ]
}

activation_probe_mutations = {
  "clean activation probe uses C-style quote escapes" => [
    "clean consumer activation probe must use PowerShell-compatible batch command quoting",
    lambda do |contents|
      contents.sub(
        %q{'@set "OROCOS_TEST_ACTIVE_PREFIX=%OROCOS_PREFIX%"'},
        %q{"@set \"OROCOS_TEST_ACTIVE_PREFIX=%OROCOS_PREFIX%\""}
      )
    end
  ],
  "clean activation probe disables command echo" => [
    "clean consumer activation probe must cover Rattler-style command echo",
    ->(contents) { contents.sub('"@echo on"', '"@echo off"') }
  ],
  "clean activation probe uses a short PATH" => [
    "clean consumer activation probe must cover a structured long PATH",
    ->(contents) { contents.sub("1..96 | ForEach-Object", "1..2 | ForEach-Object") }
  ],
  "clean activation probe assumes pkg-config directory exists" => [
    "clean consumer activation probe must cover split-package pkg-config directory semantics",
    lambda do |contents|
      contents.sub(
        '$pkgConfigExpectedCount = if (Test-Path -LiteralPath $pkgConfig -PathType Container)',
        '$pkgConfigExpectedCount = if ($true)'
      )
    end
  ],
  "clean activation probe hard-codes pkg-config expected count" => [
    "clean consumer activation probe must cover split-package pkg-config expected count",
    ->(contents) { contents.sub('Count = $pkgConfigExpectedCount', 'Count = 1') }
  ],
  "clean activation probe ignores structured expected counts" => [
    "clean consumer activation probe must cover structured discovery-path expected counts",
    ->(contents) { contents.sub('-ExpectedCount $entry.Count', '-ExpectedCount 1') }
  ],
  "clean activation probe skips repeated activation" => [
    "clean consumer activation probe must repeat both lifecycle hooks",
    lambda do |contents|
      replace_occurrence(
        contents,
        '(\'call "{0}"\' -f $activationHook)',
        '(\'call "{0}"\' -f $missingActivationHook)',
        1
      )
    end
  ],
  "clean activation probe omits internal output rejection" => [
    "clean consumer activation probe must cover internal command-output rejection",
    lambda do |contents|
      contents.sub(
        '$activationOutput -match "__OROCOS_ROCK_PATH_"',
        '$activationOutput -match "OROCOS_TEST_UNUSED"'
      )
    end
  ],
  "clean activation probe weakens its time gate" => [
    "clean consumer activation probe must cover a 30-second default gate",
    ->(contents) { contents.sub('[int]$MaximumSeconds = 30', '[int]$MaximumSeconds = 300') }
  ],
  "clean activation probe omits PKG_CONFIG_LIBDIR restoration" => [
    "clean consumer activation probe must cover PKG_CONFIG_LIBDIR restoration",
    ->(contents) { contents.sub('-Expected $preservedPkgConfigLibdir', '-Expected $preservedDiscoveryPath') }
  ],
  "clean activation probe leaves OROCOS_PREFIX set" => [
    "clean consumer activation probe must cover unset OROCOS_PREFIX restoration",
    lambda do |contents|
      contents.sub(
        'Assert-ValueAbsent -Environment $environment -Name "OROCOS_PREFIX"',
        'Assert-ValueAbsent -Environment $environment -Name "OROCOS_PREFIX_UNUSED"'
      )
    end
  ],
  "clean activation probe leaves OROCOS_TARGET set" => [
    "clean consumer activation probe must cover unset OROCOS_TARGET restoration",
    lambda do |contents|
      contents.sub(
        'Assert-ValueAbsent -Environment $environment -Name "OROCOS_TARGET"',
        'Assert-ValueAbsent -Environment $environment -Name "OROCOS_TARGET_UNUSED"'
      )
    end
  ]
}

builder_mutations = {
  "missing direct boost-functional dependency" => [
    "Windows builder must install boost-functional directly for RTT headers",
    lambda do |contents|
      contents.sub(/^\s*"boost-functional:\$\{VcpkgTriplet\}"\s*`?\r?\n/, "")
    end
  ],
  "missing package-only generator smoke switch" => [
    "Windows builder must define the package-only generator smoke skip switch",
    ->(contents) { contents.sub(/^\s*\[switch\]\$SkipGeneratorSmokeTests,\r?\n/, "") }
  ],
  "unguarded generator smoke work" => [
    "Windows builder must guard smoke builds, artifacts, and executions with the skip switch",
    ->(contents) { contents.gsub("if (-not $SkipGeneratorSmokeTests) {", "if ($true) {") }
  ],
  "builder loses Ninja generator layout" => [
    "Windows builder must support both Visual Studio and Ninja generator layouts",
    ->(contents) { contents.sub('$CMakeGeneratorArguments = @("-G", $Generator)', '$CMakeGeneratorArguments = @("-G", "Visual Studio 17 2022")') }
  ],
  "builder omits Ninja exception semantics" => [
    "Windows builder must retain C++ exception semantics with custom compiler flags",
    ->(contents) { contents.sub('$cxxOptions += "/EHsc"', '$cxxOptions += "/EHs-"') }
  ],
  "builder drops exceptions when suppressing Visual Studio warnings" => [
    "Windows builder must retain C++ exception semantics with custom compiler flags",
    lambda do |contents|
      contents.sub(
        '-EnableExceptions:((-not $IsVisualStudioGenerator) -or $SuppressExternalWarnings)',
        '-EnableExceptions:(-not $IsVisualStudioGenerator)'
      )
    end
  ],
  "builder suppresses maintained angle headers" => [
    "Windows builder must keep maintained Orocos header warnings visible",
    lambda do |contents|
      contents.sub(
        '$externalOptions += "/external:W0"',
        '$externalOptions += "/external:anglebrackets /external:W0"'
      )
    end
  ]
}

accepted_mutations = []
wrong_rejections = []
{
  ".github/workflows/windows-packages.yml" => mutations,
  ".github/workflows/windows-msvc.yml" => native_workflow_mutations,
  "tools/test-windows-conda-consumer.ps1" => consumer_mutations,
  "tools/probe-windows-conda-activation.ps1" => activation_probe_mutations,
  "examples/pixi-consumer/scripts/activate-orocos.ps1" => wrapper_mutations,
  "packaging/conda/recipe.yaml" => recipe_mutations,
  "packaging/conda/build.ps1" => build_mutations,
  "packaging/conda/orocos-activate.bat" => hook_mutations,
  "packaging/conda/orocos-deactivate.bat" => deactivation_hook_mutations,
  "packaging/conda/stage-runtime-hook.ps1" => runtime_stage_mutations,
  "packaging/conda/test-dev.ps1" => development_test_mutations,
  "packaging/conda/test-runtime.ps1" => runtime_test_mutations,
  "tools/build-windows-msvc.ps1" => builder_mutations,
  "tools/export-windows-env.ps1" => exporter_mutations,
  "pixi.toml" => pixi_manifest_mutations
}.each do |relative_path, file_mutations|
  file_mutations.each do |name, (expected_error, mutation)|
    with_fixture do |root|
      fixture_path = File.join(root, relative_path)
      File.write(fixture_path, mutation.call(File.read(fixture_path)))
      _stdout, stderr, status = run_checker(root)
      if status.success?
        accepted_mutations << name
      elsif !stderr.include?(expected_error)
        wrong_rejections << "#{name}: expected #{expected_error.inspect}, got #{stderr.inspect}"
      end
    end
  end
end

unless accepted_mutations.empty?
  raise "Windows package policy accepted unsafe mutation(s): #{accepted_mutations.join(', ')}"
end
unless wrong_rejections.empty?
  raise "Windows package policy rejected mutations for the wrong reason:\n#{wrong_rejections.join("\n")}"
end

puts "Windows package CI mutation tests passed."
