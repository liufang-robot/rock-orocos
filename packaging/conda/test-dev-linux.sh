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

status_code_generator="$PREFIX/toolchain/share/open62541/generate_statuscode_descriptions.py"
status_code_csv="$PREFIX/toolchain/share/open62541/schema/StatusCode.csv"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/orocos-open62541-generator.XXXXXX")"

cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

status_code_output="$temporary_directory/statuscode_descriptions"
"$PREFIX/bin/python" "$status_code_generator" "$status_code_csv" "$status_code_output"

generated_c="${status_code_output}.c"
generated_h="${status_code_output}.h"
[ -s "$generated_c" ]
[ -s "$generated_h" ]
grep -q "UA_StatusCode_name" "$generated_c"
grep -q "UA_STATUSCODE_BADUNEXPECTEDERROR" "$generated_h"
