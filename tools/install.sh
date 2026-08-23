#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./tools/install.sh [--prefix PREFIX] [--target gnulinux|xenomai] [--skip-osdeps] [--no-export-env] [-- PACKAGE...]

Update and build the selected Autoproj package layout for the Orocos/Rock
toolchain, then refresh the exported environment scripts.

Options:
  --prefix PREFIX  Installed toolchain prefix. Default: $OROCOS_PREFIX or ~/.orocos
  --target TARGET  Orocos target to build and export. Default: $OROCOS_TARGET or gnulinux
  --skip-osdeps    Do not invoke the host operating-system package manager
  --no-export-env  Do not regenerate PREFIX/env.sh and PREFIX/dev-env.sh after build
  -h, --help       Show this help

Arguments after "--" are passed to "autoproj build".
USAGE
}

PREFIX="$OROCOS_ROCK_DEFAULT_PREFIX"
TARGET="$OROCOS_ROCK_DEFAULT_TARGET"
EXPORT_ENV=1
INSTALL_OSDEPS=1
BUILD_ARGS=()
SOURCE_PACKAGES=(farbot rtlog-cpp rtt open62541 open62541pp rtt_opcua ocl orogen typelib utilmm rtt_typelib)

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
        --no-export-env)
            EXPORT_ENV=0
            shift
            ;;
        --skip-osdeps)
            INSTALL_OSDEPS=0
            shift
            ;;
        --)
            shift
            BUILD_ARGS=("$@")
            break
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

orocos_rock_require_file "$OROCOS_ROCK_ROOT/autoproj/manifest"
orocos_rock_require_autoproj
orocos_rock_ensure_workspace_ruby_gems
orocos_rock_source_workspace_env
orocos_rock_configure_target_environment "$TARGET"
orocos_rock_prepare_autoproj_workspace "$PREFIX" "none" "$TARGET"

cd "$OROCOS_ROCK_ROOT"

orocos_rock_info "Updating Autoproj sources"
orocos_rock_run_preserving_install_env "$PREFIX" \
    orocos_rock_autoproj update --no-interactive --no-osdeps --no-config --no-bundler --no-autoproj "${SOURCE_PACKAGES[@]}"

orocos_rock_info "Checking resolved dependency policy"
GEM_PATH="$(orocos_rock_user_gem_path)" \
    ruby "$SCRIPT_DIR/check-resolved-dependencies.rb"

orocos_rock_info "Checking C++20 package policy"
ruby "$SCRIPT_DIR/check-cpp20-policy.rb"

if [ "$INSTALL_OSDEPS" -eq 1 ]; then
    orocos_rock_info "Installing source-declared operating-system dependencies"
    orocos_rock_run_preserving_install_env "$PREFIX" \
        orocos_rock_autoproj osdeps --no-interactive
fi

orocos_rock_info "Building Autoproj layout"
orocos_rock_run_preserving_install_env "$PREFIX" \
    orocos_rock_autoproj build --no-interactive "${BUILD_ARGS[@]}"

"$SCRIPT_DIR/install-ruby-tools.sh" --prefix "$PREFIX"

if [ "$EXPORT_ENV" -eq 1 ]; then
    "$SCRIPT_DIR/export-env.sh" --prefix "$PREFIX" --target "$TARGET"
fi
