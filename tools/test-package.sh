#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./tools/test-package.sh [--prefix PREFIX] PACKAGE_TEST

Reconfigure an installed Autoproj package build tree with tests enabled and
run the first experimental package CTest subsets.

Package tests:
  utilmm       Build utilmm_testsuite and run CTest Suite
  log4cpp     Build and run log4cpp CTest cases
  typelib-cxx Build typelib_testsuite and run C++ CTest cases only
  rtt-core    Build and run stable RTT core CTest cases
  ocl-basic   Build and run OCL timer/taskbrowser CTest cases

Options:
  --prefix PREFIX  Installed toolchain prefix. Default: $OROCOS_ROCK_PREFIX or ~/.orocos
  -h, --help       Show this help
USAGE
}

PREFIX="$OROCOS_ROCK_DEFAULT_PREFIX"
PACKAGE_TEST=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || orocos_rock_die "--prefix requires a value"
            PREFIX="$2"
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
    log4cpp)
        LOG4CPP_TESTS=(
            testCategory
            testFixedContextCategory
            testNDC
            testPattern
            testErrorCollision
            testPriority
            testFilter
            testProperties
            testConfig
            testPropertyConfig
            testRollingFileAppender
            testDailyRollingFileAppender
        )
        orocos_rock_info "Configuring log4cpp tests"
        reconfigure toolchain/tools/log4cpp toolchain/tools/log4cpp/build -DBUILD_TESTING=ON
        orocos_rock_info "Building log4cpp tests"
        build_targets toolchain/tools/log4cpp/build "${LOG4CPP_TESTS[@]}"
        orocos_rock_info "Running log4cpp CTest subset"
        run_ctest toolchain/tools/log4cpp/build/tests "^($(IFS='|'; echo "${LOG4CPP_TESTS[*]}"))$"
        ;;
    typelib-cxx)
        orocos_rock_info "Configuring Typelib C++ tests"
        reconfigure toolchain/tools/typelib toolchain/tools/typelib/build -DBUILD_TESTS=ON
        orocos_rock_info "Building Typelib C++ tests"
        build_targets toolchain/tools/typelib/build typelib_testsuite
        orocos_rock_info "Running Typelib C++ CTest subset"
        run_ctest toolchain/tools/typelib/build '^(CxxSuiteInstalledPlugins|CxxSuiteLocalPlugins)$'
        ;;
    rtt-core)
        orocos_rock_info "Configuring RTT core tests"
        reconfigure toolchain/tools/rtt toolchain/tools/rtt/build -DENABLE_TESTS=ON -DBUILD_TESTING=ON
        orocos_rock_info "Building RTT core tests"
        build_targets toolchain/tools/rtt/build main-test list-test core-test
        orocos_rock_info "Running RTT core CTest subset"
        run_ctest toolchain/tools/rtt/build '^(main-test|list-test|core-test)$'
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
    *)
        usage >&2
        orocos_rock_die "unknown PACKAGE_TEST: $PACKAGE_TEST"
        ;;
esac
