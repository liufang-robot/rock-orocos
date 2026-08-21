#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./tools/install-ruby-tools.sh --prefix PREFIX [--gem-cache DIRECTORY]

Build and install the Ruby-based Orocos generator tools into the public
toolchain prefix. A configured gem cache makes dependency installation local
and exact; normal source builds continue to resolve the same versions online.
USAGE
}

PREFIX=""
GEM_CACHE="${OROCOS_ROCK_RUBY_GEM_CACHE:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || orocos_rock_die "--prefix requires a value"
            PREFIX="$2"
            shift 2
            ;;
        --gem-cache)
            [ "$#" -ge 2 ] || orocos_rock_die "--gem-cache requires a value"
            GEM_CACHE="$2"
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

if [ -n "$GEM_CACHE" ]; then
    orocos_rock_set_ruby_gem_cache "$GEM_CACHE"
fi

orocos_rock_require_command ruby
orocos_rock_require_command gem

PREFIX="$(mkdir -p "$PREFIX" && cd "$PREFIX" && pwd)"
TOOLCHAIN_PREFIX="$PREFIX/toolchain"
GEM_HOME_DIR="$TOOLCHAIN_PREFIX/gems"
BIN_DIR="$TOOLCHAIN_PREFIX/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$GEM_HOME_DIR" "$BIN_DIR"

install_remote_gem() {
    local gem_name="$1"
    local gem_version="$2"
    local args=()

    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        args=(--local --ignore-dependencies "$(orocos_rock_cached_gem_path "$gem_name" "$gem_version")")
    else
        args=(-v "$gem_version")
        args+=("$gem_name")
    fi

    GEM_HOME="$GEM_HOME_DIR" GEM_PATH="$GEM_HOME_DIR" \
        gem install --install-dir "$GEM_HOME_DIR" --bindir "$BIN_DIR" \
        --env-shebang --no-document "${args[@]}"
}

install_local_gem() {
    local package_dir="$1"
    local gemspec_path gem_name gem_path

    gemspec_path="$(find "$package_dir" -maxdepth 1 -name '*.gemspec' -print -quit)"
    [ -n "$gemspec_path" ] || orocos_rock_die "no gemspec found under $package_dir"

    gem_name="$(basename "${gemspec_path%.gemspec}")"
    gem_path="$TMP_DIR/$gem_name.gem"

    gem build -C "$package_dir" "$(basename "$gemspec_path")" --output "$gem_path" >/dev/null

    GEM_HOME="$GEM_HOME_DIR" GEM_PATH="$GEM_HOME_DIR" \
        gem install --install-dir "$GEM_HOME_DIR" --bindir "$BIN_DIR" \
        --env-shebang --local --no-document --ignore-dependencies "$gem_path"

    if [ -d "$package_dir/bin" ]; then
        find "$package_dir/bin" -maxdepth 1 -type f ! -name '.*' -print | while read -r executable_path; do
            install -m 0755 "$executable_path" "$BIN_DIR/$(basename "$executable_path")"
        done
    fi
}

orocos_rock_info "Installing Ruby runtime dependencies into $GEM_HOME_DIR"
install_remote_gem facets 3.1.0
install_remote_gem backports 3.25.3
install_remote_gem base64 0.3.0
install_remote_gem rexml 3.4.4
install_remote_gem kramdown 2.5.2
install_remote_gem rake 13.4.2

orocos_rock_info "Installing utilrb into the public toolchain prefix"
install_local_gem "$OROCOS_ROCK_ROOT/toolchain/tools/utilrb"

orocos_rock_info "Installing metaruby into the public toolchain prefix"
install_local_gem "$OROCOS_ROCK_ROOT/tools/metaruby"

orocos_rock_info "Installing orogen into the public toolchain prefix"
install_local_gem "$OROCOS_ROCK_ROOT/toolchain/tools/orogen"
