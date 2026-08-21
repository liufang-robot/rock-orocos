#!/usr/bin/env bash

set -euo pipefail

[ "$#" -eq 4 ] || {
    printf 'usage: prepare-linux-prefix.sh PREFIX BUILD_PREFIX REPOSITORY_ROOT TEMPORARY_HOME\n' >&2
    exit 1
}

prefix="$(cd "$1" && pwd)"
build_prefix="$(cd "$2" && pwd)"
repository_root="$(cd "$3" && pwd)"
temporary_home="$(cd "$4" && pwd)"

for required in \
    "$prefix/env.sh" \
    "$prefix/dev-env.sh" \
    "$prefix/toolchain/bin/deployer-gnulinux" \
    "$prefix/toolchain/bin/orogen" \
    "$prefix/toolchain/bin/typegen" \
    "$prefix/toolchain/include/orocos/rtt/RTT.hpp" \
    "$prefix/toolchain/lib/orocos/gnulinux/types/librtt-transport-mqueue-gnulinux.so"; do
    [ -f "$required" ] || {
        printf 'required Linux package file is missing: %s\n' "$required" >&2
        exit 1
    }
done

ruby "$repository_root/packaging/conda/sanitize-linux-prefix.rb" \
    --prefix "$prefix" \
    --build-prefix "$build_prefix" \
    --repository-root "$repository_root" \
    --temporary-home "$temporary_home"

printf 'Prepared Linux Orocos package prefix: %s\n' "$prefix"
