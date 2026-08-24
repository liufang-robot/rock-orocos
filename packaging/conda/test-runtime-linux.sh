#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031

set -euo pipefail

test -f "$PREFIX/etc/conda/activate.d/orocos-activate.sh"
test -f "$PREFIX/etc/conda/deactivate.d/orocos-deactivate.sh"
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

activation_hook="$PREFIX/etc/conda/activate.d/orocos-activate.sh"
deactivation_hook="$PREFIX/etc/conda/deactivate.d/orocos-deactivate.sh"
managed_variables=(
    OROCOS_PREFIX
    OROCOS_TARGET
    LD_LIBRARY_PATH
    CMAKE_PREFIX_PATH
    PKG_CONFIG_PATH
    RTT_COMPONENT_PATH
    TYPELIB_PLUGIN_PATH
)

assert_no_orocos_hook_state() {
    if env | grep -q '^__OROCOS_ROCK_'; then
        env | grep '^__OROCOS_ROCK_' >&2
        return 1
    fi
}

(
    # Rattler activates the package before running this test. Reset that
    # inherited lifecycle state before constructing an independent fixture.
    # shellcheck disable=SC1090
    . "$deactivation_hook"
    assert_no_orocos_hook_state

    export CONDA_PREFIX="$PREFIX"
    initial_path="$PREFIX/bin:/usr/bin:/bin"
    export PATH="$initial_path"
    for name in "${managed_variables[@]}"; do
        export "$name=before-$name::with spaces"
    done
    export LD_LIBRARY_PATH=

    # shellcheck disable=SC1090
    . "$activation_hook"
    # shellcheck disable=SC1090
    . "$activation_hook"
    test "$OROCOS_PREFIX" = "$PREFIX"
    test "$OROCOS_TARGET" = "gnulinux"

    # shellcheck disable=SC1090
    . "$deactivation_hook"
    # shellcheck disable=SC1090
    . "$deactivation_hook"

    test "$PATH" = "$initial_path"
    for name in "${managed_variables[@]}"; do
        [[ -v "$name" ]]
        if [ "$name" = "LD_LIBRARY_PATH" ]; then
            test -z "${!name}"
        else
            test "${!name}" = "before-$name::with spaces"
        fi
    done
    assert_no_orocos_hook_state
)

(
    # Keep this unset-variable fixture independent of Rattler's activation.
    # shellcheck disable=SC1090
    . "$deactivation_hook"
    assert_no_orocos_hook_state

    export CONDA_PREFIX="$PREFIX"
    initial_path="/usr/bin:/bin"
    export PATH="$initial_path"
    unset "${managed_variables[@]}"

    # shellcheck disable=SC1090
    . "$activation_hook"
    # shellcheck disable=SC1090
    . "$activation_hook"
    case ":$PATH:" in
        *:"$PREFIX/bin":*) ;;
        *) exit 1 ;;
    esac
    case ":$PATH:" in
        *:"$PREFIX/toolchain/bin":*) ;;
        *) exit 1 ;;
    esac

    # shellcheck disable=SC1090
    . "$deactivation_hook"
    # shellcheck disable=SC1090
    . "$deactivation_hook"

    test "$PATH" = "$initial_path"
    for name in "${managed_variables[@]}"; do
        [[ ! -v "$name" ]]
    done
    assert_no_orocos_hook_state
)

deployer_output="$(deployer-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$deployer_output"
opcua_output="$(deployer-opcua-gnulinux --version 2>&1 || true)"
grep -q "OROCOS Toolchain version" <<<"$opcua_output"
ctaskbrowser-opcua-gnulinux --version >/dev/null
