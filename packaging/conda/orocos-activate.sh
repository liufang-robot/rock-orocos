#!/bin/sh

if [ -z "${CONDA_PREFIX:-}" ]; then
    printf '%s\n' 'Cannot activate Orocos runtime: CONDA_PREFIX is not set.' >&2
    return 1
fi

if [ ! -f "$CONDA_PREFIX/env.sh" ]; then
    printf 'Cannot activate Orocos runtime: missing %s.\n' \
        "$CONDA_PREFIX/env.sh" >&2
    return 1
fi

# shellcheck disable=SC1091
. "$CONDA_PREFIX/env.sh"
