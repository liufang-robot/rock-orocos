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
activation_hook_source="$repository_root/packaging/conda/orocos-activate.sh"
activation_hook_directory="$prefix/etc/conda/activate.d"

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

[ -f "$activation_hook_source" ] || {
    printf 'Linux runtime activation hook is missing: %s\n' \
        "$activation_hook_source" >&2
    exit 1
}

install -d -m 0755 "$activation_hook_directory"
install -m 0644 "$activation_hook_source" \
    "$activation_hook_directory/orocos-activate.sh"

ruby "$repository_root/tools/stage-license-corpus.rb" \
    --inventory "$repository_root/packaging/license-corpus.json" \
    --source-lock "$repository_root/packaging/source-lock.json" \
    --platform linux \
    --source-root "$repository_root" \
    --gem-home "$prefix/toolchain/gems" \
    --gem-cache "$repository_root/.ruby-gems" \
    --prefix "$prefix"

ruby "$repository_root/packaging/conda/sanitize-linux-prefix.rb" \
    --prefix "$prefix" \
    --build-prefix "$build_prefix" \
    --repository-root "$repository_root" \
    --temporary-home "$temporary_home"

ruby "$repository_root/tools/check-linux-glibc-compatibility.rb" \
    --prefix "$prefix/toolchain" \
    --maximum-version 2.17

printf 'Prepared Linux Orocos package prefix: %s\n' "$prefix"
