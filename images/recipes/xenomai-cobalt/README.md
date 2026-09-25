# Xenomai Cobalt

This recipe integrates the pinned Xenomai source into the specified
Linux/Dovetail tree and installs its matching Cobalt SDK at `/usr/xenomai`.
Source repositories, original references, fixed commits, archive checksums,
and the input configuration checksum are recorded in `inputs.sh`.

`provision.sh` installs build dependencies and Cobalt access permissions,
then calls `build-kernel.sh`. That script verifies inputs, integrates Cobalt,
enables `CONFIG_XENO_DRIVERS_RTDMTEST=m`, runs `olddefconfig` with GCC 14,
and requires Dovetail, RTIPC and the RTDM test module.
It installs the kernel, stripped modules, effective configuration and
initramfs, and then builds the matching userspace SDK. The supplied
`kernel.config` stays unchanged in version control.

NVMe, ext4, virtio and ENA modules are included in the initramfs. The recipe
removes the distribution kernel and updates GRUB. The newly installed kernel
is used on the next boot; no Cobalt runtime test runs in the build VM.

The `xenomai` group has GID 4242. The runner receives kernel access through
`xenomai.allowed_group`, device permissions, and PAM/systemd resource limits.

The four-vCPU profile reserves CPUs 1 and 3, which share a physical core on
the measured m7i.xlarge. Linux and the runner use CPUs 0 and 2; RT tasks
explicitly select CPU 3. Cobalt supports CPUs 0 and 3 (`0x9`). The image
manifest records this profile, and fresh-boot validation rejects a CPU
topology or boot setting that violates it. See the maintained image guide
for the boot arguments and latency measurements.

CPUs 1 and 2 remain outside Cobalt's mask, allowing Smokey to verify
migration from a non-RT CPU. The test loads `xeno_rtdmtest` itself to check
kernel-thread migration as well as user-thread affinity; the module is not
preloaded during ordinary boot.

Large kernel source and debug build trees are removed from the disposable
build disk after installation.

See the [image guide](../../../docs/src/xenomai-image.md) for the complete
consumer and verification contract.
