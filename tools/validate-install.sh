#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./tools/validate-install.sh [--prefix PREFIX] [--target gnulinux|xenomai]

Validate the installed Orocos/Rock prefix exported by orocos-rock.

Options:
  --prefix PREFIX  Installed toolchain prefix. Default: $OROCOS_PREFIX or ~/.orocos
  --target TARGET  Orocos target to validate. Default: $OROCOS_TARGET or gnulinux
  -h, --help       Show this help
USAGE
}

PREFIX="$OROCOS_ROCK_DEFAULT_PREFIX"
TARGET="$OROCOS_ROCK_DEFAULT_TARGET"

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
        *)
            usage >&2
            orocos_rock_die "unknown argument: $1"
            ;;
    esac
done

orocos_rock_validate_target "$TARGET"
DEPLOYER="$(orocos_rock_target_deployer "$TARGET")"
OPCUA_DEPLOYER="$(orocos_rock_target_opcua_deployer "$TARGET")"
OPCUA_BROWSER="ctaskbrowser-opcua-$TARGET"
MQUEUE_TRANSPORT="$PREFIX/toolchain/lib/orocos/$TARGET/types/librtt-transport-mqueue-$TARGET.so"

orocos_rock_require_file "$PREFIX/env.sh"
orocos_rock_require_file "$PREFIX/dev-env.sh"
orocos_rock_require_file "$MQUEUE_TRANSPORT"
orocos_rock_require_file "$PREFIX/toolchain/include/orocos/eigen_typekit/eigen_typekit.hpp"
orocos_rock_require_file "$PREFIX/toolchain/lib/orocos/$TARGET/eigen_typekit/types/libeigen_typekit-$TARGET.so"
orocos_rock_require_file "$PREFIX/toolchain/lib/orocos/$TARGET/eigen_typekit/types/libeigen-transport-mqueue-$TARGET.so"
if [ -e "$PREFIX/toolchain/lib/orocos/$TARGET/kdl_typekit" ]; then
    orocos_rock_die "the Eigen-only toolchain unexpectedly contains kdl_typekit"
fi
orocos_rock_require_file "$PREFIX/toolchain/lib/orocos/$TARGET/rtt_http/types/librtt-transport-http-$TARGET.so"
orocos_rock_require_file "$PREFIX/toolchain/lib/orocos/$TARGET/ocl/plugins/libhttp-$TARGET.so"
orocos_rock_require_file "$PREFIX/toolchain/lib/cmake/rtt_http/rtt_httpConfig.cmake"

(
    # shellcheck disable=SC1090
    . "$PREFIX/env.sh"
    export OROCOS_TARGET="$TARGET"
    orocos_rock_require_command "$DEPLOYER"
    deployer_version_output="$("$DEPLOYER" --version 2>&1 || true)"
    if ! orocos_rock_validate_deployer_version_output "$TARGET" "$deployer_version_output"; then
        orocos_rock_die "$DEPLOYER smoke check failed"
    fi
    orocos_rock_require_command "$OPCUA_DEPLOYER"
    opcua_deployer_version_output="$("$OPCUA_DEPLOYER" --version 2>&1 || true)"
    if ! orocos_rock_validate_deployer_version_output "$TARGET" "$opcua_deployer_version_output"; then
        orocos_rock_die "$OPCUA_DEPLOYER smoke check failed"
    fi
    orocos_rock_require_command "$OPCUA_BROWSER"
    "$OPCUA_BROWSER" --version >/dev/null
    orocos_rock_require_command pkg-config
    pkg-config --exists "rtt_opcua-$TARGET"
    pkg-config --exists "rtt_http-$TARGET"
    pkg-config --exists "eigen_typekit-$TARGET"
    pkg-config --exists "ocl-deployment-$TARGET"
    "$DEPLOYER" --check "$SCRIPT_DIR/../tests/http-service/runtime.ops"
    "$DEPLOYER" --check "$SCRIPT_DIR/../tests/eigen-typekit/runtime.ops"
    case ":${TYPELIB_PLUGIN_PATH:-}:" in
        *:"$OROCOS_PREFIX/toolchain/lib/typelib":*) ;;
        *) orocos_rock_die "env.sh did not expose installed Typelib plugins" ;;
    esac
)

(
    export GEM_HOME="$PREFIX/.invalid-workspace-gem-home"
    export GEM_PATH="$PREFIX/.invalid-workspace-gem-path"
    # shellcheck disable=SC1090
    . "$PREFIX/dev-env.sh"
    if [ "$GEM_HOME" != "$OROCOS_PREFIX/toolchain/gems" ]; then
        orocos_rock_die "dev-env.sh did not select the installed Ruby gem home"
    fi
    case ":$GEM_PATH:" in
        *:"$PREFIX/.invalid-workspace-gem-path":*)
            orocos_rock_die "dev-env.sh retained a workspace Ruby gem path"
            ;;
    esac
    orocos_rock_require_command orogen
    orocos_rock_require_command typegen
    ruby -e 'require "typelib"; require "orogen"'
    orogen --help >/dev/null
    typegen --help >/dev/null
    eigen_consumer_build="$(mktemp -d "${TMPDIR:-/tmp}/orocos-eigen-consumer.XXXXXX")"
    trap 'rm -rf -- "$eigen_consumer_build"' EXIT
    cmake -S "$SCRIPT_DIR/../tests/eigen-typekit" -B "$eigen_consumer_build" \
        -DCMAKE_BUILD_TYPE=Release -DOROCOS_TARGET="$TARGET"
    cmake --build "$eigen_consumer_build" --parallel 2
    ctest --test-dir "$eigen_consumer_build" --output-on-failure --no-tests=error
)

orocos_rock_info "Validated Orocos/Rock $TARGET install prefix: $PREFIX"
