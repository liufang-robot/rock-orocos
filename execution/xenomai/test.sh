#!/bin/bash
# Run as the image's runner account after booting the Cobalt kernel.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
expected_revision=${1:-$(git rev-parse HEAD)}
work="$root/execution/.local/xenomai"
mkdir -p "$(dirname "$work")"
mkdir "$work"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PATH="/usr/xenomai/bin:$PATH"
export XENOMAI_DIR=/usr/xenomai XENOMAI_ROOT_DIR=/usr/xenomai
export CC=gcc-14 CXX=g++-14
export JOBS="$(nproc)" CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)"

# Exercise the same installed-prefix acceptance as the independent VM job.
# The expected image revision may differ from this test checkout, but must be
# selected explicitly when testing an older published image.
mkdir "$work/installed"
ln -s "$root/execution/cobalt" "$work/installed/cobalt"
ln -s "$root" "$work/installed/orocos"
bash images/validate/validate-guest.sh "$work/installed" "$expected_revision" \
    2>&1 | tee "$work/installed.log"
bash execution/xenomai/latency.sh "$work"

# Keep the AMI's installed prefix intact while testing a clean source build.
export OROCOS_PREFIX="$work/prefix" OROCOS_TARGET=xenomai
ruby tools/linux-source-lock.rb apply packaging/source-lock.json .
./tools/setup.sh --prefix "$OROCOS_PREFIX" --target xenomai --skip-osdeps \
    2>&1 | tee "$work/build.log"
ruby tools/linux-source-lock.rb verify packaging/source-lock.json .
for subset in rtt-core rtt-opcua rtt-http; do
    ./tools/test-package.sh --prefix "$OROCOS_PREFIX" --target xenomai "$subset" \
        2>&1 | tee "$work/$subset.log"
done

# This regression is specific to Cobalt task teardown and is outside the
# target-independent subset selected by test-package.sh.
source "$OROCOS_PREFIX/dev-env.sh"
cmake --build toolchain/tools/rtt/build --parallel "$JOBS" \
    --target xenomai3-task-lifetime-test
ctest --test-dir toolchain/tools/rtt/build --output-on-failure --no-tests=error \
    --timeout 120 -R '^xenomai3-task-lifetime-test$' \
    2>&1 | tee "$work/task-lifetime.log"
printf 'Xenomai image and package acceptance passed; logs: %s\n' "$work"
