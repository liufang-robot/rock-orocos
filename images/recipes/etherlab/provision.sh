#!/bin/bash
set -euo pipefail
export LC_ALL=C TZ=UTC DEBIAN_FRONTEND=noninteractive
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$recipe_dir/inputs.sh"
apt-get -y --no-install-recommends install autoconf automake libtool pkg-config
build_dir="$recipe_dir/.build"
mkdir -p "$build_dir/source"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$ETHERLAB_URL" -o "$build_dir/source.tar.gz"
printf '%s  %s\n' "$ETHERLAB_SHA256" "$build_dir/source.tar.gz" | sha256sum --check --strict
tar -xzf "$build_dir/source.tar.gz" --strip-components=1 -C "$build_dir/source"
cd "$build_dir/source"
./bootstrap
# CI consumers link the real IgH library while disabling hardware access. The
# image does not need an EtherCAT master or physical NIC driver kernel module.
./configure --prefix="$ETHERLAB_PREFIX" --disable-kernel --enable-userlib --disable-fakeuserlib \
    --disable-initd --with-systemdsystemunitdir=no
make -j"$(nproc)"
make install
test -s "$ETHERLAB_PREFIX/include/ecrt.h"
test -e "$ETHERLAB_PREFIX/lib/libethercat.so"
printf '%s/lib\n' "$ETHERLAB_PREFIX" > /etc/ld.so.conf.d/etherlab.conf
ldconfig
install -Dm0644 COPYING "$ETHERLAB_PREFIX/share/licenses/ethercat/COPYING"
