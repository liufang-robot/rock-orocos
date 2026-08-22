#!/usr/bin/env ruby

def package_test_case_arm(script, package_test)
  case_match = script.match(
    /^[ \t]*case\s+"\$PACKAGE_TEST"\s+in\s*$\n(?<body>.*?)(?=^[ \t]*esac\s*$)/m
  )
  return unless case_match

  arm_match = case_match[:body].match(
    /^[ \t]*#{Regexp.escape(package_test)}\)\s*$\n(?<body>.*?)(?=^[ \t]*;;\s*$)/m
  )
  arm_match && arm_match[:body]
end

def active_shell_commands(body)
  return [] unless body

  commands = []
  continued_command = +""
  body.each_line do |line|
    statement = line.strip
    next if statement.empty? || statement.start_with?("#")

    if statement.end_with?("\\")
      continued_command << statement.delete_suffix("\\").rstrip << " "
    else
      continued_command << statement
      commands << continued_command
      continued_command = +""
    end
  end
  commands << continued_command.rstrip unless continued_command.empty?
  commands
end

def shell_contract_command?(command, token)
  return true if command == token
  return true if token.start_with?("-D") &&
                 command.start_with?("reconfigure ") &&
                 command.split.include?(token)

  command == "if #{token}; then"
end

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github", "workflows", "package-tests.yml")
results_path = File.join(root, "docs", "src", "package-test-results.md")
errors = []

package_test_contracts = {
  "utilmm" => {
    script_tokens: [
      "build_targets toolchain/tools/utilmm/build utilmm_testsuite",
      "run_ctest toolchain/tools/utilmm/build '^Suite$'"
    ],
    result_tokens: ["`Suite`"]
  },
  "typelib-cxx" => {
    script_tokens: [
      "build_targets toolchain/tools/typelib/build typelib_testsuite",
      "run_ctest toolchain/tools/typelib/build '^(CxxSuiteInstalledPlugins|CxxSuiteLocalPlugins)$'"
    ],
    result_tokens: ["`CxxSuiteInstalledPlugins`", "`CxxSuiteLocalPlugins`"]
  },
  "rtt-typelib" => {
    script_tokens: [
      "-DBUILD_TESTING=ON",
      "build_targets toolchain/tools/rtt_typelib/build rtt-typelib get_marshaller_for_test",
      "run_ctest toolchain/tools/rtt_typelib/build '^get_marshaller_for_test$'",
      'pkg-config --exists "rtt_typelib-$TARGET"'
    ],
    result_tokens: ["`rtt-typelib`", "`get_marshaller_for_test`", "`rtt_typelib-gnulinux`"]
  },
  "rtt-core" => {
    script_tokens: [
      "-DENABLE_MQ=ON",
      "-DENABLE_CORBA=OFF",
      "build_targets toolchain/tools/rtt/build main-test list-test core-test task-test mqueue-test mqueue_archive_test",
      "run_ctest toolchain/tools/rtt/build '^(main-test|list-test|core-test|task-test|mqueue-test|mqueue_archive_test)$'"
    ],
    result_tokens: [
      "`main-test`", "`list-test`", "`core-test`", "`task-test`",
      "`mqueue-test`", "`mqueue_archive_test`"
    ]
  },
  "rtt-opcua" => {
    script_tokens: [
      "-DRTT_OPCUA_WARNINGS_AS_ERRORS=ON",
      'build_targets toolchain/tools/rtt_opcua/build "${RTT_OPCUA_TEST_TARGETS[@]}"',
      "run_ctest toolchain/tools/rtt_opcua/build '^rtt_opcua_.*_test$'",
      "build_targets toolchain/tools/ocl/build ocl_opcua_deployment_test deployer-opcua ctaskbrowser-opcua",
      "run_ctest toolchain/tools/ocl/build '^ocl_opcua_deployment_.*$'",
      'pkg-config --exists "rtt_opcua-$TARGET"',
      'pkg-config --exists "ocl-deployment-$TARGET"'
    ],
    result_tokens: ["`rtt_opcua_*_test`", "`ocl_opcua_deployment_*`", "`rtt_opcua-gnulinux`"]
  },
  "ocl-basic" => {
    script_tokens: [
      "-DBUILD_TIMER_TEST=ON",
      "-DBUILD_TASKBROWSER_TEST=ON",
      "build_targets toolchain/tools/ocl/build timer taskb",
      "run_ctest toolchain/tools/ocl/build '^(timer|taskb)$'"
    ],
    result_tokens: ["`timer`", "`taskb`"]
  },
  "ocl-integration" => {
    script_tokens: [
      "-DBUILD_TIMER_TEST=OFF",
      "-DBUILD_TASKBROWSER_TEST=OFF",
      "-DBUILD_DEPLOYMENT_TEST=ON",
      "-DBUILD_LOGGING_TEST=ON",
      "-DBUILD_REPORTING_TEST=ON",
      "OCL_INTEGRATION_TARGETS=(deploy testlogging report tcpreport)",
      "cmake_target_exists toolchain/tools/ocl/build ncreport",
      "OCL_INTEGRATION_TARGETS+=(ncreport)",
      'build_targets toolchain/tools/ocl/build "${OCL_INTEGRATION_TARGETS[@]}"',
      'run_ctest toolchain/tools/ocl/build "$OCL_INTEGRATION_TEST_REGEX"'
    ],
    result_tokens: ["`deploy`", "`testlogging`", "`report`", "`tcpreport`", "`ncreport`", "optional"]
  }
}.freeze

if !File.file?(workflow_path)
  errors << "missing .github/workflows/package-tests.yml"
else
  contents = File.read(workflow_path)

  errors << "package tests must run on pull requests" unless contents.include?("pull_request:")
  errors << "package tests must support manual dispatch" unless contents.include?("workflow_dispatch:")
  errors << "package tests must not run for docs-only changes" if contents.match?(/docs\//)
  errors << "package tests must define an OS matrix" unless contents.include?("matrix:") && contents.include?("os:")
  {
    "Ubuntu 22.04" => "ubuntu:22.04",
    "Ubuntu 24.04" => "ubuntu:24.04",
    "Debian 13" => "debian:trixie"
  }.each do |name, image|
    errors << "package tests must cover #{name}" unless contents.include?("name: #{name}") && contents.include?("image: #{image}")
  end
  errors << "package tests must use matrix-selected containers" unless contents.include?("image: ${{ matrix.os.image }}")
  errors << "package tests must use a fresh /tmp/orocos install prefix" unless contents.include?("OROCOS_PREFIX: /tmp/orocos")
  unless contents.include?("LANG: C.UTF-8") && contents.include?("LC_ALL: C.UTF-8")
    errors << "package tests must use a UTF-8 locale for Autoproj and dpkg metadata"
  end
  errors << "package tests must not use the clean-room Docker /opt/orocos install prefix" if contents.include?("OROCOS_PREFIX: /opt/orocos")
  errors << "package tests must not install omniORB for no-CORBA builds" if contents.include?("libomniorb4-dev") || contents.include?("omniidl")
  errors << "package tests must be non-required while experimental" unless contents.include?("continue-on-error: true")
  errors << "package tests must define a package-test matrix" unless contents.include?("package-test:")
  package_test_contracts.each_key do |package_test|
    errors << "package tests must include #{package_test}" unless contents.include?("- #{package_test}")
  end
  errors << "package tests must run the shared package test wrapper" unless contents.include?("./tools/test-package.sh")
  errors << "package tests must pass the default gnulinux target explicitly" unless contents.include?('./tools/test-package.sh --prefix "$OROCOS_PREFIX" --target gnulinux')
  errors << "package tests must return package test failures" if contents.include?("::warning::") || contents.include?("exit 0")
  errors << "package tests must upload diagnostic logs when package tests fail" unless contents.include?("actions/upload-artifact@v6") && contents.include?("if: failure()")
  errors << "package tests must upload CTest logs" unless contents.include?("Testing/Temporary/*.log")
  errors << "package tests must upload CMake logs" unless contents.include?("CMakeOutput.log") && contents.include?("CMakeError.log")
  errors << "package tests must upload Autoproj package logs" unless contents.include?("toolchain/log/*.log")
  errors << "package tests must upload osdeps suffix files" unless contents.include?(".autoproj/remotes/**/*.osdeps*") && contents.include?("autoproj/**/*.osdeps*")
end

test_package_path = File.join(root, "tools", "test-package.sh")
if !File.file?(test_package_path)
  errors << "missing tools/test-package.sh"
else
  test_package = File.read(test_package_path)
  errors << "OCL integration CI subset must not run interactive state-machine browser test" if test_package.include?("testWithStateMachine")
  package_test_contracts.each do |package_test, contract|
    case_arm = package_test_case_arm(test_package, package_test)
    unless case_arm
      errors << "tools/test-package.sh: must define the #{package_test} case arm"
      next
    end

    case_commands = active_shell_commands(case_arm)
    contract.fetch(:script_tokens).each do |token|
      unless case_commands.any? { |command| shell_contract_command?(command, token) }
        errors << "tools/test-package.sh: #{package_test} must include #{token}"
      end
    end
  end
end

custom_datatype_path = File.join(root, "tools", "test-opcua-custom-datatypes.sh")
if !File.file?(custom_datatype_path)
  errors << "missing tools/test-opcua-custom-datatypes.sh"
else
  custom_datatype_test = File.read(custom_datatype_path)
  [
    "-DENABLE_MQ=ON",
    "-DENABLE_CORBA=OFF",
    "mqueue-test mqueue_archive_test",
    "mqueue-test|mqueue_archive_test",
    'librtt-transport-mqueue-$TARGET.so'
  ].each do |fragment|
    unless custom_datatype_test.include?(fragment)
      errors << "custom datatype verification must include #{fragment}"
    end
  end
  unless custom_datatype_test.include?('MQUEUE_TRANSPORT="$PREFIX/lib/orocos/$TARGET/types/librtt-transport-mqueue-$TARGET.so"') &&
         custom_datatype_test.include?('orocos_rock_require_file "$MQUEUE_TRANSPORT"')
    errors << "custom datatype verification must require the installed target-specific mqueue transport"
  end
  if custom_datatype_test.include?("-DENABLE_MQ=OFF")
    errors << "custom datatype verification must not disable the mqueue transport"
  end
  ["UA_BUILD_UNIT_TESTS=ON", "UAPP_BUILD_TESTS=ON"].each do |setting|
    if custom_datatype_test.include?(setting)
      errors << "custom datatype verification must not configure #{setting}"
    end
  end
  unless custom_datatype_test.include?('LOGIN_HOME_ROOT="$(getent passwd "$(id -u)" | cut -d: -f6)"') &&
         custom_datatype_test.include?('LOGIN_HOME_OROCOS')
    errors << "custom datatype verification must scan the login home even when HOME is isolated"
  end
end

if !File.file?(results_path)
  errors << "missing docs/src/package-test-results.md"
else
  results = File.read(results_path)
  errors << "package test results must define the package verification matrix" unless results.include?("# Package Verification Matrix")
  errors << "package test results must not refer to the old MetaNC branch" if results.include?("MetaNC")
  errors << "package test results must identify tracked source selections" unless results.include?("`autoproj/overrides.yml`")
  package_test_contracts.each do |package_test, contract|
    errors << "package test results must document #{package_test}" unless results.include?("| `#{package_test}` |")
    contract.fetch(:result_tokens).each do |token|
      errors << "package test results: #{package_test} must mention #{token}" unless results.include?(token)
    end
  end
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
