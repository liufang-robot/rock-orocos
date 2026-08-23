#!/usr/bin/env bash

set -euo pipefail

for name in PREFIX RECIPE_DIR SRC_DIR BUILD_PREFIX SUBDIR; do
    [ -n "${!name:-}" ] || {
        printf 'Rattler-Build did not provide %s.\n' "$name" >&2
        exit 1
    }
done

[ "$SUBDIR" = "linux-64" ] || {
    printf "The Linux Orocos package supports linux-64, not '%s'.\n" "$SUBDIR" >&2
    exit 1
}

repository_root="$(cd "$SRC_DIR" && pwd)"
temporary_home="$(mktemp -d "${TMPDIR:-/tmp}/orocos-linux-package.XXXXXX")"
trap 'rm -rf "$temporary_home"' EXIT

export HOME="$temporary_home"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export OROCOS_PREFIX="$PREFIX"
export OROCOS_TARGET=gnulinux
export OROCOS_ROCK_BUILD_TOOLS_PREFIX="$BUILD_PREFIX"
export OROCOS_ROCK_DEPENDENCY_PREFIX="$PREFIX"
export OROCOS_ROCK_RUBY_GEM_CACHE="$repository_root/.ruby-gems"
export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT:-2}"
export JOBS="${CPU_COUNT:-2}"

cd "$repository_root"

ruby tools/linux-source-lock.rb apply packaging/source-lock.json "$repository_root"
./tools/install-autoproj.sh --gem-cache "$OROCOS_ROCK_RUBY_GEM_CACHE"
./tools/bootstrap.sh --prefix "$PREFIX" --target gnulinux --skip-osdeps
./tools/install.sh --prefix "$PREFIX" --target gnulinux --skip-osdeps
ruby tools/linux-source-lock.rb verify packaging/source-lock.json "$repository_root"
./tools/validate-install.sh --prefix "$PREFIX" --target gnulinux
./packaging/conda/prepare-linux-prefix.sh \
    "$PREFIX" "$BUILD_PREFIX" "$repository_root" "$temporary_home"
