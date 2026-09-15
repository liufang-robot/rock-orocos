#!/usr/bin/env ruby

require "autoproj/cli/inspection_tool"

root = File.expand_path("..", __dir__)
Dir.chdir(root)
ENV["AUTOPROJ_CURRENT_ROOT"] = root

workspace = Autoproj::Workspace.default
workspace.config.interactive = false
inspection = Autoproj::CLI::InspectionTool.new(workspace)
inspection.initialize_and_load(read_only: true)

inspection.finalize_setup(
  ["rtt", "eigen_typekit"],
  non_imported_packages: :return,
  recursive: true,
  read_only: true
)

eigen = workspace.manifest.find_autobuild_package("eigen_typekit")
abort "resolved Autoproj graph does not contain eigen_typekit" unless eigen
unless eigen.srcdir == File.join(eigen.importdir, "eigen_typekit")
  abort "eigen_typekit must configure only the eigen_typekit source subdirectory"
end
eigen_dependencies = eigen.dependencies.to_a + eigen.optional_dependencies.to_a +
                     eigen.os_packages.to_a + eigen.description.dependencies.map(&:name)
if eigen_dependencies.any? { |name| name.match?(/kdl|catkin|rtt_geometry|roscpp/) }
  abort "Eigen-only build resolved KDL or ROS dependencies: #{eigen_dependencies.inspect}"
end
abort "eigen_typekit must depend on RTT" unless eigen.dependencies.include?("rtt")
abort "eigen_typekit must depend on Eigen3" unless eigen.os_packages.include?("eigen3")

exit 0 unless workspace.config.get("rtt_corba_implementation") == "none"

rtt = workspace.manifest.find_autobuild_package("rtt")
abort "resolved Autoproj graph does not contain rtt" unless rtt

resolved_dependencies = rtt.dependencies.to_a +
                        rtt.optional_dependencies.to_a +
                        rtt.os_packages.to_a +
                        rtt.description.dependencies.map(&:name)

if resolved_dependencies.include?("omniorb")
  abort "rtt resolved omniorb even though rtt_corba_implementation is none"
end
