#!/bin/bash
set -euo pipefail
cd "${1:?toolchain source directory required}"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export XENOMAI_DIR=/usr/xenomai XENOMAI_ROOT_DIR=/usr/xenomai
export PATH="/usr/xenomai/bin:$PATH"
export OROCOS_TARGET=xenomai OROCOS_PREFIX=/opt/orocos
export CC=gcc-14 CXX=g++-14
export JOBS="$(nproc)" CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)"
ruby tools/linux-source-lock.rb apply packaging/source-lock.json .
./tools/install-autoproj.sh
./tools/bootstrap.sh --prefix "$OROCOS_PREFIX" --target xenomai
./tools/install.sh --prefix "$OROCOS_PREFIX" --target xenomai
ruby tools/linux-source-lock.rb verify packaging/source-lock.json .
# setup.sh also runs target executables. Runtime acceptance belongs to the
# validator after it has booted the installed Cobalt kernel.
test -s "$OROCOS_PREFIX/dev-env.sh"
test -x "$OROCOS_PREFIX/toolchain/bin/deployer-xenomai"
