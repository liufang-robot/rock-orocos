#!/usr/bin/env ruby

require "yaml"

root = File.expand_path("..", __dir__)
overrides_path = File.join(root, "autoproj", "overrides.yml")
install_path = File.join(root, "tools", "install.sh")
setup_path = File.join(root, "tools", "setup.sh")
rtt_manifest_path = File.join(root, "autoproj", "manifests", "rtt.xml")
export_env_path = File.join(root, "tools", "export-env.sh")
validate_install_path = File.join(root, "tools", "validate-install.sh")
ruby_tools_path = File.join(root, "tools", "install-ruby-tools.sh")
common_path = File.join(root, "tools", "common.sh")
native_ci_check_path = File.join(root, "tools", "check-native-ci.rb")
package_tests_ci_check_path = File.join(root, "tools", "check-package-tests-ci.rb")
cpp17_policy_check_path = File.join(root, "tools", "check-cpp17-policy.rb")

expected_forks = {
  "rtt" => "https://github.com/liufang-robot/rtt.git",
  "ocl" => "https://github.com/liufang-robot/ocl.git",
  "log4cpp" => "https://github.com/liufang-robot/log4cpp.git",
  "orogen" => "https://github.com/liufang-robot/tools-orogen.git",
  "typelib" => "https://github.com/liufang-robot/tools-typelib.git",
  "utilmm" => "https://github.com/liufang-robot/utilmm.git",
  "rtt_typelib" => "https://github.com/liufang-robot/tools-rtt_typelib.git",
  "stdint_typekit" => "https://github.com/liufang-robot/stdint_typekit.git"
}

overrides = YAML.safe_load_file(overrides_path).fetch("overrides", [])
errors = []

expected_forks.each do |package, url|
  override = overrides.find { |entry| entry.key?(package) }

  if override.nil?
    errors << "#{package}: missing source override"
    next
  end

  actual_url = override["url"]
  actual_branch = override["branch"]

  errors << "#{package}: expected url #{url}, got #{actual_url.inspect}" unless actual_url == url
  errors << "#{package}: expected branch MetaNC, got #{actual_branch.inspect}" unless actual_branch == "MetaNC"
end

install_script = File.read(install_path)
setup_script = File.file?(setup_path) ? File.read(setup_path) : nil
common_script = File.read(common_path)
overrides_script = File.read(File.join(root, "autoproj", "overrides.rb"))
export_env_script = File.read(export_env_path)
validate_install_script = File.read(validate_install_path)

expected_forks.each_key do |package|
  refreshes_package = install_script.include?("FORKED_PACKAGES=(") &&
                      install_script.match?(/FORKED_PACKAGES=\([^)]*\b#{Regexp.escape(package)}\b[^)]*\)/m)
  errors << "install.sh: must refresh maintained fork #{package}" unless refreshes_package
end

source_update = install_script.index("orocos_rock_autoproj update")
osdeps = install_script.index("orocos_rock_autoproj osdeps")
build = install_script.index("orocos_rock_autoproj build")

if source_update.nil?
  errors << "install.sh: missing Autoproj source update before build"
elsif build && source_update > build
  errors << "install.sh: Autoproj source update must run before build"
end

cpp17_check = install_script.index('ruby "$SCRIPT_DIR/check-cpp17-policy.rb"')
if cpp17_check.nil?
  errors << "install.sh: missing C++17 package policy check after source update"
elsif source_update && cpp17_check < source_update
  errors << "install.sh: C++17 package policy check must run after Autoproj source update"
elsif build && cpp17_check > build
  errors << "install.sh: C++17 package policy check must run before build"
end

if osdeps.nil?
  errors << "install.sh: missing Autoproj osdeps refresh after source update"
elsif source_update && osdeps < source_update
  errors << "install.sh: Autoproj osdeps refresh must happen after source update"
elsif build && osdeps > build
  errors << "install.sh: Autoproj osdeps refresh must happen before build"
end

unless overrides_script.match?(/setup_package\s+["']rtt["']/) &&
       overrides_script.include?("use_package_xml = true")
  errors << "autoproj/overrides.rb: rtt must opt into package.xml manifest loading"
end

unless export_env_script.include?('PATH "\$OROCOS_ROCK_PREFIX/toolchain/bin"')
  errors << "tools/export-env.sh: env.sh must prepend the installed toolchain bin directory"
end

unless export_env_script.include?('CMAKE_PREFIX_PATH "\$OROCOS_ROCK_PREFIX/toolchain"')
  errors << "tools/export-env.sh: env.sh must prepend the installed toolchain prefix"
end

unless export_env_script.include?('GEM_HOME="\${GEM_HOME:-') &&
       export_env_script.include?('toolchain/gems')
  errors << "tools/export-env.sh: dev-env.sh must activate the installed Ruby gem home"
end

unless validate_install_script.include?("deployer-gnulinux --version") &&
       validate_install_script.include?("OROCOS Toolchain version")
  errors << "tools/validate-install.sh: must smoke-test deployer-gnulinux"
end

unless validate_install_script.include?("orogen --help")
  errors << "tools/validate-install.sh: must smoke-test orogen"
end

unless validate_install_script.include?("typegen --help")
  errors << "tools/validate-install.sh: must smoke-test typegen"
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
errors << "tools/check-cpp17-policy.rb: missing C++17 policy check" unless File.file?(cpp17_policy_check_path)

unless install_script.include?('"$SCRIPT_DIR/install-ruby-tools.sh" --prefix "$PREFIX"')
  errors << "install.sh: must stage Ruby generator tools into the install prefix"
end

if setup_script.nil?
  errors << "tools/setup.sh: missing user-facing setup wrapper"
else
  expected_setup_steps = [
    '"$SCRIPT_DIR/install-autoproj.sh"',
    '"$SCRIPT_DIR/bootstrap.sh" --prefix "$PREFIX"',
    '"$SCRIPT_DIR/install.sh" --prefix "$PREFIX"',
    '"$SCRIPT_DIR/validate-install.sh" --prefix "$PREFIX"'
  ]
  expected_setup_steps.each do |step|
    errors << "tools/setup.sh: missing setup step #{step}" unless setup_script.include?(step)
  end
end

unless common_script.include?('.autoproj/Gemfile') &&
       common_script.include?('gem "autoproj", ">= 2.18.0"')
  errors << "tools/common.sh: must create .autoproj/Gemfile for Autoproj bundler osdeps"
end

unless common_script.include?('BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$OROCOS_ROCK_ROOT/.autoproj/Gemfile}"')
  errors << "tools/common.sh: must provide BUNDLE_GEMFILE while invoking Autoproj"
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
  errors << "autoproj/manifests/rtt.xml: must declare omniorb as a package dependency" unless rtt_manifest.include?('<depend package="omniorb" />')
  errors << "autoproj/manifests/rtt.xml: must declare xpath-perl as a package dependency" unless rtt_manifest.include?('<depend package="xpath-perl" />')
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
