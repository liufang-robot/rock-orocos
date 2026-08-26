# Getting Started

`orocos-rock` provides the same runtime and development split through
two installation paths:

| Need | Recommended path | Result |
|---|---|---|
| Use Orocos on a supported Linux or Windows host | Install the Pixi packages | A relocatable environment with no source workspace |
| Change RTT, OCL, OroGen, or package selection | Build from source | An Autoproj or native Windows development workspace |
| Build for Xenomai 3 | Build from source | A target-specific prefix tied to the host Xenomai installation |

## Install Packages

Add the public channel and install the development SDK:

```bash
pixi workspace channel add https://prefix.dev/liufang-robot/orocos
pixi workspace channel add conda-forge
pixi add orocos-dev==0.1.3
```

The SDK installs the exact matching `orocos` runtime. Linux users source
`$CONDA_PREFIX/dev-env.sh`; Windows users dot-source
`$env:CONDA_PREFIX\Library\dev-env.ps1`. See
[Pixi And Conda Packages](./conda-packages.md) for runtime-only installs,
activation, and verification.

## Build From Source On Linux

From the repository root:

```bash
./tools/setup.sh --prefix ~/.orocos --target gnulinux
source ~/.orocos/dev-env.sh
```

The setup wrapper installs Autoproj, resolves host dependencies, builds the
selected package layout, exports the environment scripts, and validates the
prefix. It may request `sudo` for operating-system packages.

Use [User Workflows](./user-guide.md) for updates, runtime activation, and OPC
UA deployment.

## Build From Source On Windows

Install Pixi and Visual Studio 2022 C++ Build Tools, then run:

```powershell
pixi install --locked
pixi run --locked windows-build
. .\install\windows-msvc\dev-env.ps1
```

The [Windows Native Build](./windows-msvc-handoff.md) chapter defines the
supported compiler, dependency, environment, and validation contract.

## Choose An Environment

- Source `env.sh` or `env.ps1` for deployed runtime tools.
- Source `dev-env.sh` or `dev-env.ps1` for headers, CMake
  metadata, OroGen, Typegen, and downstream component development.
- Do not use paths inside this repository as downstream dependency paths. The
  installed prefix is the public boundary.
