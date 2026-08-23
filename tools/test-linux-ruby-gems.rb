#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
RECIPE = File.join(ROOT, "packaging", "conda", "recipe-linux.yaml")
BUILD_SCRIPT = File.join(ROOT, "packaging", "conda", "build-linux.sh")
INSTALL_AUTOPROJ = File.join(ROOT, "tools", "install-autoproj.sh")
INSTALL_RUBY_TOOLS = File.join(ROOT, "tools", "install-ruby-tools.sh")
COMMON = File.join(ROOT, "tools", "common.sh")
REPOSITORY_WORKFLOW = File.join(ROOT, ".github", "workflows", "repository-policy.yml")
REPOSITORY_POLICY = File.join(ROOT, "tools", "check-repository-policy.rb")

LOCKED_GEMS = {
  "autobuild-1.25.2.gem" => "62b4c782550b3c1ba42eee8d034955835e445236c3156f2099c3be4fc8551968",
  "autoproj-2.18.1.gem" => "8e36787127025c445eff2c7361bfb86109a6ce029fcb278a8f79393c9db95b2e",
  "backports-3.25.3.gem" => "94298d32dc3c40ca15633b54e282780b49e2db0c045f602ea1907e4f63a17235",
  "base64-0.3.0.gem" => "27337aeabad6ffae05c265c450490628ef3ebd4b67be58257393227588f5a97b",
  "bundler-2.6.9.gem" => "a25675ffbd055ae1186766cc1e120b4cf62588e88abb59b99c57e22b1c55c9eb",
  "concurrent-ruby-1.3.8.gem" => "b2f1be836e968ccc78ccfce277ea79c72a88633f22306782c16ff23fb415d1e1",
  "equatable-0.7.0.gem" => "cd99f7bf79439dac5b34ccd33826aef0ef561029ecfa6d32a87c088a688ffe2b",
  "facets-3.1.0.gem" => "7834a68824efbb35380ed7f6f590e01fb9a31a9466e317210e8803f72813c345",
  "ffi-1.17.4-x86_64-linux-gnu.gem" => "9d3db14c2eae074b382fa9c083fe95aec6e0a1451da249eab096c34002bc752d",
  "kramdown-2.5.2.gem" => "1ba542204c66b6f9111ff00dcc26075b95b220b07f2905d8261740c82f7f02fa",
  "necromancer-0.5.1.gem" => "6d0be995dd3f69e2d03dfc6e426ab891704dd5bbb903a79730baab4352185ef0",
  "net-protocol-0.2.2.gem" => "aa73e0cba6a125369de9837b8d8ef82a61849360eba0521900e2c3713aa162a8",
  "net-smtp-0.5.1.gem" => "ed96a0af63c524fceb4b29b0d352195c30d82dd916a42f03c62a3a70e5b70736",
  "pairing_heap-3.1.1.gem" => "c71a74ecdf9d6accc7545b38075b2f4e8d98b550aabe0f0758a587ee12e93588",
  "parslet-2.0.0.gem" => "d45130695d39b43d7e6a91f4d2ec66b388a8d822bae38de9b4de9a5fbde1f606",
  "pastel-0.7.4.gem" => "cc3b26fa5124c7c20250511969bfdeb36ac46d682a5f1a2fa4c22f044204feee",
  "rake-13.4.2.gem" => "cb825b2bd5f1f8e91ca37bddb4b9aaf345551b4731da62949be002fa89283701",
  "rb-inotify-0.11.1.gem" => "a0a700441239b0ff18eb65e3866236cd78613d6b9f78fea1f9ac47a85e47be6e",
  "rexml-3.4.4.gem" => "19e0a2c3425dfbf2d4fc1189747bdb2f849b6c5e74180401b15734bc97b5d142",
  "rgl-0.5.10.gem" => "e3ff7dc67858baa6caea23396758c561e4a6f357e3f9c2cdfb4b9007d3164c4a",
  "stream-0.5.6.gem" => "2733607ce840d60c72eb181714d45f0a7b077ee62fec0a94510a29c39175610f",
  "thor-1.5.0.gem" => "e3a9e55fe857e44859ce104a84675ab6e8cd59c650a49106a05f55f136425e73",
  "timeout-0.4.3.gem" => "9509f079b2b55fe4236d79633bd75e34c1c1e7e3fb4b56cb5fda61f80a0fe30e",
  "tty-color-0.5.2.gem" => "43bd59bce8767bb393935ca25e8a473dcfcbe589937507742e80483a6ced6c8b",
  "tty-cursor-0.7.1.gem" => "79534185e6a777888d88628b14b6a1fdf5154a603f285f80b1753e1908e0bf48",
  "tty-prompt-0.21.0.gem" => "abeb4247e22f34600ba60c62b966131c6ec9a3bfc9442dfcebb642484fd5d909",
  "tty-reader-0.7.0.gem" => "2407d5c55585e9eab311a6d7f436edb80dc361a0c6558c116a90779db454e7a4",
  "tty-screen-0.8.2.gem" => "c090652115beae764336c28802d633f204fb84da93c6a968aa5d8e319e819b50",
  "tty-spinner-0.9.3.gem" => "0e036f047b4ffb61f2aa45f5a770ec00b4d04130531558a94bfc5b192b570542",
  "utilrb-3.2.0.gem" => "b9ea3be2971ea05024adb805ec37f3bb36e0bbb412f7e21ccf525ecd107daf78",
  "wisper-2.0.1.gem" => "ce17bc5c3a166f241a2e6613848b025c8146fce2defba505920c1d1f3f88fae6",
  "xdg-2.2.5.gem" => "f3a5f799363852695e457bb7379ac6c4e3e8cb3a51ce6b449ab47fbb1523b913"
}.freeze

GENERATOR_GEMS = [
  ["facets", "3.1.0"],
  ["backports", "3.25.3"],
  ["base64", "0.3.0"],
  ["rexml", "3.4.4"],
  ["kramdown", "2.5.2"],
  ["rake", "13.4.2"]
].freeze

AUTOPROJ_GEMS = [
  ["autobuild", "1.25.2", "autobuild-1.25.2.gem"],
  ["backports", "3.25.3", "backports-3.25.3.gem"],
  ["bundler", "2.6.9", "bundler-2.6.9.gem"],
  ["concurrent-ruby", "1.3.8", "concurrent-ruby-1.3.8.gem"],
  ["equatable", "0.7.0", "equatable-0.7.0.gem"],
  ["facets", "3.1.0", "facets-3.1.0.gem"],
  ["ffi", "1.17.4", "ffi-1.17.4-x86_64-linux-gnu.gem"],
  ["necromancer", "0.5.1", "necromancer-0.5.1.gem"],
  ["timeout", "0.4.3", "timeout-0.4.3.gem"],
  ["net-protocol", "0.2.2", "net-protocol-0.2.2.gem"],
  ["net-smtp", "0.5.1", "net-smtp-0.5.1.gem"],
  ["pairing_heap", "3.1.1", "pairing_heap-3.1.1.gem"],
  ["parslet", "2.0.0", "parslet-2.0.0.gem"],
  ["pastel", "0.7.4", "pastel-0.7.4.gem"],
  ["rake", "13.4.2", "rake-13.4.2.gem"],
  ["rb-inotify", "0.11.1", "rb-inotify-0.11.1.gem"],
  ["rexml", "3.4.4", "rexml-3.4.4.gem"],
  ["rgl", "0.5.10", "rgl-0.5.10.gem"],
  ["stream", "0.5.6", "stream-0.5.6.gem"],
  ["thor", "1.5.0", "thor-1.5.0.gem"],
  ["tty-color", "0.5.2", "tty-color-0.5.2.gem"],
  ["tty-cursor", "0.7.1", "tty-cursor-0.7.1.gem"],
  ["tty-prompt", "0.21.0", "tty-prompt-0.21.0.gem"],
  ["tty-reader", "0.7.0", "tty-reader-0.7.0.gem"],
  ["tty-screen", "0.8.2", "tty-screen-0.8.2.gem"],
  ["tty-spinner", "0.9.3", "tty-spinner-0.9.3.gem"],
  ["utilrb", "3.2.0", "utilrb-3.2.0.gem"],
  ["wisper", "2.0.1", "wisper-2.0.1.gem"],
  ["xdg", "2.2.5", "xdg-2.2.5.gem"],
  ["autoproj", "2.18.1", "autoproj-2.18.1.gem"]
].freeze

def assert(condition, message)
  raise message unless condition
end

def assert_missing_cache_failure(label, command, cache, network_log, path)
  stdout, stderr, status = Open3.capture3(
    {
      "OROCOS_ROCK_RUBY_GEM_CACHE" => cache,
      "PATH" => path,
      "RUBYGEMS_HOST" => "https://network.invalid"
    },
    *command
  )
  output = "#{stdout}#{stderr}"

  assert(!status.success?, "#{label} unexpectedly accepted an incomplete gem cache")
  assert(
    output.include?("required file is missing") && output.include?(cache),
    "#{label} did not identify the missing cached gem: #{output.inspect}"
  )
  assert(
    !File.exist?(network_log),
    "#{label} invoked gem or curl before rejecting the incomplete cache"
  )
end

recipe_text = File.read(RECIPE)
recipe = YAML.safe_load(recipe_text)
sources = recipe.fetch("source")
assert(sources.is_a?(Array), "Linux recipe source must be a list")

path_sources = sources.select { |source| source.key?("path") }
assert(path_sources.length == 1, "Linux recipe must contain exactly one repository source")
assert(path_sources.first.fetch("path") == "../..", "Linux recipe repository source changed")

gem_sources = sources.select { |source| source.key?("url") }
assert(
  gem_sources.length == LOCKED_GEMS.length,
  "Linux recipe must contain exactly #{LOCKED_GEMS.length} locked gem sources"
)

actual_gems = {}
gem_sources.each do |source|
  assert(
    source.keys.sort == %w[sha256 target_directory url],
    "locked gem source has unexpected fields: #{source.inspect}"
  )
  filename = File.basename(source.fetch("url"))
  assert(!actual_gems.key?(filename), "duplicate locked gem source: #{filename}")
  assert(
    source.fetch("url") == "https://rubygems.org/downloads/#{filename}",
    "locked gem source must use the RubyGems artifact URL: #{source.inspect}"
  )
  assert(
    source.fetch("target_directory") == ".ruby-gems",
    "locked gem must be staged below .ruby-gems: #{filename}"
  )
  actual_gems[filename] = source.fetch("sha256")
end
assert(actual_gems == LOCKED_GEMS, "Linux recipe locked gem inventory or hashes changed")
assert(!recipe_text.include?("facets-3.2.2"), "Linux recipe must not stage Facets 3.2.2")

build_script = File.read(BUILD_SCRIPT)
assert(
  build_script.include?('export OROCOS_ROCK_RUBY_GEM_CACHE="$repository_root/.ruby-gems"'),
  "Linux package build must export the recipe-provided Ruby gem cache"
)

common_script = File.read(COMMON)
assert(
  common_script.include?('gem "bundler", "= 2.6.9"') &&
    common_script.include?('Gem.bin_path("bundler", "bundle", "= 2.6.9")'),
  "cache-mode Bundler shim must locate Bundler 2.6.9 exactly"
)
assert(
  build_script.include?('./tools/install-autoproj.sh --gem-cache "$OROCOS_ROCK_RUBY_GEM_CACHE"'),
  "Linux package build must explicitly install Autoproj from the Ruby gem cache"
)

ruby_tools = File.read(INSTALL_RUBY_TOOLS)
installed_generator_gems = ruby_tools.scan(
  /^\s*install_remote_gem\s+(\S+)\s+(\S+)\s*$/
)
assert(
  installed_generator_gems == GENERATOR_GEMS,
  "Linux generator gem versions changed: #{installed_generator_gems.inspect}"
)

workflow = YAML.safe_load(File.read(REPOSITORY_WORKFLOW), aliases: true)
triggers = workflow["on"] || workflow[true]
watched_paths = [
  "tools/common.sh",
  "tools/install-autoproj.sh",
  "tools/install-ruby-tools.sh",
  "tools/locked-ruby-gems.rb",
  "tools/test-linux-ruby-gems.rb"
]
%w[pull_request push].each do |trigger|
  paths = Array(triggers.dig(trigger, "paths"))
  watched_paths.each do |path|
    assert(
      paths.include?(path),
      "repository policy #{trigger} must watch #{path}"
    )
  end
end
policy_commands = workflow.fetch("jobs").fetch("policy").fetch("steps")
                          .filter_map { |step| step["run"] }
                          .join("\n")
assert(
  policy_commands.lines.map(&:strip).include?("ruby tools/test-linux-ruby-gems.rb"),
  "repository policy workflow must run the Linux Ruby gem fixture"
)

repository_policy = File.read(REPOSITORY_POLICY)
watched_paths.each do |path|
  assert(
    repository_policy.include?(path),
    "repository policy checker must enforce the #{path} trigger"
  )
end
assert(
  repository_policy.include?("ruby tools/test-linux-ruby-gems.rb"),
  "repository policy checker must enforce the Linux Ruby gem fixture wiring"
)

Dir.mktmpdir("orocos-linux-ruby-gems-") do |directory|
  cache = File.join(directory, "cache")
  bin = File.join(directory, "bin")
  network_log = File.join(directory, "network.log")
  FileUtils.mkdir_p(cache)
  FileUtils.mkdir_p(bin)

  %w[curl gem].each do |command|
    stub = File.join(bin, command)
    File.write(
      stub,
      <<~SH
        #!/bin/sh
        printf '%s\n' "#{command} $*" >>"#{network_log}"
        exit 97
      SH
    )
    FileUtils.chmod(0o755, stub)
  end
  fixture_path = "#{bin}:/usr/bin:/bin"

  assert_missing_cache_failure(
    "install-autoproj.sh",
    ["bash", INSTALL_AUTOPROJ, "--gem-cache", cache],
    cache,
    network_log,
    fixture_path
  )

  workspace_gems = File.join(directory, "workspace-gems")
  assert_missing_cache_failure(
    "workspace Ruby gem install",
    [
      "bash", "-c",
      '. "$1"; orocos_rock_install_workspace_gem facets 3.1.0 "$2"',
      "workspace-gem-test", COMMON, workspace_gems
    ],
    cache,
    network_log,
    fixture_path
  )

  prefix = File.join(directory, "prefix")
  assert_missing_cache_failure(
    "install-ruby-tools.sh",
    ["bash", INSTALL_RUBY_TOOLS, "--prefix", prefix],
    cache,
    network_log,
    fixture_path
  )
end

Dir.mktmpdir("orocos-online-autoproj-") do |directory|
  bin = File.join(directory, "bin")
  workspace = File.join(directory, "workspace")
  FileUtils.mkdir_p(bin)
  FileUtils.mkdir_p(workspace)
  File.write(
    File.join(bin, "ruby"),
    <<~SH
      #!/bin/sh
      case "$*" in
        *"print RUBY_VERSION"*) printf '%s' "3.0.2" ;;
        *"print RbConfig.ruby"*) printf '%s' "/fixture/ruby" ;;
        *"Gem.bin_path"*) printf '%s' "/fixture/bundle" ;;
        *"paths = [Gem.user_dir]"*) printf '%s' "/fixture/gems" ;;
        *) exit 0 ;;
      esac
    SH
  )
  FileUtils.chmod(0o755, File.join(bin, "ruby"))

  prepare_command = <<~'SH'
    . "$1"
    OROCOS_ROCK_ROOT="$2"
    unset OROCOS_ROCK_RUBY_GEM_CACHE
    orocos_rock_prepare_autoproj_workspace "$3" none gnulinux
  SH
  stdout, stderr, status = Open3.capture3(
    { "PATH" => "#{bin}:/usr/bin:/bin" },
    "bash", "-c", prepare_command, "online-workspace",
    COMMON, workspace, File.join(directory, "prefix")
  )
  assert(
    status.success?,
    "could not prepare online Autoproj workspace: #{stdout}#{stderr}"
  )

  gemfile = File.read(File.join(workspace, ".autoproj", "Gemfile"))
  facets_declarations = gemfile.lines.grep(/^gem "facets"/).map(&:chomp)
  assert(
    facets_declarations == ['gem "facets", "= 3.1.0"'],
    "online Gemfile must pin the Ruby 3.0-compatible Facets release: #{facets_declarations.inspect}"
  )
end

Dir.mktmpdir("orocos-locked-autoproj-") do |directory|
  cache = File.join(directory, "cache")
  bin = File.join(directory, "bin")
  gem_log = File.join(directory, "gem.log")
  curl_log = File.join(directory, "curl.log")
  fake_user_gems = File.join(directory, "user-gems")
  FileUtils.mkdir_p(cache)
  FileUtils.mkdir_p(bin)
  AUTOPROJ_GEMS.each do |_name, _version, filename|
    File.write(File.join(cache, filename), "fixture\n")
  end
  cached_paths = AUTOPROJ_GEMS.map do |_name, _version, filename|
    File.join(cache, filename)
  end.join("\\n")
  locked_gemfile = AUTOPROJ_GEMS.map do |name, version, _filename|
    %(gem "#{name}", "= #{version}")
  end.join("\\n")

  File.write(
    File.join(bin, "autoproj"),
    "#!/bin/sh\nexit 0\n"
  )
  File.write(
    File.join(bin, "gem"),
    <<~SH
      #!/bin/sh
      printf '%s\n' "$*" >>"#{gem_log}"
      exit 0
    SH
  )
  File.write(
    File.join(bin, "curl"),
    <<~SH
      #!/bin/sh
      printf '%s\n' "$*" >>"#{curl_log}"
      exit 97
    SH
  )
  File.write(
    File.join(bin, "ruby"),
    <<~SH
      #!/bin/sh
      case "$*" in
        *"locked-ruby-gems.rb paths"*) printf '%b\n' "#{cached_paths}" ;;
        *"locked-ruby-gems.rb gemfile"*) printf '%b\n' '#{locked_gemfile}' ;;
        *"Gem.bin_path"*) printf '%s' "/fixture/bundle" ;;
        *"print Gem.user_dir +"*) printf '%s' "#{fake_user_gems}:default-gems" ;;
        *"print Gem.user_dir"*) printf '%s' "#{fake_user_gems}" ;;
        *) exit 0 ;;
      esac
    SH
  )
  %w[autoproj curl gem ruby].each do |command|
    FileUtils.chmod(0o755, File.join(bin, command))
  end

  stdout, stderr, status = Open3.capture3(
    {
      "HOME" => File.join(directory, "home"),
      "PATH" => "#{bin}:/usr/bin:/bin",
      "RUBYGEMS_HOST" => "https://network.invalid"
    },
    "bash", INSTALL_AUTOPROJ, "--gem-cache", cache
  )
  output = "#{stdout}#{stderr}"
  assert(status.success?, "locked Autoproj fixture failed: #{output.inspect}")
  assert(!File.exist?(curl_log), "locked Autoproj install invoked curl")
  assert(
    File.file?(gem_log),
    "a preexisting autoproj command bypassed the locked artifact install"
  )

  gem_commands = File.readlines(gem_log, chomp: true)
  assert(
    gem_commands.length == AUTOPROJ_GEMS.length,
    "locked Autoproj install did not install every artifact exactly once: #{gem_commands.inspect}"
  )
  AUTOPROJ_GEMS.zip(gem_commands).each do |(_name, _version, filename), command|
    assert(command.include?("--user-install"), "cached gem install was not user-local: #{command}")
    assert(command.include?("--local"), "cached gem install allowed remote resolution: #{command}")
    assert(command.include?("--ignore-dependencies"), "cached gem install resolved dependencies: #{command}")
    assert(
      command.end_with?(File.join(cache, filename)),
      "cached gem install used the wrong artifact: #{command}"
    )
  end

  workspace = File.join(directory, "workspace")
  FileUtils.mkdir_p(File.join(workspace, "tools"))
  FileUtils.cp(File.join(ROOT, "tools", "locked-ruby-gems.rb"), File.join(workspace, "tools"))
  stale_cache = File.join(workspace, ".autoproj", "vendor", "cache")
  FileUtils.mkdir_p(File.join(stale_cache, "stale-directory"))
  File.write(File.join(stale_cache, "stale.txt"), "stale\n")
  File.symlink(cache, File.join(stale_cache, "stale-link"))
  prepare_command = <<~'SH'
    . "$1"
    OROCOS_ROCK_ROOT="$2"
    orocos_rock_set_ruby_gem_cache "$3"
    orocos_rock_prepare_autoproj_workspace "$4" none gnulinux
  SH
  prepare_stdout, prepare_stderr, prepare_status = Open3.capture3(
    { "PATH" => "#{bin}:/usr/bin:/bin" },
    "bash", "-c", prepare_command, "locked-workspace",
    COMMON, workspace, cache, File.join(directory, "prefix")
  )
  assert(
    prepare_status.success?,
    "could not prepare locked Autoproj workspace: #{prepare_stdout}#{prepare_stderr}"
  )

  gemfile = File.read(File.join(workspace, ".autoproj", "Gemfile"))
  launcher = File.read(File.join(workspace, ".autoproj", "bin", "autoproj"))
  bundler = File.read(File.join(workspace, ".autoproj", "bin", "bundle"))
  bundler_cache = File.join(workspace, ".autoproj", "vendor", "cache")
  AUTOPROJ_GEMS.each do |name, version, _filename|
    declaration = %(gem "#{name}", "= #{version}")
    assert(gemfile.include?(declaration), "locked Gemfile is missing #{declaration}")
  end
  assert(
    launcher.include?('activate_autoproj!') && launcher.include?('= 2.18.1'),
    "cache-mode launcher must validate and activate Autoproj 2.18.1 exactly"
  )
  assert(
    bundler.include?('install)') && bundler.include?('install --local'),
    "cache-mode Bundler shim must force every install to local resolution"
  )
  assert(
    bundler.include?(bundler_cache) && !bundler.include?(%{BUNDLE_CACHE_PATH="#{cache}"}),
    "cache-mode Bundler shim must not let Bundler mutate the recipe cache"
  )
  copied_artifacts = Dir.children(bundler_cache).sort
  assert(
    copied_artifacts == AUTOPROJ_GEMS.map(&:last).sort,
    "derived Bundler cache does not match the locked Autoproj closure"
  )
end

puts "Linux Ruby gem input tests passed."
