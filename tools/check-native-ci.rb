#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github", "workflows", "native-toolchain.yml")
errors = []

if !File.file?(workflow_path)
  errors << "missing .github/workflows/native-toolchain.yml"
else
  contents = File.read(workflow_path)

  errors << "native CI must run on pull requests" unless contents.include?("pull_request:")
  errors << "native CI must run on pushes to main" unless contents.include?("push:") && contents.include?("- main")
  errors << "native CI must not run for docs-only changes" if contents.match?(/docs\//)
  errors << "native CI must define a Ubuntu version matrix" unless contents.include?("matrix:") && contents.include?("ubuntu-version:")
  %w[22.04 24.04].each do |version|
    errors << "native CI must cover Ubuntu #{version}" unless contents.include?(%("#{version}"))
  end
  errors << "native CI must not require Ubuntu 26.04 yet" if contents.include?(%("26.04"))
  errors << "native CI must use standard Ubuntu containers" unless contents.include?("image: ubuntu:${{ matrix.ubuntu-version }}")
  errors << "native CI must export SHELL for Autoproj" unless contents.include?("SHELL: /bin/bash")
  errors << "native CI must install build-essential for native Ruby gems and package builds" unless contents.include?("build-essential")
  errors << "native CI must install cmake before Autoproj build" unless contents.include?("cmake")
  errors << "native CI must install Boost headers before utilmm configure" unless contents.include?("libboost-dev")
  errors << "native CI must install omniORB headers and IDL compiler" unless contents.include?("libomniorb4-dev") && contents.include?("omniidl")
  errors << "native CI must install XML and XPath support" unless contents.include?("libxml2-dev") && contents.include?("libxml-xpath-perl")
  errors << "native CI must install pkg-config" unless contents.include?("pkg-config")
  errors << "native CI must install libffi headers for the ffi Ruby gem" unless contents.include?("libffi-dev")
  errors << "native CI must install Ruby development headers" unless contents.include?("ruby-dev")
  errors << "native CI must install ripgrep for warning checks" unless contents.include?("ripgrep")
  errors << "native CI must install Autoproj through the wrapper" unless contents.include?("./tools/install-autoproj.sh")
  errors << "native CI must run Autoproj policy check" unless contents.include?("ruby tools/check-autoproj-policy.rb")
  errors << "native CI must run package test workflow policy check" unless contents.include?("ruby tools/check-package-tests-ci.rb")
  errors << "native CI must bootstrap through the wrapper" unless contents.include?("./tools/bootstrap.sh --prefix")
  errors << "native CI must build through the wrapper" unless contents.include?("./tools/install.sh --prefix")
  errors << "native CI must validate the installed prefix" unless contents.include?("./tools/validate-install.sh --prefix")
  errors << "native CI must fail on compiler warnings" unless contents.include?("compiler warning budget exceeded")
  errors << "native CI must scan build logs" unless contents.include?('"$OROCOS_ROCK_PREFIX"/toolchain/log/*-build.log')
  errors << "native CI must upload diagnostic logs on failure" unless contents.include?("actions/upload-artifact@v6") && contents.include?("if: failure()")
  errors << "native CI must upload package build logs" unless contents.include?("toolchain/log/*.log")
  errors << "native CI must upload Autoproj configuration/log context" unless contents.include?(".autoproj/config.yml") && contents.include?(".autoproj/remotes/**/*.autobuild")
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
