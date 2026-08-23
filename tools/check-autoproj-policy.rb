#!/usr/bin/env ruby

require "yaml"
require "open3"
require "pathname"
require_relative "check-source-provenance"

def setup_package_body(script, package)
  match = script.match(
    /^[ \t]*setup_package\s+["']#{Regexp.escape(package)}["']\s+do(?:\s+\|[^|]+\|)?\s*$\n(?<body>.*?)(?=^[ \t]*end\s*$)/m
  )
  match && match[:body]
end

def active_ruby_statements(body)
  return [] unless body

  body.each_line.filter_map do |line|
    statement = line.strip
    statement unless statement.empty? || statement.start_with?("#")
  end
end

def executable_file?(root, path)
  relative_path = Pathname.new(path).relative_path_from(Pathname.new(root))
  output, status = Open3.capture2(
    "git", "-c", "safe.directory=#{root}",
    "-C", root, "ls-files", "--stage", "--", relative_path.to_s
  )
  status.success? && output.each_line.any? { |line| line.start_with?("100755 ") }
end

root = File.expand_path("..", __dir__)
manifest_path = File.join(root, "autoproj", "manifest")
overrides_path = File.join(root, "autoproj", "overrides.yml")
local_autobuild_path = File.join(root, "autoproj", "local.autobuild")
init_path = File.join(root, "autoproj", "init.rb")
install_path = File.join(root, "tools", "install.sh")
bootstrap_path = File.join(root, "tools", "bootstrap.sh")
install_autoproj_path = File.join(root, "tools", "install-autoproj.sh")
setup_path = File.join(root, "tools", "setup.sh")
update_path = File.join(root, "tools", "update.sh")
update_test_path = File.join(root, "tools", "test-update.sh")
rtt_manifest_path = File.join(root, "autoproj", "manifests", "rtt.xml")
local_osdeps_path = File.join(root, "autoproj", "orocos-rock.osdeps")
export_env_path = File.join(root, "tools", "export-env.sh")
validate_install_path = File.join(root, "tools", "validate-install.sh")
ruby_tools_path = File.join(root, "tools", "install-ruby-tools.sh")
common_path = File.join(root, "tools", "common.sh")
native_ci_check_path = File.join(root, "tools", "check-native-ci.rb")
package_tests_ci_check_path = File.join(root, "tools", "check-package-tests-ci.rb")
windows_package_ci_check_path = File.join(root, "tools", "check-windows-package-ci.rb")
cpp20_policy_check_path = File.join(root, "tools", "check-cpp20-policy.rb")
rtlog_prefix_check_path = File.join(root, "tools", "check-rtlog-prefix.sh")
resolved_dependencies_check_path = File.join(root, "tools", "check-resolved-dependencies.rb")

expected_sources = {
  "farbot" => { "url" => "https://github.com/liufang-robot/farbot.git", "branch" => "master" },
  "rtlog-cpp" => { "url" => "https://github.com/liufang-robot/rtlog-cpp.git", "branch" => "main" },
  "open62541" => { "url" => "https://github.com/open62541/open62541.git", "tag" => "v1.4.15" },
  "open62541pp" => { "url" => "https://github.com/open62541pp/open62541pp.git", "tag" => "v0.21.2" },
  "rtt" => { "url" => "https://github.com/liufang-robot/rtt.git", "branch" => "dev" },
  "rtt_opcua" => {
    "url" => "https://github.com/liufang-robot/rtt_opcua.git",
    "branch" => "fix/proxy-shutdown-lost-wakeup"
  },
  "ocl" => { "url" => "https://github.com/liufang-robot/ocl.git", "branch" => "dev" },
  "orogen" => {
    "url" => "https://github.com/liufang-robot/tools-orogen.git",
    "branch" => "dev",
    "commit" => "3346b6ac682ad772b57d07b2386cdaef47e4abbe"
  },
  "typelib" => { "url" => "https://github.com/liufang-robot/tools-typelib.git", "branch" => "dev" },
  "utilmm" => { "url" => "https://github.com/liufang-robot/utilmm.git", "branch" => "dev" },
  "rtt_typelib" => { "url" => "https://github.com/liufang-robot/tools-rtt_typelib.git", "branch" => "dev" }
}
local_source_packages = %w[farbot rtlog-cpp open62541 open62541pp rtt_opcua]

manifest = File.read(manifest_path)
source_selection = YAML.safe_load_file(overrides_path)
version_control = source_selection.fetch("version_control", [])
overrides = source_selection.fetch("overrides", [])
errors = []
errors.concat(OrocosRock::SourceProvenance.validate_autoproj(root))

expected_sources.each do |package, source|
  source_entries = local_source_packages.include?(package) ? version_control : overrides
  matching_entries = source_entries.select { |entry| entry.key?(package) }

  if matching_entries.empty?
    errors << "#{package}: missing source selection"
    next
  end
  if matching_entries.size > 1
    errors << "#{package}: expected exactly one source selection, got #{matching_entries.size}"
  end

  matching_entries.each do |override|
    source.each do |key, expected|
      actual = override[key]
      errors << "#{package}: expected #{key} #{expected}, got #{actual.inspect}" unless actual == expected
    end
  end
end

install_script = File.read(install_path)
bootstrap_script = File.read(bootstrap_path)
install_autoproj_script = File.read(install_autoproj_path)
setup_script = File.file?(setup_path) ? File.read(setup_path) : nil
update_script = File.file?(update_path) ? File.read(update_path) : ""
common_script = File.read(common_path)
overrides_script = File.read(File.join(root, "autoproj", "overrides.rb"))
local_autobuild_script = File.file?(local_autobuild_path) ? File.read(local_autobuild_path) : ""
init_script = File.read(init_path)
local_osdeps = File.file?(local_osdeps_path) ? File.read(local_osdeps_path) : ""
local_osdeps_data = local_osdeps.empty? ? {} : (YAML.safe_load(local_osdeps) || {})
export_env_script = File.read(export_env_path)
validate_install_script = File.read(validate_install_path)

errors << "missing executable tools/update.sh" unless executable_file?(root, update_path)
errors << "missing executable tools/test-update.sh" unless executable_file?(root, update_test_path)
unless update_script.include?("git pull --ff-only")
  errors << "update.sh: must fast-forward the configured root upstream"
end
unless update_script.include?("orocos_rock_autoproj update")
  errors << "update.sh: must update the Autoproj layout"
end
errors << "update.sh: must disable osdeps" unless update_script.include?("--no-osdeps")
if update_script.match?(/orocos_rock_autoproj\s+build/)
  errors << "update.sh: must not build packages"
end

unless init_script.include?('build_tools_prefix = ENV["OROCOS_ROCK_BUILD_TOOLS_PREFIX"]') &&
       init_script.include?('Autoproj.env_add_path "PATH", File.join(build_tools_prefix, "bin")')
  errors << "autoproj/init.rb: must preserve an explicitly selected package-build tool prefix"
end
unless init_script.include?('dependency_prefix = ENV["OROCOS_ROCK_DEPENDENCY_PREFIX"]') &&
       init_script.include?('Autobuild::CMake.prefix_path << dependency_prefix') &&
       init_script.include?('"PKG_CONFIG_PATH", File.join(dependency_prefix, relative_path)')
  errors << "autoproj/init.rb: must preserve an explicitly selected package dependency prefix"
end
if update_script.match?(/--(?:force-)?reset/)
  errors << "update.sh: must not reset package repositories"
end

if manifest.match?(/\bstdint_typekit\b/)
  errors << "autoproj/manifest: stdint_typekit is retired because RTT provides fixed-width built-ins"
end
if (version_control + overrides).any? { |entry| entry.key?("stdint_typekit") }
  errors << "autoproj/overrides.yml: stdint_typekit must not have a source selection"
end
if install_script.match?(/\bstdint_typekit\b/)
  errors << "tools/install.sh: stdint_typekit must not be refreshed or built"
end

expected_sources.each_key do |package|
  refreshes_package = install_script.include?("SOURCE_PACKAGES=(") &&
                      install_script.match?(/SOURCE_PACKAGES=\([^)]*\b#{Regexp.escape(package)}\b[^)]*\)/m)
  errors << "install.sh: must refresh selected source package #{package}" unless refreshes_package
end

unless local_autobuild_script.include?('cmake_package "farbot"')
  errors << "autoproj/local.autobuild: must define farbot as a local CMake package"
end

unless local_autobuild_script.include?('cmake_package "rtlog-cpp"') &&
       local_autobuild_script.include?('pkg.depends_on "farbot"')
  errors << "autoproj/local.autobuild: must define rtlog-cpp as a local CMake package depending on farbot"
end

unless local_autobuild_script.include?('cmake_package "open62541"') &&
       local_autobuild_script.include?('pkg.define "UA_NAMESPACE_ZERO", "REDUCED"')
  errors << "autoproj/local.autobuild: must define the reduced open62541 package"
end

unless local_autobuild_script.include?('pkg.define "UA_BUILD_UNIT_TESTS", "OFF"')
  errors << "autoproj/local.autobuild: must disable open62541 dependency tests"
end

unless local_autobuild_script.include?('cmake_package "open62541pp"') &&
       local_autobuild_script.include?('pkg.depends_on "open62541"') &&
       local_autobuild_script.include?('pkg.define "UAPP_INTERNAL_OPEN62541", "OFF"')
  errors << "autoproj/local.autobuild: must build open62541pp against the selected open62541 package"
end

unless local_autobuild_script.include?('pkg.define "UAPP_BUILD_TESTS", "OFF"')
  errors << "autoproj/local.autobuild: must disable open62541pp dependency tests"
end

unless local_autobuild_script.include?('pkg.define "UAPP_INTERNAL_OPEN62541", "OFF"')
  errors << "autoproj/local.autobuild: must disable open62541pp's internal open62541 dependency"
end

unless local_autobuild_script.include?('cmake_package "rtt_opcua"') &&
       local_autobuild_script.include?('pkg.depends_on "rtt"') &&
       local_autobuild_script.include?('pkg.depends_on "open62541pp"') &&
       local_autobuild_script.include?('move_package "rtt_opcua", "tools"')
  errors << "autoproj/local.autobuild: must define rtt_opcua in the toolchain tools layout"
end

unless install_script.match?(/SOURCE_PACKAGES=\([^)]*\bfarbot\b[^)]*\brtlog-cpp\b[^)]*\brtt\b[^)]*\)/m)
  errors << "install.sh: farbot and rtlog-cpp must be refreshed before rtt"
end

rtt_position = manifest.index("    - rtt\n")
rtt_opcua_position = manifest.index("    - rtt_opcua\n")
ocl_position = manifest.index("    - ocl\n")
if rtt_opcua_position.nil?
  errors << "autoproj/manifest: must select rtt_opcua"
elsif rtt_position.nil? || ocl_position.nil? ||
      !(rtt_position < rtt_opcua_position && rtt_opcua_position < ocl_position)
  errors << "autoproj/manifest: rtt_opcua must be ordered after rtt and before ocl"
end

source_update = install_script.index("orocos_rock_autoproj update")
osdeps = install_script.index("orocos_rock_autoproj osdeps")
build = install_script.index("orocos_rock_autoproj build")

if source_update.nil?
  errors << "install.sh: missing Autoproj source update before build"
elsif build && source_update > build
  errors << "install.sh: Autoproj source update must run before build"
end

cpp20_check = install_script.index('ruby "$SCRIPT_DIR/check-cpp20-policy.rb"')
if cpp20_check.nil?
  errors << "install.sh: missing C++20 package policy check after source update"
elsif source_update && cpp20_check < source_update
  errors << "install.sh: C++20 package policy check must run after Autoproj source update"
elsif build && cpp20_check > build
  errors << "install.sh: C++20 package policy check must run before build"
end

if osdeps.nil?
  errors << "install.sh: missing Autoproj osdeps refresh after source update"
elsif source_update && osdeps < source_update
  errors << "install.sh: Autoproj osdeps refresh must happen after source update"
elsif build && osdeps > build
  errors << "install.sh: Autoproj osdeps refresh must happen before build"
end

rtt_setup = active_ruby_statements(setup_package_body(overrides_script, "rtt"))
unless rtt_setup.include?("pkg.use_package_xml = true")
  errors << "autoproj/overrides.rb: rtt must opt into package.xml manifest loading"
end

unless rtt_setup.include?('pkg.depends_on "rtlog-cpp"')
  errors << "autoproj/overrides.rb: rtt must depend on rtlog-cpp for the bounded logger backend"
end

unless rtt_setup.include?('pkg.define "ENABLE_MQ", "ON"')
  errors << "autoproj/overrides.rb: rtt must build the mqueue transport"
end

unless rtt_setup.include?('pkg.define "ENABLE_CORBA", "OFF"')
  errors << "autoproj/overrides.rb: rtt must keep CORBA disabled"
end

unless rtt_setup.include?('pkg.description.dependencies.delete_if { |dependency| dependency.name == "omniorb" }') &&
       rtt_setup.include?('pkg.remove_dependency "omniorb"')
  errors << "autoproj/overrides.rb: rtt must remove the package.xml omniorb dependency for no-CORBA builds"
end

ocl_setup = active_ruby_statements(setup_package_body(overrides_script, "ocl"))
unless ocl_setup.include?('pkg.depends_on "rtt_opcua"') &&
       ocl_setup.include?('pkg.define "BUILD_OPCUA", "ON"')
  errors << "autoproj/overrides.rb: ocl must build against rtt_opcua"
end

unless export_env_script.include?('OROCOS_PREFIX="$PREFIX"') &&
       export_env_script.include?("export OROCOS_PREFIX")
  errors << "tools/export-env.sh: env.sh must bind OROCOS_PREFIX to the generated install prefix"
end

unless common_script.include?("orocos_rock_validate_target") &&
       common_script.include?("gnulinux|xenomai") &&
       common_script.include?('rtt_target: "$target"')
  errors << "tools/common.sh: must validate gnulinux/xenomai targets and persist rtt_target in Autoproj config"
end

unless install_script.include?("--target TARGET") &&
       install_script.include?('"$SCRIPT_DIR/export-env.sh" --prefix "$PREFIX" --target "$TARGET"')
  errors << "tools/install.sh: must accept --target and pass it to export-env.sh"
end

unless common_script.include?("orocos_rock_run_preserving_install_env") &&
       bootstrap_script.scan('orocos_rock_run_preserving_install_env "$PREFIX"').size == 2 &&
       install_script.scan('orocos_rock_run_preserving_install_env "$PREFIX"').size == 3
  errors << "bootstrap/install wrappers must preserve public environment scripts around Autoproj commands"
end

unless export_env_script.include?("--target TARGET") &&
       export_env_script.include?('OROCOS_TARGET="$TARGET"')
  errors << "tools/export-env.sh: env.sh must export the selected Orocos target"
end

if export_env_script.include?('${OROCOS_ROCK_PREFIX:-')
  errors << "tools/export-env.sh: generated env.sh must not redirect through OROCOS_ROCK_PREFIX"
end

unless export_env_script.include?('PATH "\$OROCOS_PREFIX/toolchain/bin"')
  errors << "tools/export-env.sh: env.sh must prepend the installed toolchain bin directory"
end

unless export_env_script.include?('CMAKE_PREFIX_PATH "\$OROCOS_PREFIX/toolchain"')
  errors << "tools/export-env.sh: env.sh must prepend the installed toolchain prefix"
end

unless export_env_script.include?('TYPELIB_PLUGIN_PATH "\$OROCOS_PREFIX/toolchain/lib/typelib"')
  errors << "tools/export-env.sh: env.sh must expose relocatable Typelib plugin discovery"
end

root_lib = export_env_script.index('LD_LIBRARY_PATH "\$OROCOS_PREFIX/lib"')
toolchain_lib = export_env_script.index('LD_LIBRARY_PATH "\$OROCOS_PREFIX/toolchain/lib"')
if root_lib && toolchain_lib && root_lib > toolchain_lib
  errors << "tools/export-env.sh: toolchain libraries must take precedence over root prefix libraries"
end

root_pkg_config = export_env_script.index('PKG_CONFIG_PATH "\$OROCOS_PREFIX/lib/pkgconfig"')
toolchain_pkg_config = export_env_script.index('PKG_CONFIG_PATH "\$OROCOS_PREFIX/toolchain/lib/pkgconfig"')
if root_pkg_config && toolchain_pkg_config && root_pkg_config > toolchain_pkg_config
  errors << "tools/export-env.sh: toolchain pkg-config metadata must take precedence over root prefix metadata"
end

unless export_env_script.include?('GEM_HOME="\$OROCOS_PREFIX/toolchain/gems"') &&
       export_env_script.include?('ruby -rrubygems -e \'print Gem.default_dir\'') &&
       export_env_script.include?('GEM_PATH="\$GEM_HOME:\$orocos_rock_default_gem_dir"')
  errors << "tools/export-env.sh: dev-env.sh must isolate the installed Ruby gem home and retain default gems"
end

unless export_env_script.include?('toolchain/lib/ruby/$RUBY_VERSION_ABI/$RUBY_ARCH')
  errors << "tools/export-env.sh: dev-env.sh must expose the installed native Ruby extension directory"
end

unless validate_install_script.include?('DEPLOYER="$(orocos_rock_target_deployer "$TARGET")"') &&
       validate_install_script.include?("orocos_rock_validate_deployer_version_output")
  errors << "tools/validate-install.sh: must smoke-test the selected target deployer"
end

unless validate_install_script.include?('OPCUA_DEPLOYER="$(orocos_rock_target_opcua_deployer "$TARGET")"') &&
       validate_install_script.include?('pkg-config --exists "rtt_opcua-$TARGET"')
  errors << "tools/validate-install.sh: must smoke-test the installed OPC UA transport"
end

mqueue_transport = 'MQUEUE_TRANSPORT="$PREFIX/toolchain/lib/orocos/$TARGET/types/librtt-transport-mqueue-$TARGET.so"'
unless validate_install_script.include?(mqueue_transport) &&
       validate_install_script.include?('orocos_rock_require_file "$MQUEUE_TRANSPORT"')
  errors << "tools/validate-install.sh: must require the installed target-specific mqueue transport"
end

unless common_script.include?("orocos_rock_validate_deployer_version_output") &&
       common_script.include?("OROCOS Toolchain version") &&
       common_script.include?("Xenomai/cobalt")
  errors << "tools/common.sh: must validate deployer version output for gnulinux and xenomai"
end

unless common_script.include?("orocos_rock_target_opcua_deployer") &&
       common_script.include?('deployer-opcua-$1')
  errors << "tools/common.sh: must resolve the target-specific OPC UA deployer"
end

unless validate_install_script.include?("orogen --help")
  errors << "tools/validate-install.sh: must smoke-test orogen"
end

unless validate_install_script.include?("typegen --help")
  errors << "tools/validate-install.sh: must smoke-test typegen"
end

unless validate_install_script.include?('.invalid-workspace-gem-home') &&
       validate_install_script.include?('.invalid-workspace-gem-path') &&
       validate_install_script.include?('ruby -e \'require "typelib"; require "orogen"\'')
  errors << "tools/validate-install.sh: must reject inherited workspace gems and load the installed generator stack"
end

unless validate_install_script.include?('TYPELIB_PLUGIN_PATH') &&
       validate_install_script.include?('toolchain/lib/typelib')
  errors << "tools/validate-install.sh: must check installed Typelib plugin discovery"
end

unless File.file?(ruby_tools_path)
  errors << "tools/install-ruby-tools.sh: missing Ruby tool staging script"
else
  ruby_tools_script = File.read(ruby_tools_path)
  errors << "tools/install-ruby-tools.sh: must stage utilrb" unless ruby_tools_script.include?("toolchain/tools/utilrb")
  errors << "tools/install-ruby-tools.sh: must stage metaruby" unless ruby_tools_script.include?("tools/metaruby")
  errors << "tools/install-ruby-tools.sh: must stage orogen" unless ruby_tools_script.include?("toolchain/tools/orogen")
end

errors << "tools/check-native-ci.rb: missing native CI policy check" unless File.file?(native_ci_check_path)
errors << "tools/check-package-tests-ci.rb: missing package test CI policy check" unless File.file?(package_tests_ci_check_path)
errors << "tools/check-windows-package-ci.rb: missing Windows package CI policy check" unless File.file?(windows_package_ci_check_path)
errors << "tools/check-cpp20-policy.rb: missing C++20 policy check" unless File.file?(cpp20_policy_check_path)
errors << "tools/check-rtlog-prefix.sh: missing rtlog installed-prefix smoke test" unless File.file?(rtlog_prefix_check_path)
errors << "tools/check-resolved-dependencies.rb: missing resolved dependency policy check" unless File.file?(resolved_dependencies_check_path)

if File.file?(resolved_dependencies_check_path)
  resolved_dependencies_script = File.read(resolved_dependencies_check_path)
  unless resolved_dependencies_script.include?("Autoproj::CLI::InspectionTool") &&
         resolved_dependencies_script.include?("non_imported_packages: :return") &&
         resolved_dependencies_script.include?("rtt.os_packages.to_a")
    errors << "tools/check-resolved-dependencies.rb: must inspect the resolved Autoproj graph in read-only mode"
  end
  if resolved_dependencies_script.include?("installation-manifest")
    errors << "tools/check-resolved-dependencies.rb: must not rely on the potentially stale installation manifest"
  end
end

reconfigure = bootstrap_script.index("orocos_rock_autoproj reconfigure")
bootstrap_resolved_dependencies_check = bootstrap_script.index('ruby "$SCRIPT_DIR/check-resolved-dependencies.rb"')
bootstrap_osdeps = bootstrap_script.index("orocos_rock_autoproj osdeps")
if bootstrap_resolved_dependencies_check.nil?
  errors << "bootstrap.sh: missing resolved dependency policy check"
elsif reconfigure && bootstrap_resolved_dependencies_check < reconfigure
  errors << "bootstrap.sh: resolved dependency policy check must run after reconfigure"
elsif bootstrap_osdeps && bootstrap_resolved_dependencies_check > bootstrap_osdeps
  errors << "bootstrap.sh: resolved dependency policy check must run before osdeps"
end

install_resolved_dependencies_check = install_script.index('ruby "$SCRIPT_DIR/check-resolved-dependencies.rb"')
if install_resolved_dependencies_check.nil?
  errors << "install.sh: missing resolved dependency policy check"
elsif source_update && install_resolved_dependencies_check < source_update
  errors << "install.sh: resolved dependency policy check must run after source update"
elsif osdeps && install_resolved_dependencies_check > osdeps
  errors << "install.sh: resolved dependency policy check must run before osdeps"
end

[bootstrap_script, install_script].each do |script|
  unless script.include?('GEM_PATH="$(orocos_rock_user_gem_path)"')
    errors << "resolved dependency policy checks must use the Autoproj user/default gem path"
    break
  end
end

unless install_script.include?('"$SCRIPT_DIR/install-ruby-tools.sh" --prefix "$PREFIX"')
  errors << "install.sh: must stage Ruby generator tools into the install prefix"
end

if setup_script.nil?
  errors << "tools/setup.sh: missing user-facing setup wrapper"
else
  expected_setup_steps = [
    '"$SCRIPT_DIR/install-autoproj.sh"',
    '"$SCRIPT_DIR/bootstrap.sh" --prefix "$PREFIX" --target "$TARGET"',
    '"$SCRIPT_DIR/install.sh" --prefix "$PREFIX" --target "$TARGET"',
    '"$SCRIPT_DIR/validate-install.sh" --prefix "$PREFIX" --target "$TARGET"'
  ]
  expected_setup_steps.each do |step|
    errors << "tools/setup.sh: missing setup step #{step}" unless setup_script.include?(step)
  end
end

unless common_script.include?('.autoproj/Gemfile') &&
       common_script.include?('gem "autoproj", ">= 2.18.0"')
  errors << "tools/common.sh: must create .autoproj/Gemfile for Autoproj bundler osdeps"
end

unless common_script.include?('rtt_corba_implementation: none')
  errors << "tools/common.sh: must disable RTT CORBA by default"
end

unless common_script.include?('BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$OROCOS_ROCK_ROOT/.autoproj/Gemfile}"')
  errors << "tools/common.sh: must provide BUNDLE_GEMFILE while invoking Autoproj"
end

unless common_script.include?('orocos_rock_user_gem_path') &&
       common_script.include?('Gem.default_path') &&
       common_script.include?('gem_path="$(orocos_rock_user_gem_path)"') &&
       common_script.include?('GEM_PATH="$gem_path"')
  errors << "tools/common.sh: must include RubyGems user and default gem paths when loading Autoproj"
end

unless install_autoproj_script.include?('USER_GEM_PATH="$(orocos_rock_user_gem_path)"') &&
       install_autoproj_script.include?('GEM_PATH="$USER_GEM_PATH"')
  errors << "tools/install-autoproj.sh: must include RubyGems user and default gem paths when validating Autoproj"
end

unless common_script.include?('.autoproj/bin/bundle') &&
       common_script.include?('Gem.bin_path("bundler", "bundle")')
  errors << "tools/common.sh: must seed .autoproj/bin/bundle before Autoproj osdeps"
end

if !File.file?(rtt_manifest_path)
  errors << "autoproj/manifests/rtt.xml: missing tracked manifest for bootstrap-time RTT osdeps"
else
  rtt_manifest = File.read(rtt_manifest_path)
  errors << "autoproj/manifests/rtt.xml: must declare boost as a package dependency" unless rtt_manifest.include?('<depend package="boost" />')
  errors << "autoproj/manifests/rtt.xml: must not require omniorb while CORBA is disabled by default" if rtt_manifest.include?('<depend package="omniorb" />')
  errors << "autoproj/manifests/rtt.xml: must declare xpath-perl as a package dependency" unless rtt_manifest.include?('<depend package="xpath-perl" />')
end

if local_osdeps_data.key?("ruby")
  errors << "autoproj/orocos-rock.osdeps: must not override ruby directly; Autoproj aliases ruby to the active rubyXX osdep"
end

%w[ruby33 ruby34].each do |ruby_osdep|
  unless local_osdeps_data.dig(ruby_osdep, "debian,ubuntu") == "ruby"
    errors << "autoproj/orocos-rock.osdeps: must define #{ruby_osdep} for Debian/Ubuntu package-set compatibility"
  end
end

unless local_osdeps_data.dig("ruby-dev", "debian,ubuntu") == "ruby-dev"
  errors << "autoproj/orocos-rock.osdeps: must define ruby-dev for Debian/Ubuntu package-set compatibility"
end

if local_osdeps_data.key?("omniorb")
  errors << "autoproj/orocos-rock.osdeps: must not map omniorb for the no-CORBA build"
end

%w[ncurses libncurses libncurses-dev].each do |ncurses_osdep|
  unless local_osdeps_data.dig(ncurses_osdep, "debian,ubuntu") == "libncurses-dev"
    errors << "autoproj/orocos-rock.osdeps: must map #{ncurses_osdep} to libncurses-dev on Debian/Ubuntu"
  end
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
