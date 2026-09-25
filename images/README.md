# Debian 13 Xenomai images

Build a Debian 13 disk with the pinned Cobalt kernel and SDK, the Orocos
Xenomai toolchain, EtherLab userspace library, and RunsOn bootstrap.

The [image guide](../docs/src/xenomai-image.md) is the maintained entrypoint
for source inputs, installed prefixes, local builds, fresh-VM validation,
publication, and retained evidence.

- `build/`: Packer/QEMU build and committed source staging.
- `recipes/`: ordered installation scripts and fixed inputs.
- `validate/`: boot and installed-prefix acceptance as the runner user.
- [publish/](publish/README.md): AWS publication, retention, and recovery.

The builder, publisher, and `execution/cobalt/` baseline derive from
`OptimalCNC/runs-on-ami-example` at
`b80fab7269c94ec2efad9b5d672564ddc6cf9fac`; its MIT notice is retained in
[LICENSE](LICENSE).
