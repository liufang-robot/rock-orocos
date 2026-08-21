# Windows Native Build

The native Windows path builds a 64-bit MSVC Orocos runtime and development
prefix with Orocos target `win32`. Pixi supplies the locked tools and
libraries; Visual Studio 2022 C++ Build Tools supplies the compiler.

## Supported Stack

The build covers:

- `farbot`, `rtlog-cpp`, RTT, and required RTT plugins;
- `open62541`, `open62541pp`, and `rtt_opcua`;
- OCL deployer, RTT scripting, OPC UA deployer, and OPC UA TaskBrowser;
- Typelib, its Ruby extension, and `rtt_typelib`; and
- utilrb, metaruby, OroGen, and Typegen.

The acceptance test imports a C++ header through CastXML, generates and builds
a component, typekit, Typelib transport, and deployer, and separately
generates and imports a standalone Typegen project.

## Prerequisites

- 64-bit Windows
- Pixi
- Visual Studio 2022 C++ Build Tools with the C++ workload

The root Pixi workspace contains both `win-64` and
`linux-64` lock entries. The `windows-build` task remains
Windows-only.

## Build And Activate

```powershell
pixi install --locked
pixi run --locked windows-build

pixi shell --locked
. .\install\windows-msvc\dev-env.ps1
orogen --help
typegen --help
```

The task uses:

| Content | Default path |
|---|---|
| Disposable source and builds | `build/windows-msvc` |
| vcpkg checkout and dependencies | `build/vcpkg` |
| Validated installed prefix | `install/windows-msvc` |
| Runtime activation | `install/windows-msvc/env.ps1` |
| Development activation | `install/windows-msvc/dev-env.ps1` |

Runtime-only use does not require an active Pixi shell:

```powershell
. .\install\windows-msvc\env.ps1
deployer-opcua-win32.exe --check --no-consolelog
```

Development uses the Pixi shell because Ruby, CastXML, CMake, and the compiler
remain environment-managed dependencies.

## Source-Locked Build

Release candidates use the shared source lock:

```powershell
pixi run --locked windows-build -- `
  -SourceLockPath packaging/source-lock.json
```

This mode rejects individual repository/ref overrides and verifies every
checkout's final commit. For maintenance-fork work, omit the source lock and
pass repository/ref parameters to `windows-build`.

## Packages

The `win-64` package build uses:

```powershell
pixi install --locked -e package
pixi run --locked package-render
pixi run --locked package-build
```

See [Pixi And Conda Packages](./conda-packages.md) for consumption and
[Packaging And Release](./release-guide.md) for CI and publication.

## Target Differences

- `win32` defaults to the Typelib generator transport.
- CORBA and mqueue are disabled.
- The installed prefix bundles the dependency SDK required by downstream
  builds.
- OCL TaskBrowser uses vcpkg's readline implementation for completion,
  editing, and history.
- Runtime DLL discovery is encoded by `env.ps1`; downstream users
  do not depend on vcpkg checkout paths.

The Windows contract is native development support, not byte-for-byte parity
with `gnulinux`.

## Console And OPC UA

History defaults to `.tb_history` in the launch directory. Set
`ORO_TB_HISTFILE` to override it. Use `quit`, or Ctrl+Z
followed by Enter, for end-of-input in a native Windows console.

The OPC UA endpoint behavior and security baseline match the
[Native OPC UA Reference](./opcua-reference.md). Windows executables use the
`-win32.exe` suffix where the Linux tools use `-gnulinux`.
