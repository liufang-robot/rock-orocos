#!/bin/bash
set -euo pipefail
export LC_ALL=C TZ=UTC
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$recipe_dir/inputs.sh"
printf '%s  %s\n' "$KERNEL_CONFIG_SHA256" "$recipe_dir/kernel.config" | sha256sum --check --strict
build_dir="$recipe_dir/.build"
export TMPDIR="$build_dir/tmp"
source_dir="$build_dir/linux"
xenomai_dir="$build_dir/xenomai"
userspace_build="$build_dir/xenomai-build"
mkdir -p "$TMPDIR" "$source_dir" "$xenomai_dir" "$userspace_build"
archive="$build_dir/linux-dovetail.tar.gz"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$SOURCE_URL" -o "$archive"
printf '%s  %s\n' "$SOURCE_SHA256" "$archive" | sha256sum --check --strict
tar -xzf "$archive" --strip-components=1 -C "$source_dir"
archive="$build_dir/xenomai.tar.gz"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$XENOMAI_URL" -o "$archive"
printf '%s  %s\n' "$XENOMAI_SHA256" "$archive" | sha256sum --check --strict
tar -xzf "$archive" --strip-components=1 -C "$xenomai_dir"
# The pinned Linux tree already contains Dovetail; integrate this exact Cobalt source.
"$xenomai_dir/scripts/prepare-kernel.sh" --linux="$source_dir" --arch=x86_64
cd "$source_dir"
kernel_make=(make CC=gcc-14 HOSTCC=gcc-14)
cp "$recipe_dir/kernel.config" .config
"${kernel_make[@]}" olddefconfig
for option in CONFIG_DOVETAIL CONFIG_XENOMAI CONFIG_XENO_DRIVERS_RTIPC \
    CONFIG_XENO_DRIVERS_RTIPC_XDDP CONFIG_XENO_DRIVERS_RTIPC_IDDP CONFIG_XENO_DRIVERS_RTIPC_BUFP; do
    grep -qx "$option=y" .config || { printf 'Required kernel option missing: %s\n' "$option" >&2; exit 1; }
done
release=$("${kernel_make[@]}" -s kernelrelease)
"${kernel_make[@]}" -j"$(nproc)" bzImage modules
"${kernel_make[@]}" INSTALL_MOD_STRIP=1 modules_install
rm -f "/lib/modules/$release/build" "/lib/modules/$release/source"
install -m 0644 arch/x86/boot/bzImage "/boot/vmlinuz-$release"
install -m 0644 .config "/boot/config-$release"
install -m 0644 System.map "/boot/System.map-$release"
# Keep both QEMU virtio and EC2 NVMe storage bootable with the supplied modular
# configuration. Network modules are included too, for both validation hosts.
printf '%s\n' nvme nvme_core ext4 virtio_blk virtio_pci virtio_net ena >> /etc/initramfs-tools/modules
update-initramfs -c -k "$release"
test -s "/boot/initrd.img-$release"
install -d /usr/local/share/rock-orocos-image
printf '%s\n' "$release" > /usr/local/share/rock-orocos-image/kernel-release
# Build the matching Cobalt SDK, retaining its application headers and libraries.
cd "$xenomai_dir"
./scripts/bootstrap
cd "$userspace_build"
"$xenomai_dir/configure" --prefix="$XENOMAI_PREFIX" --with-core=cobalt \
  --enable-smp --disable-registry --disable-doc-build CC=gcc-14 CXX=g++-14
make -j"$(nproc)"
make install-strip
printf '%s/lib\n' "$XENOMAI_PREFIX" > /etc/ld.so.conf.d/xenomai.conf
ldconfig
# The stock kernels are removed; the remaining kernel needs Cobalt group access.
cat > /etc/default/grub.d/99-rock-orocos.cfg <<EOF
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} xenomai.allowed_group=$XENOMAI_GID"
EOF
# Installed modules are stripped; the large debug build belongs only to the
# disposable build disk. Reclaim its blocks before building the Orocos stack.
rm -rf -- "$source_dir" "$xenomai_dir" "$userspace_build"
fstrim "$(findmnt --noheadings --output TARGET --target "$recipe_dir")"
