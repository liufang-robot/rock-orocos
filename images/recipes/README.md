# Debian 13 installation recipe

`recipe.json` fixes the Debian 13 genericcloud disk and its SHA-512 checksum,
and lists the provisioning steps in execution order:

1. `install-runs-on.sh` installs the runner account and verified, pinned
   Actions runner and RunsOn bootstrap binaries.
2. `install-tools.sh` installs Debian build and consumer tools, including GCC 14.
3. `xenomai-cobalt/provision.sh` builds the specified Linux/Dovetail and Cobalt
   sources with the supplied `kernel.config`, then installs the kernel and SDK.
4. `etherlab/provision.sh` builds and installs real IgH userspace headers and
   libraries at `/opt/etherlab`, with kernel modules and services disabled.
5. `orocos/provision.sh` builds the committed, source-locked Orocos Xenomai
   toolchain at `/opt/orocos` as the runner user.
6. `record-image.sh` records source identities, effective kernel configuration
   digest, installed prefixes, and Debian package versions.

These scripts run as root inside a disposable build VM. The builder stages
only committed recipe files and a checksummed source archive. Compilation
outputs remain on a disposable disk. Runtime acceptance runs after a fresh
boot; `tools/setup.sh` is not used during provisioning because it also runs
runtime tests.

See the [image guide](../../docs/src/xenomai-image.md) for build commands and
the [Cobalt recipe](xenomai-cobalt/README.md) for kernel installation details.
