#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./tools/test-package.sh [--prefix PREFIX] [--target gnulinux|xenomai] PACKAGE_TEST

Reconfigure an installed Autoproj package build tree with tests enabled and
run the first experimental package CTest subsets.

Package tests:
  utilmm       Build utilmm_testsuite and run CTest Suite
  typelib-cxx Build typelib_testsuite and run C++ CTest cases only
  rtt-typelib Build rtt_typelib transport plugin and check pkg-config metadata
  rtt-core    Build and run stable RTT core/task CTest cases
  rtt-opcua   Build and run the native RTT/OCL OPC UA integration tests
  opcua-custom-datatypes
              Rebuild the OPC UA stack and run the installed external fixture
  ocl-basic   Build and run OCL timer/taskbrowser CTest cases
  ocl-integration
               Build and run stable OCL deployment/logging/reporting CTest cases

Options:
  --prefix PREFIX  Installed toolchain prefix. Default: $OROCOS_PREFIX or ~/.orocos
  --target TARGET  Orocos target for metadata checks. Default: $OROCOS_TARGET or gnulinux
  -h, --help       Show this help
USAGE
}

PREFIX="$OROCOS_ROCK_DEFAULT_PREFIX"
TARGET="$OROCOS_ROCK_DEFAULT_TARGET"
PACKAGE_TEST=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || orocos_rock_die "--prefix requires a value"
            PREFIX="$2"
            shift 2
            ;;
        --target)
            [ "$#" -ge 2 ] || orocos_rock_die "--target requires a value"
            TARGET="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            orocos_rock_die "unknown argument: $1"
            ;;
        *)
            [ -z "$PACKAGE_TEST" ] || orocos_rock_die "only one PACKAGE_TEST may be specified"
            PACKAGE_TEST="$1"
            shift
            ;;
    esac
done

[ -n "$PACKAGE_TEST" ] || {
    usage >&2
    orocos_rock_die "missing PACKAGE_TEST"
}
orocos_rock_validate_target "$TARGET"

BUILD_PARALLEL="${JOBS:-2}"
PACKAGE_TEST_TIMEOUT="${PACKAGE_TEST_TIMEOUT:-120}"

source_installed_env() {
    if [ -f "$PREFIX/dev-env.sh" ]; then
        # shellcheck disable=SC1090
        . "$PREFIX/dev-env.sh"
    elif [ -f "$PREFIX/env.sh" ]; then
        # shellcheck disable=SC1090
        . "$PREFIX/env.sh"
    else
        orocos_rock_die "installed environment is missing under $PREFIX; run ./tools/install.sh --prefix $PREFIX first"
    fi
    export OROCOS_TARGET="$TARGET"
}

reconfigure() {
    source_dir="$1"
    build_dir="$2"
    shift 2

    cmake -S "$source_dir" -B "$build_dir" "$@"
}

build_targets() {
    build_dir="$1"
    shift

    cmake --build "$build_dir" --parallel "$BUILD_PARALLEL" --target "$@"
}

run_ctest() {
    build_dir="$1"
    regex="$2"

    (
        cd "$build_dir"
        ctest --output-on-failure --timeout "$PACKAGE_TEST_TIMEOUT" -R "$regex"
    )
}

cmake_target_exists() {
    build_dir="$1"
    target="$2"

    cmake --build "$build_dir" --target help 2>/dev/null |
        awk -v target="$target" '$NF == target { found = 1 } END { exit found ? 0 : 1 }'
}

if [ "$PACKAGE_TEST" = "opcua-custom-datatypes" ]; then
    [ -n "${OROCOS_ROCK_OPCUA_DEPENDENCY_PREFIX:-}" ] || \
        orocos_rock_die "set OROCOS_ROCK_OPCUA_DEPENDENCY_PREFIX to the temporary prerequisite prefix"
    exec "$SCRIPT_DIR/test-opcua-custom-datatypes.sh" \
        --prefix "$PREFIX" \
        --dependency-prefix "$OROCOS_ROCK_OPCUA_DEPENDENCY_PREFIX" \
        --target "$TARGET"
fi

source_installed_env
cd "$OROCOS_ROCK_ROOT"

case "$PACKAGE_TEST" in
    utilmm)
        orocos_rock_info "Configuring utilmm tests"
        reconfigure toolchain/tools/utilmm toolchain/tools/utilmm/build -DENABLE_TESTS=ON
        orocos_rock_info "Building utilmm tests"
        build_targets toolchain/tools/utilmm/build utilmm_testsuite
        orocos_rock_info "Running utilmm CTest subset"
        run_ctest toolchain/tools/utilmm/build '^Suite$'
        ;;
    typelib-cxx)
        orocos_rock_info "Configuring Typelib C++ tests"
        reconfigure toolchain/tools/typelib toolchain/tools/typelib/build -DBUILD_TESTS=ON
        orocos_rock_info "Building Typelib C++ tests"
        build_targets toolchain/tools/typelib/build typelib_testsuite
        orocos_rock_info "Running Typelib C++ CTest subset"
        run_ctest toolchain/tools/typelib/build '^(CxxSuiteInstalledPlugins|CxxSuiteLocalPlugins)$'
        ;;
    rtt-typelib)
        orocos_rock_info "Configuring rtt_typelib"
        reconfigure toolchain/tools/rtt_typelib toolchain/tools/rtt_typelib/build -DBUILD_TESTING=ON
        orocos_rock_info "Building rtt_typelib transport plugin"
        build_targets toolchain/tools/rtt_typelib/build rtt-typelib get_marshaller_for_test
        orocos_rock_info "Running rtt_typelib CTest subset"
        run_ctest toolchain/tools/rtt_typelib/build '^get_marshaller_for_test$'
        orocos_rock_info "Checking rtt_typelib pkg-config metadata"
        pkg-config --exists "rtt_typelib-$TARGET"
        ;;
    rtt-core)
        orocos_rock_info "Configuring RTT core tests"
        reconfigure toolchain/tools/rtt toolchain/tools/rtt/build \
            -DENABLE_TESTS=ON \
            -DBUILD_TESTING=ON \
            -DENABLE_MQ=ON \
            -DENABLE_CORBA=OFF
        orocos_rock_info "Building RTT core tests"
        build_targets toolchain/tools/rtt/build main-test list-test core-test task-test mqueue-test mqueue_archive_test
        orocos_rock_info "Running RTT core CTest subset"
        run_ctest toolchain/tools/rtt/build '^(main-test|list-test|core-test|task-test|mqueue-test|mqueue_archive_test)$'
        ;;
    rtt-opcua)
        orocos_rock_info "Configuring native RTT OPC UA tests"
        reconfigure toolchain/tools/rtt_opcua toolchain/tools/rtt_opcua/build \
            -DBUILD_TESTING=ON \
            -DRTT_OPCUA_WARNINGS_AS_ERRORS=ON
        RTT_OPCUA_TEST_TARGETS=(
            rtt_opcua_foundation_test
            rtt_opcua_server_test
            rtt_opcua_type_protocol_test
            rtt_opcua_object_model_test
            rtt_opcua_task_context_proxy_test
            rtt_opcua_publication_selector_test
        )
        orocos_rock_info "Building native RTT OPC UA tests"
        build_targets toolchain/tools/rtt_opcua/build "${RTT_OPCUA_TEST_TARGETS[@]}"
        orocos_rock_info "Running native RTT OPC UA CTest suite"
        run_ctest toolchain/tools/rtt_opcua/build '^rtt_opcua_.*_test$'

        orocos_rock_info "Configuring OCL OPC UA integration test"
        reconfigure toolchain/tools/ocl toolchain/tools/ocl/build \
            -DBUILD_TESTING=ON \
            -DBUILD_TESTS=ON \
            -DBUILD_DEPLOYMENT=ON \
            -DBUILD_TASKBROWSER=ON \
            -DBUILD_OPCUA=ON
        orocos_rock_info "Building OCL OPC UA integration targets"
        build_targets toolchain/tools/ocl/build ocl_opcua_deployment_test deployer-opcua ctaskbrowser-opcua
        orocos_rock_info "Running OCL OPC UA integration tests"
        run_ctest toolchain/tools/ocl/build '^ocl_opcua_deployment_.*$'

        orocos_rock_info "Checking installed OPC UA pkg-config metadata"
        pkg-config --exists "rtt_opcua-$TARGET"
        pkg-config --exists "ocl-deployment-$TARGET"
        ;;
    ocl-basic)
        orocos_rock_info "Configuring OCL basic tests"
        reconfigure toolchain/tools/ocl toolchain/tools/ocl/build \
            -DBUILD_TESTS=ON \
            -DBUILD_TIMER_TEST=ON \
            -DBUILD_TASKBROWSER_TEST=ON \
            -DBUILD_DEPLOYMENT_TEST=OFF \
            -DBUILD_LOGGING_TEST=OFF \
            -DBUILD_REPORTING_TEST=OFF
        orocos_rock_info "Building OCL basic tests"
        build_targets toolchain/tools/ocl/build timer taskb
        orocos_rock_info "Running OCL basic CTest subset"
        run_ctest toolchain/tools/ocl/build '^(timer|taskb)$'
        ;;
    ocl-integration)
        orocos_rock_info "Configuring OCL integration tests"
        reconfigure toolchain/tools/ocl toolchain/tools/ocl/build \
            -DBUILD_TESTS=ON \
            -DBUILD_TIMER_TEST=OFF \
            -DBUILD_TASKBROWSER_TEST=OFF \
            -DBUILD_DEPLOYMENT_TEST=ON \
            -DBUILD_LOGGING_TEST=ON \
            -DBUILD_REPORTING_TEST=ON
        OCL_INTEGRATION_TARGETS=(deploy testlogging report tcpreport)
        OCL_INTEGRATION_TEST_REGEX='^(deploy|testlogging|report|tcpreport)$'
        if cmake_target_exists toolchain/tools/ocl/build ncreport; then
            OCL_INTEGRATION_TARGETS+=(ncreport)
            OCL_INTEGRATION_TEST_REGEX='^(deploy|testlogging|report|tcpreport|ncreport)$'
        else
            orocos_rock_info "Skipping optional ncreport test target because NetCDF support is unavailable"
        fi
        orocos_rock_info "Building OCL integration tests"
        build_targets toolchain/tools/ocl/build "${OCL_INTEGRATION_TARGETS[@]}"
        orocos_rock_info "Running OCL integration CTest subset"
        run_ctest toolchain/tools/ocl/build "$OCL_INTEGRATION_TEST_REGEX"
        ;;
    *)
        usage >&2
        orocos_rock_die "unknown PACKAGE_TEST: $PACKAGE_TEST"
        ;;
esac
