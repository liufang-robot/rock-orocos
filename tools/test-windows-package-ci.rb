#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FIXTURE_PATHS = %w[
  .github/workflows/windows-packages.yml
  examples/pixi-consumer/scripts/activate-orocos.ps1
  packaging/conda/recipe.yaml
  tools/check-windows-package-ci.rb
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

with_fixture do |root|
  _stdout, stderr, status = run_checker(root)
  raise "real Windows package policy is invalid:\n#{stderr}" unless status.success?
end

publish_condition_error =
  "Prefix publication condition must exactly require the approved release event and repository"
mutations = {
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
  "commented runtime shared wrapper source" => [
    "consumer smoke test must source the shared Pixi activation wrapper exactly twice",
    lambda do |contents|
      replace_occurrence(contents, shared_source, "    # . $env:OROCOS_PIXI_ACTIVATION_SCRIPT", 0)
    end
  ],
  "missing both shared wrapper sources" => [
    "consumer smoke test must source the shared Pixi activation wrapper exactly twice",
    ->(contents) { contents.gsub(/^#{Regexp.escape(shared_source)}\r?\n/, "") }
  ],
  "direct runtime installed activation source" => [
    "consumer smoke test must not source installed activation scripts directly",
    lambda do |contents|
      replace_occurrence(
        contents,
        shared_source,
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
        1
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

accepted_mutations = []
wrong_rejections = []
{
  ".github/workflows/windows-packages.yml" => mutations,
  "tools/test-windows-conda-consumer.ps1" => consumer_mutations,
  "examples/pixi-consumer/scripts/activate-orocos.ps1" => wrapper_mutations
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
