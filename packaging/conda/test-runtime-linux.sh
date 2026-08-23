#!/usr/bin/env bash

set -euo pipefail

test -f "$PREFIX/etc/conda/activate.d/orocos-activate.sh"
test -n "${CONDA_PREFIX:-}"
resolved_conda_prefix="$(cd "$CONDA_PREFIX" && pwd)"
resolved_test_prefix="$(cd "$PREFIX" && pwd)"
test "$resolved_conda_prefix" = "$resolved_test_prefix"

test "$OROCOS_PREFIX" = "$PREFIX"
test "$OROCOS_TARGET" = "gnulinux"
[ ! -e "$PREFIX/toolchain/include/orocos/rtt/RTT.hpp" ]
[ ! -e "$PREFIX/toolchain/lib/ruby/3.4.0/x86_64-linux/typelib_ruby.so" ]
[ -f "$PREFIX/toolchain/lib/orocos/gnulinux/types/librtt-transport-mqueue-gnulinux.so" ]
case ":$TYPELIB_PLUGIN_PATH:" in
    *:"$PREFIX/toolchain/lib/typelib":*) ;;
    *) exit 1 ;;
esac

deployer_output="$(deployer-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$deployer_output"
opcua_output="$(deployer-opcua-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$opcua_output"
ctaskbrowser-opcua-gnulinux --version >/dev/null
