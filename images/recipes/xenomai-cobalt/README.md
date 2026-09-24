# Xenomai Cobalt

This recipe integrates the pinned Xenomai source into the specified
Linux/Dovetail tree and installs its matching Cobalt SDK at `/usr/xenomai`.
Source repositories, original references, fixed commits, archive checksums,
and the input configuration checksum are recorded in `inputs.sh`.

`provision.sh` installs build dependencies and Cobalt access permissions,
then calls `build-kernel.sh`. That script verifies inputs, integrates Cobalt,
runs `olddefconfig` with GCC 14, and requires Dovetail and RTIPC support.
It installs the kernel, stripped modules, effective configuration and
initramfs, and then builds the matching userspace SDK. The supplied
`kernel.config` stays unchanged in version control.

NVMe, ext4, virtio and ENA modules are included in the initramfs. The recipe
removes the distribution kernel and updates GRUB. The newly installed kernel
is used on the next boot; no Cobalt runtime test runs in the build VM.

The `xenomai` group has GID 4242. The runner receives kernel access through
`xenomai.allowed_group`, device permissions, and PAM/systemd resource limits.
Large kernel source and debug build trees are removed from the disposable
build disk after installation.

See the [image guide](../../../docs/src/xenomai-image.md) for the complete
consumer and verification contract.
