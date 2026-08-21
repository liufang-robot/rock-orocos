#!/usr/bin/env bash

set -euo pipefail

export GEM_HOME="$PREFIX/.invalid-workspace-gem-home"
export GEM_PATH="$PREFIX/.invalid-workspace-gem-path"
# shellcheck disable=SC1091
. "$PREFIX/dev-env.sh"

[ "$GEM_HOME" = "$PREFIX/toolchain/gems" ]
case ":$GEM_PATH:" in
    *:"$PREFIX/.invalid-workspace-gem-path":*) exit 1 ;;
esac
case ":$TYPELIB_PLUGIN_PATH:" in
    *:"$PREFIX/toolchain/lib/typelib":*) ;;
    *) exit 1 ;;
esac
[ -f "$PREFIX/toolchain/include/orocos/rtt/RTT.hpp" ]
[ -f "$PREFIX/toolchain/lib/cmake/orocos-rtt/orocos-rtt-config.cmake" ]
pkg-config --exists rtt_opcua-gnulinux
pkg-config --exists ocl-deployment-gnulinux
ruby -e 'require "typelib"; require "orogen"'
orogen --help >/dev/null
typegen --help >/dev/null
deployer_output="$(deployer-opcua-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$deployer_output"
