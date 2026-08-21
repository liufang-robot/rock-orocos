# Define the github: shorthand used by imported Rock package sets.
require "autoproj/git_server_configuration"

# Keep builds repeatable by letting the build configuration define the
# toolchain environment explicitly.
build_tools_prefix = ENV["OROCOS_ROCK_BUILD_TOOLS_PREFIX"]
dependency_prefix = ENV["OROCOS_ROCK_DEPENDENCY_PREFIX"]
Autoproj.isolate_environment
if build_tools_prefix && !build_tools_prefix.empty?
    Autoproj.env_add_path "PATH", File.join(build_tools_prefix, "bin")
end

Autobuild::CMake.show_make_messages = true
if dependency_prefix && !dependency_prefix.empty?
    Autobuild::CMake.prefix_path << dependency_prefix
    %w[lib/pkgconfig lib64/pkgconfig share/pkgconfig].each do |relative_path|
        Autoproj.env_add_path(
            "PKG_CONFIG_PATH", File.join(dependency_prefix, relative_path)
        )
    end
end
