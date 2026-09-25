# Xenomai Cobalt

This recipe integrates the pinned Xenomai source into the specified
Linux/Dovetail tree and installs its matching Cobalt SDK at `/usr/xenomai`.
Source repositories, original references, fixed commits, archive checksums,
and the input configuration checksum are recorded in `inputs.sh`.

`provision.sh` 安装构建依赖并配置 Cobalt 权限，然后调用 `build-kernel.sh`。
后者校验输入、集成 Cobalt，在基础配置上启用 `CONFIG_XENO_DRIVERS_RTDMTEST=m`，使用 GCC 14 运行 `olddefconfig`，
并要求 Dovetail、RTIPC 与 RTDM 测试模块。
It installs the kernel, stripped modules, effective configuration and
initramfs, and then builds the matching userspace SDK. The supplied
`kernel.config` stays unchanged in version control.

NVMe, ext4, virtio and ENA modules are included in the initramfs. The recipe
removes the distribution kernel and updates GRUB. The newly installed kernel
is used on the next boot; no Cobalt runtime test runs in the build VM.

The `xenomai` group has GID 4242. The runner receives kernel access through
`xenomai.allowed_group`, device permissions, and PAM/systemd resource limits.
`xenomai.supported_cpus=0xfffffffffffffffd` 保留 CPU 0 为实时 CPU，将 CPU 1 留给普通 Linux；
guest 至少需要两个 vCPU。这个划分使 `cpu_affinity` 能检查从非实时 CPU 自动迁移到实时 CPU，
并通过 `xeno_rtdmtest` 验证内核线程迁移。有效 mask 写入镜像 manifest。

Large kernel source and debug build trees are removed from the disposable
build disk after installation.

See the [image guide](../../../docs/src/xenomai-image.md) for the complete
consumer and verification contract.
