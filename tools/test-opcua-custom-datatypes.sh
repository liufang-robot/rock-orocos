#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./tools/test-opcua-custom-datatypes.sh --prefix PREFIX --dependency-prefix PREFIX [--target TARGET]

Build and install RTT, rtt_opcua, OCL, and an external custom-datatype fixture
into an isolated temporary prefix. Verify both the standalone server and the
explicit-start deployer lifecycle with separate client processes.

Options:
  --prefix PREFIX
      Required empty install prefix below /tmp.
  --dependency-prefix PREFIX
      Temporary prefix below /tmp containing farbot, rtlog-cpp, open62541, and
      open62541pp.
  --target gnulinux|xenomai
      Orocos target. Default: gnulinux.
  -h, --help
      Show this help.
USAGE
}

PREFIX=""
DEPENDENCY_PREFIX="${OROCOS_ROCK_OPCUA_DEPENDENCY_PREFIX:-}"
TARGET="gnulinux"
BUILD_PARALLEL="${JOBS:-2}"
TEST_TIMEOUT="${OPCUA_CUSTOM_DATATYPE_TEST_TIMEOUT:-180}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || orocos_rock_die "--prefix requires a value"
            PREFIX="$2"
            shift 2
            ;;
        --dependency-prefix)
            [ "$#" -ge 2 ] || orocos_rock_die "--dependency-prefix requires a value"
            DEPENDENCY_PREFIX="$2"
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
        *)
            usage >&2
            orocos_rock_die "unknown argument: $1"
            ;;
    esac
done

[ -n "$PREFIX" ] || orocos_rock_die "--prefix is required"
[ -n "$DEPENDENCY_PREFIX" ] || \
    orocos_rock_die "--dependency-prefix is required"
orocos_rock_validate_target "$TARGET"
orocos_rock_require_command ip
orocos_rock_require_command ss

PREFIX="$(realpath -m -- "$PREFIX")"
DEPENDENCY_PREFIX="$(realpath -m -- "$DEPENDENCY_PREFIX")"
CALLER_HOME_ROOT="$(cd "$HOME" && pwd -P)"
LOGIN_HOME_ROOT="$(getent passwd "$(id -u)" | cut -d: -f6)"
[ -n "$LOGIN_HOME_ROOT" ] || \
    orocos_rock_die "unable to resolve the login home directory"
LOGIN_HOME_ROOT="$(cd "$LOGIN_HOME_ROOT" && pwd -P)"
CALLER_HOME_OROCOS="$CALLER_HOME_ROOT/.orocos"
CALLER_HOME_OROCOS_REAL="$(realpath -m -- "$CALLER_HOME_OROCOS")"
LOGIN_HOME_OROCOS="$LOGIN_HOME_ROOT/.orocos"
LOGIN_HOME_OROCOS_REAL="$(realpath -m -- "$LOGIN_HOME_OROCOS")"

case "$PREFIX" in
    /tmp/*) ;;
    *) orocos_rock_die "test prefix must be below /tmp: $PREFIX" ;;
esac
case "$DEPENDENCY_PREFIX" in
    /tmp/*) ;;
    *) orocos_rock_die \
        "dependency prefix must be below /tmp: $DEPENDENCY_PREFIX" ;;
esac
case "$PREFIX/" in
    "$CALLER_HOME_OROCOS/"*|"$CALLER_HOME_OROCOS_REAL/"*|\
    "$LOGIN_HOME_OROCOS/"*|"$LOGIN_HOME_OROCOS_REAL/"*)
        orocos_rock_die "refusing home Orocos prefix: $PREFIX"
        ;;
esac
case "$DEPENDENCY_PREFIX/" in
    "$CALLER_HOME_OROCOS/"*|"$CALLER_HOME_OROCOS_REAL/"*|\
    "$LOGIN_HOME_OROCOS/"*|"$LOGIN_HOME_OROCOS_REAL/"*)
        orocos_rock_die "refusing home Orocos dependency prefix: $DEPENDENCY_PREFIX"
        ;;
esac

if [ -e "$PREFIX" ] && [ ! -d "$PREFIX" ]; then
    orocos_rock_die "test prefix is not a directory: $PREFIX"
fi
mkdir -p "$PREFIX"
if find "$PREFIX" -mindepth 1 -print -quit | grep -q .; then
    orocos_rock_die "test prefix must be empty: $PREFIX"
fi

for required in \
    "$OROCOS_ROCK_ROOT/toolchain/tools/rtt/CMakeLists.txt" \
    "$OROCOS_ROCK_ROOT/toolchain/tools/rtt_opcua/CMakeLists.txt" \
    "$OROCOS_ROCK_ROOT/toolchain/tools/ocl/CMakeLists.txt" \
    "$OROCOS_ROCK_ROOT/tests/opcua-custom-datatypes/CMakeLists.txt" \
    "$DEPENDENCY_PREFIX/lib/cmake/farbot/farbotConfig.cmake" \
    "$DEPENDENCY_PREFIX/lib/cmake/rtlog/rtlogConfig.cmake" \
    "$DEPENDENCY_PREFIX/lib/cmake/open62541/open62541Config.cmake" \
    "$DEPENDENCY_PREFIX/lib/cmake/open62541pp/open62541ppConfig.cmake"
do
    orocos_rock_require_file "$required"
done

TEST_ROOT="${PREFIX}-work"
if [ -e "$TEST_ROOT" ]; then
    orocos_rock_die "test work directory already exists: $TEST_ROOT"
fi
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"

unset OROCOS_PREFIX OROCOS_TARGET LD_LIBRARY_PATH RTT_COMPONENT_PATH
unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH RUBYLIB
export HOME="$TEST_HOME"
export OROCOS_TARGET="$TARGET"

LIBRARY_PATHS=(
    "$PREFIX/lib"
    "$PREFIX/lib/orocos/$TARGET"
    "$PREFIX/lib/orocos/$TARGET/plugins"
    "$PREFIX/lib/orocos/$TARGET/types"
    "$PREFIX/lib/orocos/$TARGET/rtt_opcua"
    "$PREFIX/lib/orocos/$TARGET/rtt_opcua/plugins"
    "$PREFIX/lib/orocos/$TARGET/rtt_opcua/types"
    "$PREFIX/lib/orocos/$TARGET/ocl"
    "$PREFIX/lib/orocos/$TARGET/ocl/plugins"
    "$PREFIX/lib/orocos/$TARGET/ocl/types"
    "$DEPENDENCY_PREFIX/lib"
)
LD_LIBRARY_PATH="$(IFS=:; printf '%s' "${LIBRARY_PATHS[*]}")"
export LD_LIBRARY_PATH
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$DEPENDENCY_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH

HOME_IGNORE="$CALLER_HOME_OROCOS;$CALLER_HOME_OROCOS/toolchain"
HOME_IGNORE+=";$CALLER_HOME_OROCOS_REAL;$CALLER_HOME_OROCOS_REAL/toolchain"
HOME_IGNORE+=";$LOGIN_HOME_OROCOS;$LOGIN_HOME_OROCOS/toolchain"
HOME_IGNORE+=";$LOGIN_HOME_OROCOS_REAL;$LOGIN_HOME_OROCOS_REAL/toolchain"
COMMON_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF
    -DCMAKE_IGNORE_PREFIX_PATH="$HOME_IGNORE"
)

configure_build_install() {
    name="$1"
    source_dir="$2"
    prefix_path="$3"
    shift 3
    build_dir="$TEST_ROOT/$name-build"

    orocos_rock_info "Configuring $name"
    cmake -S "$source_dir" -B "$build_dir" \
        "${COMMON_CMAKE_ARGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$prefix_path" \
        "$@"
    orocos_rock_info "Building $name"
    cmake --build "$build_dir" --parallel "$BUILD_PARALLEL"
    orocos_rock_info "Installing $name into $PREFIX"
    cmake --install "$build_dir"
}

configure_build_install \
    rtt "$OROCOS_ROCK_ROOT/toolchain/tools/rtt" "$DEPENDENCY_PREFIX" \
    -DOROCOS_TARGET="$TARGET" \
    -DENABLE_CORBA=OFF \
    -DENABLE_MQ=ON \
    -DENABLE_TESTS=ON \
    -DBUILD_TESTING=ON

if [ "$TARGET" = xenomai ]; then
    cmake --build "$TEST_ROOT/rtt-build" --parallel "$BUILD_PARALLEL" \
        --target typekit_test type_discovery_struct_test \
        type_discovery_container_test mqueue-test mqueue_archive_test
    ctest --test-dir "$TEST_ROOT/rtt-build" --output-on-failure \
        --timeout "$TEST_TIMEOUT" \
        -R '^(typekit_test|type_discovery_struct_test|type_discovery_container_test|mqueue-test|mqueue_archive_test)$'
else
    cmake --build "$TEST_ROOT/rtt-build" --parallel "$BUILD_PARALLEL" \
        --target typekit_test scripting_test \
        type_discovery_struct_test type_discovery_container_test \
        mqueue-test mqueue_archive_test
    ctest --test-dir "$TEST_ROOT/rtt-build" --output-on-failure \
        --timeout "$TEST_TIMEOUT" \
        -R '^(typekit_test|scripting_test|type_discovery_struct_test|type_discovery_container_test|mqueue-test|mqueue_archive_test)$'
fi

INSTALLED_PREFIX_PATH="$PREFIX;$DEPENDENCY_PREFIX"
configure_build_install \
    rtt-opcua "$OROCOS_ROCK_ROOT/toolchain/tools/rtt_opcua" \
    "$INSTALLED_PREFIX_PATH" \
    -DBUILD_TESTING=ON \
    -DRTT_OPCUA_WARNINGS_AS_ERRORS=ON
if [ "$TARGET" = xenomai ]; then
    ctest --test-dir "$TEST_ROOT/rtt-opcua-build" --output-on-failure \
        --timeout "$TEST_TIMEOUT" \
        -R '^(rtt_opcua_foundation_test|rtt_opcua_server_test)$'
else
    ctest --test-dir "$TEST_ROOT/rtt-opcua-build" --output-on-failure \
        --timeout "$TEST_TIMEOUT"
fi

configure_build_install \
    ocl "$OROCOS_ROCK_ROOT/toolchain/tools/ocl" \
    "$INSTALLED_PREFIX_PATH" \
    -DBUILD_TESTING=ON \
    -DBUILD_TESTS=ON \
    -DBUILD_DEPLOYMENT=ON \
    -DBUILD_TASKBROWSER=ON \
    -DBUILD_OPCUA=ON
if [ "$TARGET" = xenomai ]; then
    cmake --build "$TEST_ROOT/ocl-build" --parallel "$BUILD_PARALLEL" \
        --target ocl_opcua_deployment_test deployer deployer-opcua ctaskbrowser-opcua
    ctest --test-dir "$TEST_ROOT/ocl-build" --output-on-failure \
        --timeout "$TEST_TIMEOUT" \
        -R '^(deployer_opcua_cli_address_rejected|ocl_opcua_deployment_.*|ctaskbrowser_opcua_.*)$'
else
    cmake --build "$TEST_ROOT/ocl-build" --parallel "$BUILD_PARALLEL" \
        --target taskbrowser_value_renderer_test \
        ocl_opcua_deployment_test deployer deployer-opcua ctaskbrowser-opcua
    ctest --test-dir "$TEST_ROOT/ocl-build" --output-on-failure \
        --timeout "$TEST_TIMEOUT" \
        -R '^(taskbrowser_value_renderer_test|ocl_opcua_deployment_.*|ctaskbrowser_opcua_.*)$'
fi

FIXTURE_CMAKE_ARGS=()
if [ "$TARGET" = xenomai ]; then
    FIXTURE_SYSTEM_INCLUDES="-isystem $PREFIX/include/orocos"
    FIXTURE_SYSTEM_INCLUDES+=" -isystem /usr/xenomai/include/trank"
    FIXTURE_SYSTEM_INCLUDES+=" -isystem /usr/xenomai/include/cobalt"
    FIXTURE_SYSTEM_INCLUDES+=" -isystem /usr/xenomai/include"
    FIXTURE_SYSTEM_INCLUDES+=" -isystem /usr/xenomai/include/alchemy"
    FIXTURE_SYSTEM_INCLUDES+=" -isystem $DEPENDENCY_PREFIX/include"
    FIXTURE_CMAKE_ARGS+=("-DCMAKE_CXX_FLAGS=$FIXTURE_SYSTEM_INCLUDES")
fi
configure_build_install \
    fixture "$OROCOS_ROCK_ROOT/tests/opcua-custom-datatypes" \
    "$INSTALLED_PREFIX_PATH" "${FIXTURE_CMAKE_ARGS[@]}"

pkg-config --exists "orocos-rtt-$TARGET"
pkg-config --exists "rtt_opcua-$TARGET"
pkg-config --exists "orocos_opcua_fixture-$TARGET"

TYPEKIT="$PREFIX/lib/orocos/$TARGET/orocos_opcua_fixture/types/libfixture-types-$TARGET.so"
TRANSPORT="$PREFIX/lib/orocos/$TARGET/orocos_opcua_fixture/plugins/libfixture-opcua-transport-$TARGET.so"
COMPONENT="$PREFIX/lib/orocos/$TARGET/orocos_opcua_fixture/libfixture-components-$TARGET.so"
MQUEUE_TRANSPORT="$PREFIX/lib/orocos/$TARGET/types/librtt-transport-mqueue-$TARGET.so"
SERVER="$PREFIX/bin/fixture-server"
CLIENT="$PREFIX/bin/fixture-client"
DEPLOYER="$PREFIX/bin/deployer-opcua"
DEPLOYER_BINARY="$PREFIX/bin/deployer-opcua-$TARGET"
SERVICE_DEPLOYER="$PREFIX/bin/deployer-$TARGET"
SERVICE_PLUGIN="$PREFIX/lib/orocos/$TARGET/ocl/plugins/libopcua-$TARGET.so"
TASKBROWSER="$PREFIX/bin/ctaskbrowser-opcua"
TASKBROWSER_BINARY="$PREFIX/bin/ctaskbrowser-opcua-$TARGET"
TASKBROWSER_ACCEPTANCE="$OROCOS_ROCK_ROOT/tests/opcua-custom-datatypes/ctaskbrowser_acceptance.rb"
NO_START_SCRIPT="$PREFIX/share/orocos-opcua-fixture/deployer-no-start.ops"
ENDPOINT_ONLY_SCRIPT="$PREFIX/share/orocos-opcua-fixture/deployer-endpoint-only.ops"
START_SCRIPT="$PREFIX/share/orocos-opcua-fixture/deployer-start.ops"
SERVICE_LOAD_SCRIPT="$PREFIX/share/orocos-opcua-fixture/deployer-service-load.ops"
for artifact in \
    "$TYPEKIT" "$TRANSPORT" "$COMPONENT" "$SERVER" "$CLIENT" \
    "$DEPLOYER" "$DEPLOYER_BINARY" "$TASKBROWSER" \
    "$SERVICE_DEPLOYER" "$SERVICE_PLUGIN" "$SERVICE_LOAD_SCRIPT" \
    "$TASKBROWSER_BINARY" "$TASKBROWSER_ACCEPTANCE" \
    "$NO_START_SCRIPT" "$ENDPOINT_ONLY_SCRIPT" "$START_SCRIPT"
do
    orocos_rock_require_file "$artifact"
done
orocos_rock_require_file "$MQUEUE_TRANSPORT"

OROCOS_PREFIX="$PREFIX"
RTT_COMPONENT_PATH="$PREFIX/lib/orocos/$TARGET:$PREFIX/lib/orocos/$TARGET/orocos_opcua_fixture:$PREFIX/lib/orocos/$TARGET/ocl"
export OROCOS_PREFIX RTT_COMPONENT_PATH

cd "$TEST_ROOT"

unused_port() {
    ruby -rsocket -e \
        'server = TCPServer.new("0.0.0.0", 0); puts server.addr[1]'
}

discover_lan_ipv4() {
    ip -4 -o addr show scope global | awk '
        $3 == "inet" {
            split($4, address, "/")
            if (address[1] !~ /^127\./) {
                print address[1]
                exit
            }
        }
    '
}

listening_socket() {
    ss -H -ltn "sport = :$1"
}

ipv4_wildcard_listener() {
    ss -H -4 -ltn "sport = :$1" | awk -v port="$1" '
        $4 == "0.0.0.0:" port || $4 == "*:" port { found = 1 }
        END { exit !found }
    '
}

LAN_IPV4="$(discover_lan_ipv4)"
if [ -z "$LAN_IPV4" ]; then
    orocos_rock_die \
        "IPv4 LAN acceptance requires a non-loopback global AF_INET address"
fi
orocos_rock_info "Using non-loopback IPv4 acceptance address $LAN_IPV4"

PORT="$(unused_port)"
READY_FILE="$TEST_ROOT/server.ready"
SERVER_LOG="$TEST_ROOT/server.log"
SERVER_PID=""
DEPLOYER_PID=""

cleanup_processes() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ -n "$DEPLOYER_PID" ] && kill -0 "$DEPLOYER_PID" 2>/dev/null; then
        kill -TERM "$DEPLOYER_PID" 2>/dev/null || true
        wait "$DEPLOYER_PID" 2>/dev/null || true
    fi
}
trap cleanup_processes EXIT INT TERM

orocos_rock_info "Starting external fixture server on wildcard IPv4 port $PORT"
"$SERVER" \
    --typekit "$TYPEKIT" \
    --transport "$TRANSPORT" \
    --port "$PORT" \
    --ready "$READY_FILE" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in $(seq 1 200); do
    if [ -s "$READY_FILE" ]; then
        ready=1
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
if [ "$ready" -ne 1 ]; then
    sed -n '1,240p' "$SERVER_LOG" >&2
    orocos_rock_die "fixture server did not become ready"
fi

READY_ENDPOINT="$(sed -n '1p' "$READY_FILE")"
EXPECTED_READY_ENDPOINT="opc.tcp://0.0.0.0:$PORT/rtt"
if [ "$READY_ENDPOINT" != "$EXPECTED_READY_ENDPOINT" ]; then
    orocos_rock_die \
        "fixture server reported unexpected endpoint: $READY_ENDPOINT"
fi
ENDPOINT="opc.tcp://$LAN_IPV4:$PORT/rtt"
orocos_rock_info "Running external fixture client against $ENDPOINT"
"$CLIENT" \
    --standalone \
    --component "fixture/component" \
    --typekit "$TYPEKIT" \
    --transport "$TRANSPORT" \
    --endpoint "$ENDPOINT"

if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID"
fi
if ! wait "$SERVER_PID"; then
    sed -n '1,240p' "$SERVER_LOG" >&2
    orocos_rock_die "fixture server failed during shutdown"
fi
SERVER_PID=""

NO_START_PORT="$(unused_port)"
NO_START_ENDPOINT="opc.tcp://$LAN_IPV4:$NO_START_PORT/rtt"
NO_START_LOG="$TEST_ROOT/deployer-no-start.log"
NO_START_CLIENT_LOG="$TEST_ROOT/deployer-no-start-client.log"
orocos_rock_info "Starting deployer without opcua.start() on port $NO_START_PORT"
"$DEPLOYER" \
    --opcua-port "$NO_START_PORT" \
    --opcua-endpoint-path /rtt \
    "$NO_START_SCRIPT" </dev/null >"$NO_START_LOG" 2>&1 &
DEPLOYER_PID="$!"

sleep 0.5
if ! kill -0 "$DEPLOYER_PID" 2>/dev/null; then
    sed -n '1,240p' "$NO_START_LOG" >&2
    orocos_rock_die "no-start deployer exited unexpectedly"
fi
if listening_socket "$NO_START_PORT" | grep -q .; then
    orocos_rock_die "OPC UA port opened before opcua.start()"
fi
if "$CLIENT" \
    --deployer \
    --probe-only \
    --component Deployer \
    --typekit "$TYPEKIT" \
    --transport "$TRANSPORT" \
    --endpoint "$NO_START_ENDPOINT" \
    >"$NO_START_CLIENT_LOG" 2>&1
then
    orocos_rock_die "client created a Deployer proxy before opcua.start()"
fi

kill -TERM "$DEPLOYER_PID"
if ! wait "$DEPLOYER_PID"; then
    sed -n '1,240p' "$NO_START_LOG" >&2
    orocos_rock_die "no-start deployer failed during shutdown"
fi
DEPLOYER_PID=""

ENDPOINT_ONLY_PORT="$(unused_port)"
while [ "$ENDPOINT_ONLY_PORT" = "$NO_START_PORT" ]; do
    ENDPOINT_ONLY_PORT="$(unused_port)"
done
ENDPOINT_ONLY_ENDPOINT="opc.tcp://$LAN_IPV4:$ENDPOINT_ONLY_PORT/rtt"
ENDPOINT_ONLY_LOG="$TEST_ROOT/deployer-endpoint-only.log"
ENDPOINT_ONLY_CLIENT_LOG="$TEST_ROOT/deployer-endpoint-only-client.log"
orocos_rock_info \
    "Starting endpoint-only deployer on port $ENDPOINT_ONLY_PORT"
"$DEPLOYER" \
    --opcua-port "$ENDPOINT_ONLY_PORT" \
    --opcua-endpoint-path /rtt \
    "$ENDPOINT_ONLY_SCRIPT" </dev/null >"$ENDPOINT_ONLY_LOG" 2>&1 &
DEPLOYER_PID="$!"

endpoint_only_ready=0
for _ in $(seq 1 60); do
    if ipv4_wildcard_listener "$ENDPOINT_ONLY_PORT"; then
        endpoint_only_ready=1
        break
    fi
    if ! kill -0 "$DEPLOYER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
if [ "$endpoint_only_ready" -ne 1 ]; then
    sed -n '1,240p' "$ENDPOINT_ONLY_LOG" >&2
    ss -H -ltn "sport = :$ENDPOINT_ONLY_PORT" >&2 || true
    orocos_rock_die "endpoint-only OPC UA listener did not become ready"
fi
ss -H -4 -ltn "sport = :$ENDPOINT_ONLY_PORT" \
    >"$TEST_ROOT/deployer-endpoint-only-listener.ss"

if ! "$CLIENT" \
    --deployer \
    --require-missing-deployer-root \
    --component Deployer \
    --typekit "$TYPEKIT" \
    --transport "$TRANSPORT" \
    --endpoint "$ENDPOINT_ONLY_ENDPOINT" \
    >"$ENDPOINT_ONLY_CLIENT_LOG" 2>&1
then
    sed -n '1,240p' "$ENDPOINT_ONLY_CLIENT_LOG" >&2
    orocos_rock_die \
        "client did not confirm the endpoint-only Deployer root is absent"
fi

kill -TERM "$DEPLOYER_PID"
if ! wait "$DEPLOYER_PID"; then
    sed -n '1,240p' "$ENDPOINT_ONLY_LOG" >&2
    orocos_rock_die "endpoint-only deployer failed during shutdown"
fi
DEPLOYER_PID=""

if listening_socket "$ENDPOINT_ONLY_PORT" | grep -q .; then
    listening_socket "$ENDPOINT_ONLY_PORT" >&2
    orocos_rock_die \
        "endpoint-only OPC UA port remained open after deployer shutdown"
fi

for deployment_style in service executable; do
    START_PORT="$(unused_port)"
    while [ "$START_PORT" = "$NO_START_PORT" ] || \
        [ "$START_PORT" = "$ENDPOINT_ONLY_PORT" ]
    do
        START_PORT="$(unused_port)"
    done
    if [ "$deployment_style" = service ]; then
        START_PORT=4840
        if listening_socket "$START_PORT" | grep -q .; then
            orocos_rock_die "service plugin acceptance requires unused default port 4840"
        fi
        deployment_command=("$SERVICE_DEPLOYER" "$SERVICE_LOAD_SCRIPT")
    else
        deployment_command=("$DEPLOYER" --opcua-port "$START_PORT" --opcua-endpoint-path /rtt)
    fi
    START_ENDPOINT="opc.tcp://$LAN_IPV4:$START_PORT/rtt"
    START_LOG="$TEST_ROOT/deployer-$deployment_style-start.log"
    PROBE_LOG="$TEST_ROOT/deployer-probe.log"
    orocos_rock_info "Starting OPC UA deployment ($deployment_style) on port $START_PORT"
    "${deployment_command[@]}" \
        "$START_SCRIPT" </dev/null >"$START_LOG" 2>&1 &
    DEPLOYER_PID="$!"

    deployer_ready=0
    for _ in $(seq 1 60); do
        if "$CLIENT" \
            --deployer \
            --probe-only \
            --component Deployer \
            --typekit "$TYPEKIT" \
            --transport "$TRANSPORT" \
            --endpoint "$START_ENDPOINT" \
            >"$PROBE_LOG" 2>&1
        then
            deployer_ready=1
            break
        fi
        if ! kill -0 "$DEPLOYER_PID" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done
    if [ "$deployer_ready" -ne 1 ]; then
        sed -n '1,240p' "$START_LOG" >&2
        sed -n '1,240p' "$PROBE_LOG" >&2
        orocos_rock_die "explicit OPC UA deployer did not become ready"
    fi

    if ! ipv4_wildcard_listener "$START_PORT"; then
        ss -H -ltn "sport = :$START_PORT" >&2 || true
        orocos_rock_die \
            "OPC UA listener is not wildcard IPv4 on 0.0.0.0:$START_PORT"
    fi
    ss -H -4 -ltn "sport = :$START_PORT" >"$TEST_ROOT/deployer-listener.ss"

    orocos_rock_info "Running installed deployer OPC UA acceptance client"
    "$CLIENT" \
        --deployer \
        --component sample \
        --typekit "$TYPEKIT" \
        --transport "$TRANSPORT" \
        --endpoint "$START_ENDPOINT"

    orocos_rock_info "Running installed ctaskbrowser-opcua custom datatype acceptance"
    ruby "$TASKBROWSER_ACCEPTANCE" \
        --client "$TASKBROWSER" \
        --endpoint "$START_ENDPOINT" \
        --component sample

    kill -TERM "$DEPLOYER_PID"
    if ! wait "$DEPLOYER_PID"; then
        sed -n '1,240p' "$START_LOG" >&2
        orocos_rock_die "explicit OPC UA deployer failed during shutdown"
    fi
    DEPLOYER_PID=""

    if listening_socket "$START_PORT" | grep -q .; then
        listening_socket "$START_PORT" >&2
        orocos_rock_die "OPC UA port remained open after deployer shutdown"
    fi
done

RUNTIME_ENV="$TEST_ROOT/runtime-env.sh"
{
    printf 'export OROCOS_PREFIX=%q\n' "$PREFIX"
    printf 'export OROCOS_TARGET=%q\n' "$TARGET"
    printf 'export PKG_CONFIG_PATH=%q\n' "$PKG_CONFIG_PATH"
    printf 'export LD_LIBRARY_PATH=%q\n' "$LD_LIBRARY_PATH"
    printf 'export RTT_COMPONENT_PATH=%q\n' "$RTT_COMPONENT_PATH"
    printf 'export OROCOS_OPCUA_ENDPOINT=%q\n' "$START_ENDPOINT"
    printf 'export OROCOS_OPCUA_DEPLOYER=%q\n' "$DEPLOYER"
    printf 'export OROCOS_OPCUA_CLIENT=%q\n' "$CLIENT"
    printf 'export OROCOS_OPCUA_TYPEKIT=%q\n' "$TYPEKIT"
    printf 'export OROCOS_OPCUA_TRANSPORT=%q\n' "$TRANSPORT"
    printf 'export OROCOS_OPCUA_COMPONENT=%q\n' "$COMPONENT"
    printf 'export OROCOS_OPCUA_NO_START_SCRIPT=%q\n' "$NO_START_SCRIPT"
    printf 'export OROCOS_OPCUA_ENDPOINT_ONLY_SCRIPT=%q\n' \
        "$ENDPOINT_ONLY_SCRIPT"
    printf 'export OROCOS_OPCUA_START_SCRIPT=%q\n' "$START_SCRIPT"
} >"$RUNTIME_ENV"

trap - EXIT INT TERM

for binary in \
    "$SERVER" "$CLIENT" "$DEPLOYER_BINARY" "$TASKBROWSER_BINARY" \
    "$TYPEKIT" "$TRANSPORT" "$COMPONENT"
do
    ldd "$binary" >"$TEST_ROOT/$(basename "$binary").ldd"
done

CONTAMINATION="$({
    rg -F \
        -e "$CALLER_HOME_OROCOS" -e "$CALLER_HOME_OROCOS_REAL" \
        -e "$LOGIN_HOME_OROCOS" -e "$LOGIN_HOME_OROCOS_REAL" \
        "$TEST_ROOT" "$PREFIX" \
        --glob 'CMakeCache.txt' --glob '*.ldd' --glob '*.log' \
        --glob '*.pc' --glob '*.cmake' --glob '*.sh' || true
} | rg -v 'CMAKE_IGNORE_PREFIX_PATH' || true)"
if [ -n "$CONTAMINATION" ]; then
    printf '%s\n' "$CONTAMINATION" >&2
    orocos_rock_die \
        "isolated verification resolved an artifact below a home .orocos"
fi

orocos_rock_info "OPC UA custom datatype verification passed"
orocos_rock_info "Install prefix: $PREFIX"
orocos_rock_info "Evidence directory: $TEST_ROOT"
