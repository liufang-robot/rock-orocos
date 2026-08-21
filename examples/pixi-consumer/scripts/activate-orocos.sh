#!/usr/bin/env sh

if [ -z "${CONDA_PREFIX:-}" ]; then
    printf '%s\n' 'Cannot activate Orocos: CONDA_PREFIX is not set.' >&2
    return 1
fi

if [ -f "$CONDA_PREFIX/dev-env.sh" ]; then
    # shellcheck disable=SC1091
    . "$CONDA_PREFIX/dev-env.sh"
elif [ -f "$CONDA_PREFIX/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$CONDA_PREFIX/env.sh"
else
    printf 'Cannot activate Orocos: %s does not contain an Orocos package.\n' "$CONDA_PREFIX" >&2
    return 1
fi
