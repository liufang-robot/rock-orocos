#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github", "workflows", "package-tests.yml")
errors = []

if !File.file?(workflow_path)
  errors << "missing .github/workflows/package-tests.yml"
else
  contents = File.read(workflow_path)

  errors << "package tests must run on pull requests" unless contents.include?("pull_request:")
  errors << "package tests must support manual dispatch" unless contents.include?("workflow_dispatch:")
  errors << "package tests must start on Ubuntu 22.04 only" unless contents.include?("image: ubuntu:22.04")
  errors << "package tests must be non-required while experimental" unless contents.include?("continue-on-error: true")
  errors << "package tests must define a package-test matrix" unless contents.include?("package-test:")
  %w[utilmm log4cpp typelib-cxx rtt-core ocl-basic].each do |package_test|
    errors << "package tests must include #{package_test}" unless contents.include?("- #{package_test}")
  end
  errors << "package tests must run the shared package test wrapper" unless contents.include?("./tools/test-package.sh")
  errors << "package tests must record package test status" unless contents.include?("status=$status") && contents.include?("GITHUB_OUTPUT")
  errors << "package tests must warn instead of failing while experimental" unless contents.include?("::warning::") && contents.include?("exit 0")
  errors << "package tests must upload diagnostic logs when package tests fail" unless contents.include?("actions/upload-artifact@v6") && contents.include?("steps.package-test.outputs.status != '0'")
  errors << "package tests must upload CTest logs" unless contents.include?("Testing/Temporary/*.log")
  errors << "package tests must upload CMake logs" unless contents.include?("CMakeOutput.log") && contents.include?("CMakeError.log")
  errors << "package tests must upload Autoproj package logs" unless contents.include?("toolchain/log/*.log")
  errors << "package tests must watch the package result record" unless contents.include?("docs/src/package-test-results.md")
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
