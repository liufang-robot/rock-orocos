#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
STAGER = File.join(ROOT, "tools", "stage-license-corpus.rb")
INVENTORY = File.join(ROOT, "packaging", "license-corpus.json")
SOURCE_LOCK = File.join(ROOT, "packaging", "source-lock.json")

EXPECTED_SOURCES = %w[
  farbot metaruby ocl open62541 open62541pp orogen rtlog-cpp rtt rtt_opcua
  rtt_typelib typelib utilmm utilrb
].freeze
EXPECTED_REMOTE_GEMS = {
  "backports" => "3.25.3",
  "base64" => "0.3.0",
  "facets" => "3.1.0",
  "kramdown" => "2.5.2",
  "rake" => "13.4.2",
  "rexml" => "3.4.4"
}.freeze
EXPECTED_SOURCE_GEMS = {
  "metaruby" => "1.0.0",
  "orogen" => "1.3.0",
  "utilrb" => "3.2.0"
}.freeze
EXPECTED_LICENSE_REFS = %w[
  LicenseRef-MetaRuby-Bundled-jQuery-Notices
  LicenseRef-MetaRuby-Conflicting-BSD-LGPLv3-Declarations
  LicenseRef-OCL-GPL-2.0-Linking-Exception
  LicenseRef-Orocos-RTT-GPL-2.0-Linking-Exception
  LicenseRef-Orocos-RTT-TLSF-Linking-Exception
  LicenseRef-Ruby-base64-Mixed-Legal-Notices
  LicenseRef-Ruby-facets-Mixed-Bundled-Notices
  LicenseRef-Windows-vcpkg-Bundled-Dependencies
  LicenseRef-open62541-base64-BSD
  LicenseRef-rtlog-cpp-Bundled-License-Exceptions
].freeze
EXPECTED_COMPONENT_LICENSES = {
  "ocl" =>
    "GPL-2.0-or-later AND LGPL-2.1-or-later AND " \
    "LicenseRef-OCL-GPL-2.0-Linking-Exception",
  "open62541" =>
    "MPL-2.0 AND CC0-1.0 AND Apache-2.0 AND BSL-1.0 AND MIT AND " \
    "BSD-3-Clause AND LicenseRef-open62541-base64-BSD",
  "rtt_opcua" => "LGPL-2.1-or-later"
}.freeze
EXPECTED_SOURCE_NOTICES = {
  "ocl" => %w[
    deployment/DeploymentComponent.cpp
    manifest.xml
    package.xml
    reporting/TableMarshaller.hpp
    scripts/shell/license.txt
    taskbrowser/TaskBrowser.cpp
  ],
  "open62541" => %w[
    LICENSE
    LICENSE-CC0
    deps/README.md
    deps/base64.c
    deps/cj5.c
    deps/cj5.h
    deps/dtoa.c
    deps/dtoa.h
    deps/itoa.c
    deps/itoa.h
    deps/libc_time.c
    deps/mp_printf.c
    deps/mp_printf.h
    deps/open62541_queue.h
    deps/parse_num.c
    deps/pcg_basic.c
    deps/pcg_basic.h
    deps/ziptree.c
    deps/ziptree.h
  ],
  "rtt_opcua" => %w[LICENSE manifest.xml package.xml]
}.freeze
EXPECTED_LICENSE_REF_EVIDENCE = {
  "LicenseRef-OCL-GPL-2.0-Linking-Exception" =>
    ["sources/ocl/reporting/TableMarshaller.hpp"],
  "LicenseRef-open62541-base64-BSD" => [
    "sources/open62541/deps/README.md",
    "sources/open62541/deps/base64.c"
  ]
}.freeze

def assert(condition, message)
  raise message unless condition
end

def write_json(path, document)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(document) + "\n")
end

def tree_digest(root)
  files = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.sort
  Digest::SHA256.hexdigest(
    files.map do |path|
      relative = path.delete_prefix("#{root}/")
      "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\n"
    end.join
  )
end

def gem_specification(name, version, files = [], licenses = [])
  Gem::Specification.new do |specification|
    specification.name = name
    specification.version = version
    specification.summary = "Synthetic license corpus test gem"
    specification.authors = ["Orocos/Rock test"]
    specification.files = files
    specification.licenses = licenses
  end
end

def test_production_inventory
  inventory = JSON.parse(File.read(INVENTORY))
  source_lock = JSON.parse(File.read(SOURCE_LOCK))
  locked_revisions = source_lock.fetch("sources").to_h do |source|
    [source.fetch("name"), source.fetch("revision")]
  end

  sources = inventory.fetch("sources")
  assert(sources.map { |source| source.fetch("name") }.sort == EXPECTED_SOURCES,
         "production license inventory does not cover the exact source set")
  sources.each do |source|
    assert(source.fetch("revision") == locked_revisions.fetch(source.fetch("source_lock_name")),
           "production license inventory revision drifted for #{source.fetch('name')}")
    assert(!source.fetch("notices").empty?,
           "production license inventory has no notice for #{source.fetch('name')}")
    source.fetch("notices").each do |notice|
      assert(notice.fetch("sha256").match?(/\A[0-9a-f]{64}\z/),
             "production source notice is not hash-locked")
    end
  end
  source_licenses = sources.to_h do |source|
    [source.fetch("name"), source.fetch("license")]
  end
  EXPECTED_COMPONENT_LICENSES.each do |name, expected|
    assert(source_licenses.fetch(name) == expected,
           "production inventory misclassifies #{name}")
  end
  assert(source_licenses.fetch("rtlog-cpp") ==
         "LicenseRef-rtlog-cpp-Bundled-License-Exceptions",
         "production inventory collapses rtlog-cpp's bundled exceptions")
  source_notices = sources.to_h do |source|
    [source.fetch("name"), source.fetch("notices").map { |notice| notice.fetch("path") }]
  end
  EXPECTED_SOURCE_NOTICES.each do |name, expected|
    assert(source_notices.fetch(name) == expected,
           "production inventory has incomplete or unordered notice evidence for #{name}")
  end

  remote = inventory.fetch("ruby_gems").fetch("remote")
  actual_remote = remote.to_h { |gem| [gem.fetch("name"), gem.fetch("version")] }
  assert(actual_remote == EXPECTED_REMOTE_GEMS,
         "production license inventory does not cover the exact remote gem set")
  remote.each do |gem|
    assert(gem.fetch("artifact") == "#{gem.fetch('name')}-#{gem.fetch('version')}.gem",
           "production remote gem uses a noncanonical artifact name")
    assert(gem.fetch("sha256").match?(/\A[0-9a-f]{64}\z/),
           "production remote gem artifact is not hash-locked")
    assert(!gem.fetch("notices").empty?,
           "production remote gem has no notice evidence")
  end
  facets = remote.find { |gem| gem.fetch("name") == "facets" }
  assert(facets.fetch("license") == "LicenseRef-Ruby-facets-Mixed-Bundled-Notices",
         "production inventory collapses facets' mixed bundled notices")

  built = inventory.fetch("ruby_gems").fetch("source_built")
  actual_built = built.to_h { |gem| [gem.fetch("name"), gem.fetch("version")] }
  assert(actual_built == EXPECTED_SOURCE_GEMS,
         "production license inventory does not cover the exact source-built gem set")
  built.each do |gem|
    assert(gem.fetch("source") == gem.fetch("name"),
           "production source-built gem is not tied to its source checkout")
  end

  license_refs = inventory.fetch("license_refs")
  assert(license_refs.map { |reference| reference.fetch("id") }.sort == EXPECTED_LICENSE_REFS,
         "production license inventory has the wrong LicenseRef set")
  license_refs.each do |reference|
    assert(!reference.fetch("description").empty? && !reference.fetch("evidence").empty?,
           "#{reference.fetch('id')} is not documented with evidence")
  end
  license_ref_evidence = license_refs.to_h do |reference|
    [reference.fetch("id"), reference.fetch("evidence")]
  end
  EXPECTED_LICENSE_REF_EVIDENCE.each do |identifier, expected|
    assert(license_ref_evidence.fetch(identifier) == expected,
           "#{identifier} has incomplete or unordered evidence")
  end
  linux_license = inventory.fetch("aggregate_license").fetch("linux")
  windows_license = inventory.fetch("aggregate_license").fetch("windows")
  linux_terms = linux_license.split(" AND ")
  %w[
    Apache-2.0
    BSL-1.0
    LicenseRef-OCL-GPL-2.0-Linking-Exception
    LicenseRef-open62541-base64-BSD
  ].each do |term|
    assert(linux_terms.include?(term), "Linux aggregate license omits #{term}")
  end
  %w[GPL-2.0-only LGPL-2.1-only].each do |obsolete|
    assert(!linux_terms.include?(obsolete),
           "Linux aggregate license retains obsolete plain #{obsolete}")
  end
  assert(linux_license.include?("LicenseRef-MetaRuby-Conflicting-BSD-LGPLv3-Declarations"),
         "Linux aggregate license collapses the MetaRuby declaration conflict")
  assert(linux_license.include?("LicenseRef-Orocos-RTT-GPL-2.0-Linking-Exception"),
         "Linux aggregate license omits the RTT linking exception")
  assert(windows_license ==
         "(#{linux_license}) AND LicenseRef-Windows-vcpkg-Bundled-Dependencies",
         "Windows aggregate license does not extend the common corpus exactly")
end

def test_platform_integration
  inventory = JSON.parse(File.read(INVENTORY))
  linux_recipe = File.read(File.join(ROOT, "packaging", "conda", "recipe-linux.yaml"))
  windows_recipe = File.read(File.join(ROOT, "packaging", "conda", "recipe.yaml"))
  linux_prepare = File.read(
    File.join(ROOT, "packaging", "conda", "prepare-linux-prefix.sh")
  )
  windows_prepare = File.read(
    File.join(ROOT, "packaging", "conda", "prepare-prefix.ps1")
  )
  policy_workflow = File.read(
    File.join(ROOT, ".github", "workflows", "repository-policy.yml")
  )
  policy_checker = File.read(File.join(ROOT, "tools", "check-repository-policy.rb"))

  assert(linux_prepare.include?("tools/stage-license-corpus.rb") &&
         linux_prepare.include?("--platform linux") &&
         linux_prepare.include?('"$prefix/toolchain/gems"'),
         "Linux prefix preparation does not stage the validated license corpus")
  assert(windows_prepare.include?("tools\\stage-license-corpus.rb") &&
         windows_prepare.include?('"--platform", "windows"') &&
         windows_prepare.include?('"--vcpkg-share"'),
         "Windows prefix preparation does not stage the validated license corpus")
  ruby_invocation = windows_prepare.match(
    /& \$RubyExecutable @\(\r?\n(?<arguments>.*?)^\)/m
  )
  assert(ruby_invocation, "Windows prefix preparation does not invoke Ruby structurally")
  first_ruby_argument = ruby_invocation[:arguments].lines.map(&:strip).reject(&:empty?).first
  assert(first_ruby_argument == "$licenseStager,",
         "Windows Ruby invocation does not execute the license stager as its first argument")
  assert(!windows_prepare.include?("function Copy-LicenseMetadata"),
         "Windows prefix preparation retains the unvalidated legacy license copier")

  linux_license = inventory.fetch("aggregate_license").fetch("linux")
  windows_license = inventory.fetch("aggregate_license").fetch("windows")
  assert(linux_recipe.scan("license: #{linux_license}").size == 3,
         "Linux recipe does not publish the exact aggregate license on all package records")
  assert(windows_recipe.scan("license: #{windows_license}").size == 3,
         "Windows recipe does not publish the exact aggregate license on all package records")
  assert(linux_recipe.include?("packaging/license-corpus.json"),
         "Linux recipe source omits the license inventory")
  assert(windows_recipe.include?("packaging/license-corpus.json") &&
         windows_recipe.include?("tools/stage-license-corpus.rb"),
         "Windows recipe source omits license corpus inputs")

  %w[orocos orocos-dev].each do |package|
    root = "share/licenses/#{package}"
    assert(linux_recipe.include?("- #{root}/**"),
           "Linux #{package} output omits its package-aligned corpus")
    assert(linux_recipe.include?(%(- ${{ PREFIX }}/#{root}/**)),
           "Linux #{package} output omits its recursive late-bound license_file")

    windows_root = "Library/share/licenses/#{package}"
    assert(windows_recipe.include?("- #{windows_root}/**"),
           "Windows #{package} output omits its package-aligned corpus")
    assert(windows_recipe.include?(%(- ${{ PREFIX }}/#{windows_root}/**)),
           "Windows #{package} output omits its recursive late-bound license_file")
  end
  assert(policy_workflow.include?("ruby tools/test-license-corpus.rb"),
         "repository policy does not execute the license corpus regression test")
  assert(policy_checker.include?('"ruby tools/test-license-corpus.rb" =>'),
         "repository policy checker does not enforce the license corpus command")
  %w[tools/stage-license-corpus.rb tools/test-license-corpus.rb].each do |path|
    assert(policy_workflow.scan(%("#{path}")).size == 2,
           "repository policy triggers do not watch #{path} on pull requests and pushes")
    assert(policy_checker.include?(path),
           "repository policy checker does not enforce the #{path} triggers")
  end
end

test_production_inventory
test_platform_integration

Dir.mktmpdir("orocos-license-corpus-test-") do |temporary|
  source_root = File.join(temporary, "source-root")
  prefix = File.join(temporary, "prefix")
  gem_home = File.join(prefix, "toolchain", "gems")
  gem_cache = File.join(source_root, ".ruby-gems")
  checkout = File.join(source_root, "sources", "example")
  windows_checkout = File.join(source_root, "src", "example")
  vcpkg_share = File.join(temporary, "vcpkg-share")
  inventory_path = File.join(temporary, "license-corpus.json")
  source_lock_path = File.join(temporary, "source-lock.json")
  revision = "a" * 40
  notice_contents = "Example license notice\n"
  gem_notice_contents = "Synthetic gem license\n"
  glob_notice_contents = "Synthetic notice with glob metacharacters\n"
  remote_gem = gem_specification(
    "remote-gem", "1.2.3", ["LICENSE.txt", "NOTICE[1].txt"], ["MIT"]
  )
  source_gem = gem_specification("source-gem", "4.5.6", [], ["BSD-3-Clause"])
  artifact_path = File.join(gem_cache, "remote-gem-1.2.3.gem")

  FileUtils.mkdir_p(checkout)
  FileUtils.mkdir_p(windows_checkout)
  FileUtils.mkdir_p(File.join(gem_home, "specifications"))
  FileUtils.mkdir_p(gem_cache)
  File.write(File.join(checkout, "LICENSE"), notice_contents)
  File.write(File.join(windows_checkout, "LICENSE"), notice_contents)
  FileUtils.mkdir_p(File.join(vcpkg_share, "boost", "licenses"))
  FileUtils.mkdir_p(File.join(vcpkg_share, "boost_algorithm"))
  FileUtils.mkdir_p(File.join(vcpkg_share, "man", "man1"))
  FileUtils.mkdir_p(File.join(vcpkg_share, "zlib"))
  File.write(File.join(vcpkg_share, "boost", "licenses", "LICENSE_1_0.txt"),
             "Boost license\n")
  File.write(File.join(vcpkg_share, "boost", "vcpkg.spdx.json"), "{\"name\":\"boost\"}\n")
  File.write(File.join(vcpkg_share, "boost_algorithm", "boost_algorithm-config.cmake"),
             "# CMake package support directory, not a vcpkg port\n")
  File.write(File.join(vcpkg_share, "man", "man1", "example.1"),
             "Manual page support directory, not a vcpkg port\n")
  File.write(File.join(vcpkg_share, "zlib", "copyright"), "zlib copyright\n")
  File.write(File.join(vcpkg_share, "zlib", "license-extra.txt"), "zlib license\n")
  File.write(File.join(vcpkg_share, "zlib", "usage"), "ignored metadata\n")
  gem_source = File.join(temporary, "remote-gem-source")
  FileUtils.mkdir_p(gem_source)
  File.write(File.join(gem_source, "LICENSE.txt"), gem_notice_contents)
  File.write(File.join(gem_source, "NOTICE[1].txt"), glob_notice_contents)
  FileUtils.chdir(gem_source) do
    Gem::Package.build(remote_gem, true, false, artifact_path)
  end
  File.write(File.join(gem_home, "specifications", "remote-gem-1.2.3.gemspec"),
             remote_gem.to_ruby)
  File.write(File.join(gem_home, "specifications", "source-gem-4.5.6.gemspec"),
             source_gem.to_ruby)

  source_lock = {
    "schema_version" => 1,
    "sources" => [{
      "name" => "example",
      "repository" => "https://example.invalid/example.git",
      "revision" => revision
    }]
  }
  write_json(source_lock_path, source_lock)
  inventory = {
    "schema_version" => 1,
    "aggregate_license" => {
      "linux" => "MIT AND LicenseRef-Synthetic-Notice",
      "windows" => "(MIT AND LicenseRef-Synthetic-Notice) AND LicenseRef-Windows-vcpkg-Bundled-Dependencies"
    },
    "license_refs" => [
      {
        "id" => "LicenseRef-Synthetic-Notice",
        "description" => "Synthetic source declaration used by the regression fixture.",
        "evidence" => ["sources/example/LICENSE"]
      },
      {
        "id" => "LicenseRef-Windows-vcpkg-Bundled-Dependencies",
        "description" => "Synthetic dynamic vcpkg dependency notice set.",
        "evidence" => ["vcpkg/** (exact paths and SHA256 values in manifest.json)"]
      }
    ],
    "sources" => [{
      "name" => "example",
      "source_lock_name" => "example",
      "revision" => revision,
      "license" => "MIT",
      "checkouts" => {
        "linux" => "sources/example",
        "windows" => "src/example"
      },
      "notices" => [{
        "path" => "LICENSE",
        "sha256" => Digest::SHA256.hexdigest(notice_contents)
      }]
    }],
    "ruby_gems" => {
      "remote" => [{
        "name" => "remote-gem",
        "version" => "1.2.3",
        "artifact" => "remote-gem-1.2.3.gem",
        "sha256" => Digest::SHA256.file(artifact_path).hexdigest,
        "declared_licenses" => ["MIT"],
        "license" => "MIT",
        "notices" => [{
          "path" => "LICENSE.txt",
          "sha256" => Digest::SHA256.hexdigest(gem_notice_contents)
        }, {
          "path" => "NOTICE[1].txt",
          "sha256" => Digest::SHA256.hexdigest(glob_notice_contents)
        }]
      }],
      "source_built" => [{
        "name" => "source-gem",
        "version" => "4.5.6",
        "source" => "example",
        "declared_licenses" => ["BSD-3-Clause"],
        "license" => "MIT"
      }]
    },
    "windows_vcpkg" => {
      "license" => "LicenseRef-Windows-vcpkg-Bundled-Dependencies",
      "exact_names" => ["copyright", "vcpkg.spdx.json"],
      "name_prefixes" => ["COPYING", "LICENSE", "NOTICE"]
    }
  }
  write_json(inventory_path, inventory)

  command = [
    "ruby", STAGER,
    "--inventory", inventory_path,
    "--source-lock", source_lock_path,
    "--platform", "linux",
    "--source-root", source_root,
    "--gem-home", gem_home,
    "--gem-cache", gem_cache,
    "--prefix", prefix
  ]
  output, status = Open3.capture2e(*command)
  assert(status.success?, "license corpus staging failed:\n#{output}")

  runtime = File.join(prefix, "share", "licenses", "orocos")
  development = File.join(prefix, "share", "licenses", "orocos-dev")
  expected = %w[
    LICENSES.md
    gems/remote-gem-1.2.3/LICENSE.txt
    gems/remote-gem-1.2.3/NOTICE[1].txt
    manifest.json
    sources/example/LICENSE
  ]
  [runtime, development].each do |root|
    actual = Dir[File.join(root, "**", "*")]
             .select { |path| File.file?(path) }
             .map { |path| path.delete_prefix("#{root}/") }
             .sort
    assert(actual == expected, "unexpected corpus files under #{root}: #{actual.inspect}")
  end
  assert(tree_digest(runtime) == tree_digest(development),
         "runtime and development license corpora differ")

  first_digest = tree_digest(runtime)
  File.write(File.join(runtime, "stale.txt"), "stale\n")
  output, status = Open3.capture2e(*command)
  assert(status.success?, "second license corpus staging failed:\n#{output}")
  assert(!File.exist?(File.join(runtime, "stale.txt")), "stale corpus content survived")
  assert(tree_digest(runtime) == first_digest, "license corpus is not deterministic")

  manifest = JSON.parse(File.read(File.join(runtime, "manifest.json")))
  source = manifest.fetch("sources").fetch(0)
  assert(manifest.fetch("aggregate_license") == "MIT AND LicenseRef-Synthetic-Notice",
         "wrong aggregate license")
  license_text = File.read(File.join(runtime, "LICENSES.md"))
  assert(license_text.include?("## LicenseRef Definitions"),
         "human-readable corpus omits LicenseRef definitions")
  inventory.fetch("license_refs").each do |reference|
    assert(license_text.include?(reference.fetch("id")),
           "human-readable corpus omits #{reference.fetch('id')}")
    assert(license_text.include?(reference.fetch("description")),
           "human-readable corpus omits the #{reference.fetch('id')} description")
    reference.fetch("evidence").each do |evidence|
      assert(license_text.include?(evidence),
             "human-readable corpus omits #{reference.fetch('id')} evidence")
    end
  end
  assert(source.fetch("name") == "example", "manifest omitted the source name")
  assert(source.fetch("revision") == revision, "manifest omitted the source revision")
  assert(source.fetch("notices").fetch(0).fetch("sha256") ==
         Digest::SHA256.hexdigest(notice_contents), "manifest omitted the notice digest")
  remote = manifest.fetch("ruby_gems").fetch("remote").fetch(0)
  assert(remote.fetch("artifact_sha256") == Digest::SHA256.file(artifact_path).hexdigest,
         "manifest omitted the gem artifact digest")
  assert(remote.fetch("declared_licenses") == ["MIT"],
         "manifest omitted the remote gem's declared licenses")
  assert(remote.fetch("notices").fetch(0).fetch("sha256") ==
         Digest::SHA256.hexdigest(gem_notice_contents), "manifest omitted the gem notice digest")
  source_built = manifest.fetch("ruby_gems").fetch("source_built").fetch(0)
  assert(source_built.fetch("source") == "example",
         "manifest omitted the source-built gem classification")
  assert(source_built.fetch("declared_licenses") == ["BSD-3-Clause"],
         "manifest omitted the source-built gem's declared licenses")

  original_artifact = File.binread(artifact_path)
  original_artifact_sha = inventory.fetch("ruby_gems").fetch("remote").fetch(0).fetch("sha256")
  impostor_path = File.join(temporary, "impostor.gem")
  impostor = gem_specification("impostor", "1.2.3", ["LICENSE.txt"], ["MIT"])
  FileUtils.chdir(gem_source) do
    Gem::Package.build(impostor, true, false, impostor_path)
  end
  begin
    FileUtils.copy_file(impostor_path, artifact_path)
    inventory.fetch("ruby_gems").fetch("remote").fetch(0)["sha256"] =
      Digest::SHA256.file(artifact_path).hexdigest
    write_json(inventory_path, inventory)
    output, status = Open3.capture2e(*command)
    assert(!status.success?, "license stager accepted an artifact with an impostor gemspec")
    assert(output.include?("embedded specification does not match"),
           "impostor artifact failed for the wrong reason:\n#{output}")
  ensure
    File.binwrite(artifact_path, original_artifact)
    inventory.fetch("ruby_gems").fetch("remote").fetch(0)["sha256"] = original_artifact_sha
    write_json(inventory_path, inventory)
  end

  drifted_artifact_path = File.join(temporary, "drifted-license.gem")
  drifted_artifact = gem_specification(
    "remote-gem", "1.2.3", ["LICENSE.txt"], ["Apache-2.0"]
  )
  FileUtils.chdir(gem_source) do
    Gem::Package.build(drifted_artifact, true, false, drifted_artifact_path)
  end
  begin
    FileUtils.copy_file(drifted_artifact_path, artifact_path)
    inventory.fetch("ruby_gems").fetch("remote").fetch(0)["sha256"] =
      Digest::SHA256.file(artifact_path).hexdigest
    write_json(inventory_path, inventory)
    output, status = Open3.capture2e(*command)
    assert(!status.success?, "license stager accepted drifted artifact license declarations")
    assert(output.include?("artifact declared licenses do not match"),
           "drifted artifact licenses failed for the wrong reason:\n#{output}")
  ensure
    File.binwrite(artifact_path, original_artifact)
    inventory.fetch("ruby_gems").fetch("remote").fetch(0)["sha256"] = original_artifact_sha
    write_json(inventory_path, inventory)
  end

  [
    ["remote-gem", "1.2.3", ["MIT"]],
    ["source-gem", "4.5.6", ["BSD-3-Clause"]]
  ].each do |name, version, expected_licenses|
    specification_path = File.join(
      gem_home, "specifications", "#{name}-#{version}.gemspec"
    )
    original_specification = File.read(specification_path)
    drifted_specification = gem_specification(name, version, [], ["Apache-2.0"])
    begin
      File.write(specification_path, drifted_specification.to_ruby)
      output, status = Open3.capture2e(*command)
      assert(!status.success?,
             "license stager accepted drifted installed licenses for #{name}")
      assert(output.include?("installed gem declared licenses do not match"),
             "drifted installed licenses for #{name} failed for the wrong reason:\n#{output}")
    ensure
      File.write(specification_path, original_specification)
    end
    assert(Gem::Specification.load(specification_path).licenses == expected_licenses,
           "failed to restore the installed #{name} gemspec fixture")
  end

  inventory_mutations = [
    [
      "duplicate LicenseRef",
      lambda do |document|
        document.fetch("license_refs") << document.fetch("license_refs").fetch(0).dup
      end,
      "duplicate license inventory LicenseRef"
    ],
    [
      "extra LicenseRef key",
      lambda do |document|
        document.fetch("license_refs").fetch(0)["unexpected"] = true
      end,
      "license inventory LicenseRef keys must equal"
    ],
    [
      "invalid LicenseRef ID",
      lambda do |document|
        document.fetch("license_refs").fetch(0)["id"] = "MIT"
      end,
      "license inventory LicenseRef id is invalid"
    ],
    [
      "empty LicenseRef evidence",
      lambda do |document|
        document.fetch("license_refs").fetch(0)["evidence"] = []
      end,
      "evidence must be a nonempty string array"
    ],
    [
      "undefined LicenseRef",
      lambda do |document|
        document.fetch("license_refs").reject! do |reference|
          reference.fetch("id") == "LicenseRef-Windows-vcpkg-Bundled-Dependencies"
        end
      end,
      "license inventory uses undefined LicenseRef"
    ],
    [
      "unused LicenseRef",
      lambda do |document|
        document.fetch("license_refs") << {
          "id" => "LicenseRef-Unused-Synthetic",
          "description" => "This definition is intentionally unused.",
          "evidence" => ["sources/example/LICENSE"]
        }
      end,
      "license inventory defines unused LicenseRef"
    ]
  ]
  inventory_mutations.each do |description, mutate, expected_message|
    mutated = JSON.parse(JSON.generate(inventory))
    mutate.call(mutated)
    before_digest = tree_digest(runtime)
    begin
      write_json(inventory_path, mutated)
      output, status = Open3.capture2e(*command)
    ensure
      write_json(inventory_path, inventory)
    end
    assert(!status.success?, "license stager accepted #{description}")
    assert(output.include?(expected_message),
           "#{description} failed for the wrong reason:\n#{output}")
    assert(tree_digest(runtime) == before_digest,
           "#{description} changed an existing corpus before rejection")
  end

  duplicate_lock = JSON.parse(JSON.generate(source_lock))
  duplicate_lock.fetch("sources") << duplicate_lock.fetch("sources").fetch(0).dup
  before_digest = tree_digest(runtime)
  begin
    write_json(source_lock_path, duplicate_lock)
    output, status = Open3.capture2e(*command)
  ensure
    write_json(source_lock_path, source_lock)
  end
  assert(!status.success?, "license stager accepted a duplicate source-lock entry")
  assert(output.include?("duplicate source lock entry example"),
         "duplicate source-lock entry failed for the wrong reason:\n#{output}")
  assert(tree_digest(runtime) == before_digest,
         "duplicate source-lock entry changed an existing corpus before rejection")

  duplicate_inventory_source = JSON.parse(JSON.generate(inventory))
  duplicate_inventory_source.fetch("sources") <<
    duplicate_inventory_source.fetch("sources").fetch(0).dup
  begin
    write_json(inventory_path, duplicate_inventory_source)
    output, status = Open3.capture2e(*command)
  ensure
    write_json(inventory_path, inventory)
  end
  assert(!status.success?, "license stager accepted a duplicate inventory source")
  assert(output.include?("duplicate license inventory source example"),
         "duplicate inventory source failed for the wrong reason:\n#{output}")
  assert(tree_digest(runtime) == before_digest,
         "duplicate inventory source changed an existing corpus before rejection")

  windows_command = command.dup
  platform_index = windows_command.index("--platform")
  windows_command[platform_index + 1] = "windows"
  windows_command.concat(["--vcpkg-share", vcpkg_share])
  output, status = Open3.capture2e(*windows_command)
  assert(status.success?, "Windows license corpus staging failed:\n#{output}")

  expected_vcpkg = %w[
    vcpkg/boost/licenses/LICENSE_1_0.txt
    vcpkg/boost/vcpkg.spdx.json
    vcpkg/zlib/copyright
    vcpkg/zlib/license-extra.txt
  ]
  [runtime, development].each do |root|
    actual_vcpkg = Dir[File.join(root, "vcpkg", "**", "*")]
                   .select { |path| File.file?(path) }
                   .map { |path| path.delete_prefix("#{root}/") }
                   .sort
    assert(actual_vcpkg == expected_vcpkg,
           "unexpected vcpkg corpus files under #{root}: #{actual_vcpkg.inspect}")
  end
  windows_manifest = JSON.parse(File.read(File.join(runtime, "manifest.json")))
  assert(windows_manifest.fetch("aggregate_license") ==
         "(MIT AND LicenseRef-Synthetic-Notice) AND LicenseRef-Windows-vcpkg-Bundled-Dependencies",
         "Windows manifest omitted the vcpkg LicenseRef")
  vcpkg_metadata = windows_manifest.fetch("windows_vcpkg")
  assert(vcpkg_metadata.map { |entry| entry.fetch("corpus_path") } == expected_vcpkg,
         "Windows vcpkg manifest is incomplete or unsorted")
  vcpkg_metadata.each do |entry|
    path = File.join(runtime, entry.fetch("corpus_path"))
    assert(entry.fetch("sha256") == Digest::SHA256.file(path).hexdigest,
           "Windows vcpkg manifest contains a wrong digest")
  end
end

warn "License corpus regression tests passed."
