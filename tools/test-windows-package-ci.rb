#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FIXTURE_PATHS = %w[
  .github/workflows/windows-packages.yml
  examples/pixi-consumer/scripts/activate-orocos.ps1
  packaging/conda/build.ps1
  packaging/conda/orocos-activate.bat
  packaging/conda/recipe.yaml
  packaging/conda/stage-runtime-hook.ps1
  packaging/conda/test-runtime.ps1
  tools/check-windows-package-ci.rb
  tools/build-windows-msvc.ps1
  tools/export-windows-env.ps1
  tools/prepare-windows-conda-release.ps1
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
consumer_mutations = {
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
  "reused published Windows build number" => [
    "Windows package recipe build number must be greater than published build 0",
    lambda do |contents|
      contents.sub(
        /^  build_number: \d+$/,
        "  build_number: 0"
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
  "development package claims runtime batch" => [
    "orocos-dev output must explicitly exclude the generated batch runtime entrypoint",
    lambda do |contents|
      replace_occurrence(contents, "              - Library/env.bat\n", "", 1)
    end
  ],
  "missing activation hook recipe source" => [
    "Windows package recipe must include the Conda activation hook source",
    ->(contents) { contents.sub("        - packaging/conda/orocos-activate.bat\n", "") }
  ],
  "missing runtime hook staging script source" => [
    "Windows package recipe must include the runtime hook staging script source",
    ->(contents) { contents.sub("        - packaging/conda/stage-runtime-hook.ps1\n", "") }
  ],
  "missing runtime output hook staging script" => [
    "orocos runtime output must stage its activation hook after build environment activation",
    ->(contents) { contents.sub("        file: stage-runtime-hook.ps1\n", "") }
  ]
}

build_mutations = {
  "activation hook staged by shared build cache" => [
    "Windows shared staging cache must not install the runtime activation hook",
    lambda do |contents|
      contents + "\n" +
        '$activationHookSource = Join-Path $repositoryRoot "packaging\conda\orocos-activate.bat"' +
        "\n"
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
    "Windows runtime output must stage the activation hook copy",
    ->(contents) { contents.sub("Copy-Item", "Write-Output") }
  ]
}

hook_mutations = {
  "activation hook calls PowerShell entrypoint" => [
    "Windows package activation hook must only call Library\\env.bat and propagate failure",
    ->(contents) { contents.sub("Library\\env.bat", "Library\\env.ps1") }
  ],
  "activation hook omits Conda mode" => [
    "Windows package activation hook must only call Library\\env.bat and propagate failure",
    ->(contents) { contents.sub('Library\\env.bat" --conda', 'Library\\env.bat"') }
  ]
}

safe_batch_scan = <<~'BATCH'.chomp
  @set "__OROCOS_ROCK_PATH_SCAN=%__OROCOS_ROCK_PATH_INPUT:~1%"
  :orocos_deduplicate_next_path_value
  @if not defined __OROCOS_ROCK_PATH_SCAN goto orocos_deduplicate_path_done
  @if not "%__OROCOS_ROCK_PATH_SCAN:~0,1%"==";" goto orocos_split_next_path_value
  @set "__OROCOS_ROCK_PATH_SCAN=%__OROCOS_ROCK_PATH_SCAN:~1%"
  @goto orocos_deduplicate_next_path_value

  :orocos_split_next_path_value
  @for /f "tokens=1,* delims=;" %%E in ("%__OROCOS_ROCK_PATH_SCAN%") do set "__OROCOS_ROCK_PATH_CURRENT=%%E"
  @for /f "tokens=1,* delims=;" %%E in ("%__OROCOS_ROCK_PATH_SCAN%") do set "__OROCOS_ROCK_PATH_SCAN=%%F"
  @set "__OROCOS_ROCK_PATH_COMPARE=%__OROCOS_ROCK_PATH_NEW:~1%"

  :orocos_compare_next_path_value
  @if not defined __OROCOS_ROCK_PATH_COMPARE goto orocos_append_unique_path_value
  @for /f "tokens=1,* delims=;" %%E in ("%__OROCOS_ROCK_PATH_COMPARE%") do set "__OROCOS_ROCK_PATH_COMPARISON=%%E"
  @for /f "tokens=1,* delims=;" %%E in ("%__OROCOS_ROCK_PATH_COMPARE%") do set "__OROCOS_ROCK_PATH_COMPARE=%%F"
  @if /I "%__OROCOS_ROCK_PATH_CURRENT%"=="%__OROCOS_ROCK_PATH_COMPARISON%" goto orocos_deduplicate_next_path_value
  @goto orocos_compare_next_path_value

  :orocos_append_unique_path_value
  @set "__OROCOS_ROCK_PATH_NEW=%__OROCOS_ROCK_PATH_NEW%;%__OROCOS_ROCK_PATH_CURRENT%"
  @goto orocos_deduplicate_next_path_value
BATCH

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
    "generated env.bat must not use scoped activation or helper subprocesses",
    ->(contents) { contents.sub("@rem Call this file", "@setlocal\n@rem Call this file") }
  ],
  "batch activation rebuilds Conda-owned PATH" => [
    "generated env.bat must implement Conda-owned PATH preservation",
    lambda do |contents|
      contents.sub(
        '@if /I "%~1"=="--conda" goto orocos_runtime_path_ready',
        '@rem missing Conda PATH boundary'
      )
    end
  ],
  "batch dedup combines FOR and batch parameter expansion" => [
    "generated env.bat must avoid native cmd FOR/batch-parameter parser ambiguity",
    lambda do |contents|
      replace_normalized(
        contents,
        safe_batch_scan,
        '@for %%E in ("%__OROCOS_ROCK_PATH_NEW:;=" "%") do if /I "%%~E"=="%~1" exit /b 0'
      )
    end
  ],
  "batch dedup combines string substitution and FOR path modifier" => [
    "generated env.bat must avoid native cmd FOR/path-modifier parser ambiguity",
    lambda do |contents|
      replace_normalized(
        contents,
        safe_batch_scan,
        '@for %%E in ("%__OROCOS_ROCK_PATH_NEW:;=" "%") do if /I "%%~E"=="%__OROCOS_ROCK_PATH_CANDIDATE%" set "__OROCOS_ROCK_PATH_DUPLICATE=1"'
      )
    end
  ],
  "batch dedup compares quoted candidates inside FOR" => [
    "generated env.bat must not compare deduplication candidates inside FOR",
    lambda do |contents|
      replace_normalized(
        contents,
        safe_batch_scan,
        '@for %%E in ("%__OROCOS_ROCK_PATH_NEW:;=" "%") do if /I %%E=="%__OROCOS_ROCK_PATH_CANDIDATE%" set "__OROCOS_ROCK_PATH_DUPLICATE=1"'
      )
    end
  ],
  "batch dedup uses a nested comparison call" => [
    "generated env.bat must compare deduplication candidates without nested batch calls",
    lambda do |contents|
      replace_normalized(
        contents,
        safe_batch_scan,
        '@for %%E in ("%__OROCOS_ROCK_PATH_NEW:;=" "%") do call :orocos_compare_path_value "%%~E"'
      )
    end
  ],
  "batch dedup omits the separate comparison" => [
    "generated env.bat must collect paths before a separate deduplication pass",
    lambda do |contents|
      contents.sub(
        '@if /I "%__OROCOS_ROCK_PATH_CURRENT%"=="%__OROCOS_ROCK_PATH_COMPARISON%" goto orocos_deduplicate_next_path_value',
        '@rem missing separate comparison'
      )
    end
  ],
  "batch inherited paths use inline substitution" => [
    "generated env.bat must scan inherited paths without inline substitution",
    lambda do |contents|
      contents.sub(
        '@set "__OROCOS_ROCK_PATH_INPUT=%__OROCOS_ROCK_PATH_INPUT%;%__OROCOS_ROCK_PATH_OLD%"',
        '@for %%E in ("%__OROCOS_ROCK_PATH_OLD:;=" "%") do call :orocos_add_path_value "%%~E"'
      )
    end
  ],
  "batch collection and deduplication are not separated" => [
    "generated env.bat must collect paths before a separate deduplication pass",
    lambda do |contents|
      contents.sub(
        '@set "__OROCOS_ROCK_PATH_INPUT=%__OROCOS_ROCK_PATH_INPUT%;%~1"',
        '@call :orocos_add_path_value "%~1"'
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
  "runtime test omits a Rattler-length inherited PATH" => [
    "Windows runtime package test must cover a Rattler-length inherited PATH",
    ->(contents) { contents.sub("$rattlerPathEntries = @(", "$shortPathEntries = @(") }
  ],
  "runtime test weakens exact Conda PATH preservation" => [
    "Windows runtime package test must preserve Conda PATH with case-sensitive equality",
    lambda do |contents|
      replace_occurrence(
        contents,
        "Assert-EnvironmentValueExact",
        "Assert-EnvironmentValue",
        1
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
  ]
}

builder_mutations = {
  "missing direct boost-functional dependency" => [
    "Windows builder must install boost-functional directly for RTT headers",
    lambda do |contents|
      contents.sub(/^\s*"boost-functional:\$\{VcpkgTriplet\}"\s*`?\r?\n/, "")
    end
  ]
}

accepted_mutations = []
wrong_rejections = []
{
  ".github/workflows/windows-packages.yml" => mutations,
  "tools/test-windows-conda-consumer.ps1" => consumer_mutations,
  "examples/pixi-consumer/scripts/activate-orocos.ps1" => wrapper_mutations,
  "packaging/conda/recipe.yaml" => recipe_mutations,
  "packaging/conda/build.ps1" => build_mutations,
  "packaging/conda/orocos-activate.bat" => hook_mutations,
  "packaging/conda/stage-runtime-hook.ps1" => runtime_stage_mutations,
  "packaging/conda/test-runtime.ps1" => runtime_test_mutations,
  "tools/build-windows-msvc.ps1" => builder_mutations,
  "tools/export-windows-env.ps1" => exporter_mutations
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
