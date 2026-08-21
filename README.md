# orocos-rock

Standalone Orocos/Rock toolchain workspace for current Linux distributions and
native Windows. It builds RTT, OCL, OroGen, Typegen, and the native RTT OPC UA
transport into one reusable runtime/development prefix.

Downstream projects consume the installed prefix or the published packages.
They do not depend on this repository's Autoproj checkout layout.

## Install With Pixi

After artifacts for the current version and platform have been published, the
complete [Pixi consumer example](https://github.com/liufang-robot/rock-orocos/tree/main/examples/pixi-consumer)
provides the Prefix.dev and conda-forge channels, `orocos-dev==0.1.0`, and
automatic activation wrappers for both Unix and Windows targets. Start from
that example:

```bash
cd examples/pixi-consumer
pixi shell
```

`orocos` is the runtime package. `orocos-dev` adds headers,
CMake/pkg-config metadata, OroGen, Typegen, and an exact dependency on the
matching runtime.

See [Pixi And Conda Packages](./docs/src/conda-packages.md) for runtime-only
installation, adopting the example in an existing workspace, manual fallback,
and Linux and Windows verification.

## Build From Source

Linux and Xenomai builds use the focused Autoproj workspace:

```bash
./tools/setup.sh --prefix ~/.orocos --target gnulinux
source ~/.orocos/dev-env.sh
```

Native Windows builds use the locked Pixi environment and Visual Studio 2022
C++ Build Tools:

```powershell
pixi install --locked
pixi run --locked windows-build
. .\install\windows-msvc\dev-env.ps1
```

CORBA is disabled on every supported target. Linux builds include the
target-specific RTT mqueue transport. Windows uses the Typelib generator
transport and does not provide mqueue.

## Documentation

The published manual is
[liufang-robot.github.io/rock-orocos](https://liufang-robot.github.io/rock-orocos/).

Build it locally through the locked documentation environment:

```bash
pixi run --locked -e docs docs-build
```

The core maintenance contracts remain at stable paths:

- [Architecture](./docs/src/architecture.md)
- [Package Policy](./docs/src/package-policy.md)
- [Install Contract](./docs/src/install-contract.md)
- [Packaging And Release](./docs/src/release-guide.md)
- [Native OPC UA Reference](./docs/src/opcua-reference.md)

Generated documentation, Autoproj state, build trees, and installed prefixes
remain untracked.
