#!/bin/sh

if [ "${__OROCOS_ROCK_CONDA_ACTIVE:-}" != "1" ]; then
    return 0
fi

orocos_rock_remove_first_path_entry() {
    orocos_rock_path_to_remove=$1
    orocos_rock_path_remaining=${PATH-}
    orocos_rock_path_result=
    orocos_rock_path_result_started=
    orocos_rock_path_removed=

    while :; do
        case "$orocos_rock_path_remaining" in
            *:*)
                orocos_rock_path_entry=${orocos_rock_path_remaining%%:*}
                orocos_rock_path_remaining=${orocos_rock_path_remaining#*:}
                orocos_rock_path_has_more=1
                ;;
            *)
                orocos_rock_path_entry=$orocos_rock_path_remaining
                orocos_rock_path_has_more=0
                ;;
        esac

        if [ -z "$orocos_rock_path_removed" ] &&
            [ "$orocos_rock_path_entry" = "$orocos_rock_path_to_remove" ]; then
            orocos_rock_path_removed=1
        else
            if [ -n "$orocos_rock_path_result_started" ]; then
                orocos_rock_path_result="${orocos_rock_path_result}:$orocos_rock_path_entry"
            else
                orocos_rock_path_result=$orocos_rock_path_entry
                orocos_rock_path_result_started=1
            fi
        fi

        [ "$orocos_rock_path_has_more" = "1" ] || break
    done

    PATH=$orocos_rock_path_result
    export PATH
}

if [ "${__OROCOS_ROCK_PATH_PREFIX_BIN_PRESENT:-1}" = "0" ]; then
    orocos_rock_remove_first_path_entry \
        "$__OROCOS_ROCK_ACTIVATION_PREFIX/bin"
fi
if [ "${__OROCOS_ROCK_PATH_TOOLCHAIN_BIN_PRESENT:-1}" = "0" ]; then
    orocos_rock_remove_first_path_entry \
        "$__OROCOS_ROCK_ACTIVATION_PREFIX/toolchain/bin"
fi

if [ "${__OROCOS_ROCK_OROCOS_PREFIX_SET:-}" = "x" ]; then
    OROCOS_PREFIX=${__OROCOS_ROCK_OROCOS_PREFIX_VALUE-}
    export OROCOS_PREFIX
else
    unset OROCOS_PREFIX
fi
if [ "${__OROCOS_ROCK_OROCOS_TARGET_SET:-}" = "x" ]; then
    OROCOS_TARGET=${__OROCOS_ROCK_OROCOS_TARGET_VALUE-}
    export OROCOS_TARGET
else
    unset OROCOS_TARGET
fi
if [ "${__OROCOS_ROCK_LD_LIBRARY_PATH_SET:-}" = "x" ]; then
    LD_LIBRARY_PATH=${__OROCOS_ROCK_LD_LIBRARY_PATH_VALUE-}
    export LD_LIBRARY_PATH
else
    unset LD_LIBRARY_PATH
fi
if [ "${__OROCOS_ROCK_CMAKE_PREFIX_PATH_SET:-}" = "x" ]; then
    CMAKE_PREFIX_PATH=${__OROCOS_ROCK_CMAKE_PREFIX_PATH_VALUE-}
    export CMAKE_PREFIX_PATH
else
    unset CMAKE_PREFIX_PATH
fi
if [ "${__OROCOS_ROCK_PKG_CONFIG_PATH_SET:-}" = "x" ]; then
    PKG_CONFIG_PATH=${__OROCOS_ROCK_PKG_CONFIG_PATH_VALUE-}
    export PKG_CONFIG_PATH
else
    unset PKG_CONFIG_PATH
fi
if [ "${__OROCOS_ROCK_RTT_COMPONENT_PATH_SET:-}" = "x" ]; then
    RTT_COMPONENT_PATH=${__OROCOS_ROCK_RTT_COMPONENT_PATH_VALUE-}
    export RTT_COMPONENT_PATH
else
    unset RTT_COMPONENT_PATH
fi
if [ "${__OROCOS_ROCK_TYPELIB_PLUGIN_PATH_SET:-}" = "x" ]; then
    TYPELIB_PLUGIN_PATH=${__OROCOS_ROCK_TYPELIB_PLUGIN_PATH_VALUE-}
    export TYPELIB_PLUGIN_PATH
else
    unset TYPELIB_PLUGIN_PATH
fi

unset __OROCOS_ROCK_OROCOS_PREFIX_SET
unset __OROCOS_ROCK_OROCOS_PREFIX_VALUE
unset __OROCOS_ROCK_OROCOS_TARGET_SET
unset __OROCOS_ROCK_OROCOS_TARGET_VALUE
unset __OROCOS_ROCK_LD_LIBRARY_PATH_SET
unset __OROCOS_ROCK_LD_LIBRARY_PATH_VALUE
unset __OROCOS_ROCK_CMAKE_PREFIX_PATH_SET
unset __OROCOS_ROCK_CMAKE_PREFIX_PATH_VALUE
unset __OROCOS_ROCK_PKG_CONFIG_PATH_SET
unset __OROCOS_ROCK_PKG_CONFIG_PATH_VALUE
unset __OROCOS_ROCK_RTT_COMPONENT_PATH_SET
unset __OROCOS_ROCK_RTT_COMPONENT_PATH_VALUE
unset __OROCOS_ROCK_TYPELIB_PLUGIN_PATH_SET
unset __OROCOS_ROCK_TYPELIB_PLUGIN_PATH_VALUE
unset __OROCOS_ROCK_PATH_PREFIX_BIN_PRESENT
unset __OROCOS_ROCK_PATH_TOOLCHAIN_BIN_PRESENT
unset __OROCOS_ROCK_ACTIVATION_PREFIX
unset __OROCOS_ROCK_CONDA_ACTIVE
unset orocos_rock_path_to_remove
unset orocos_rock_path_remaining
unset orocos_rock_path_result
unset orocos_rock_path_result_started
unset orocos_rock_path_removed
unset orocos_rock_path_entry
unset orocos_rock_path_has_more
unset -f orocos_rock_remove_first_path_entry
