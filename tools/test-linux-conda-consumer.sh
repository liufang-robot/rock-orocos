#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: test-linux-conda-consumer.sh --manifest PATH (--local-channel PATH | --channel-url URL) [--attempts N]
USAGE
}

manifest_path=""
channel=""
attempts=1
retry_delay=10

while [ "$#" -gt 0 ]; do
    case "$1" in
        --manifest)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            manifest_path="$2"
            shift 2
            ;;
        --local-channel)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            [ -z "$channel" ] || { usage >&2; exit 1; }
            channel="file://$(cd "$2" && pwd)"
            shift 2
            ;;
        --channel-url)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            [ -z "$channel" ] || { usage >&2; exit 1; }
            channel="$2"
            shift 2
            ;;
        --attempts)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            attempts="$2"
            shift 2
            ;;
        --retry-delay)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            retry_delay="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

[ -f "$manifest_path" ] || {
    printf 'missing release manifest: %s\n' "$manifest_path" >&2
    exit 1
}
[ -n "$channel" ] || { usage >&2; exit 1; }
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || {
    printf 'attempts must be a positive integer\n' >&2
    exit 1
}

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
activation_script="$repository_root/examples/pixi-consumer/scripts/activate-orocos.sh"
[ -f "$activation_script" ] || {
    printf 'missing Pixi consumer activation script: %s\n' \
        "$activation_script" >&2
    exit 1
}
glibc_checker="$repository_root/tools/check-linux-glibc-compatibility.rb"
[ -f "$glibc_checker" ] || {
    printf 'missing Linux GLIBC compatibility checker: %s\n' \
        "$glibc_checker" >&2
    exit 1
}

readarray -t package_specs < <(
    ruby -rjson -e '
      manifest = JSON.parse(File.read(ARGV.fetch(0)))
      packages = manifest.fetch("packages").to_h do |item|
        [item.fetch("name"), item]
      end
      %w[orocos orocos-dev].each do |name|
        item = packages.fetch(name)
        puts "#{name}==#{item.fetch("version")}=#{item.fetch("build")}"
      end
    ' "$manifest_path"
)
[ "${#package_specs[@]}" -eq 2 ]

runtime_command="$(cat <<'COMMAND'
set -euo pipefail
test "${OROCOS_PREFIX:-}" = "$CONDA_PREFIX"
test "${OROCOS_TARGET:-}" = "gnulinux"
test "$(command -v deployer-opcua-gnulinux)" = "$CONDA_PREFIX/toolchain/bin/deployer-opcua-gnulinux"
test ! -e "$CONDA_PREFIX/toolchain/include/orocos/rtt/RTT.hpp"
test -f "$CONDA_PREFIX/toolchain/lib/orocos/gnulinux/types/librtt-transport-mqueue-gnulinux.so"
case ":$TYPELIB_PLUGIN_PATH:" in
    *:"$CONDA_PREFIX/toolchain/lib/typelib":*) ;;
    *) exit 1 ;;
esac
deployer_output="$(deployer-opcua-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$deployer_output"
ctaskbrowser-opcua-gnulinux --version >/dev/null
COMMAND
)"

development_command="$(cat <<'COMMAND'
set -euo pipefail
# Invalid gem paths prove that the wrapper selected dev-env.sh rather than env.sh.
export GEM_HOME="$CONDA_PREFIX/.invalid-workspace-gem-home"
export GEM_PATH="$CONDA_PREFIX/.invalid-workspace-gem-path"
. "$OROCOS_PIXI_ACTIVATION_SCRIPT"
test "$GEM_HOME" = "$CONDA_PREFIX/toolchain/gems"
case ":$GEM_PATH:" in
    *:"$CONDA_PREFIX/.invalid-workspace-gem-path":*) exit 1 ;;
esac
case ":$TYPELIB_PLUGIN_PATH:" in
    *:"$CONDA_PREFIX/toolchain/lib/typelib":*) ;;
    *) exit 1 ;;
esac
test -f "$CONDA_PREFIX/toolchain/include/orocos/rtt/RTT.hpp"
ruby -e 'require "typelib"; require "orogen"'
ruby "$OROCOS_GLIBC_CHECKER" \
    --prefix "$CONDA_PREFIX/toolchain" \
    --maximum-version 2.17
orogen --help >/dev/null
typegen --help >/dev/null
deployer_output="$(deployer-opcua-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$deployer_output"
COMMAND
)"

cache_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/orocos-linux-consumer.XXXXXX")"
trap 'rm -rf "$cache_root"' EXIT

for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    export PIXI_CACHE_DIR="$cache_root/attempt-$attempt"
    mkdir -p "$PIXI_CACHE_DIR"
    printf 'Testing Linux package consumers from %s (attempt %d of %d).\n' \
        "$channel" "$attempt" "$attempts"
    if env -u OROCOS_PIXI_ACTIVATION_SCRIPT \
           -u OROCOS_PREFIX \
           -u OROCOS_TARGET \
           -u TYPELIB_PLUGIN_PATH \
           pixi exec --force-reinstall --platform linux-64 \
           --spec "${package_specs[0]}" \
           --channel "$channel" --channel conda-forge \
           bash -c "$runtime_command" &&
       env -u OROCOS_PREFIX \
           -u OROCOS_TARGET \
           -u TYPELIB_PLUGIN_PATH \
           OROCOS_PIXI_ACTIVATION_SCRIPT="$activation_script" \
           OROCOS_GLIBC_CHECKER="$glibc_checker" \
           pixi exec --force-reinstall --platform linux-64 \
           --spec "${package_specs[1]}" \
           --channel "$channel" --channel conda-forge \
           bash -c "$development_command"; then
        printf 'Clean Linux runtime and development consumer checks passed.\n'
        exit 0
    fi

    [ "$attempt" -lt "$attempts" ] || exit 1
    sleep "$retry_delay"
done
