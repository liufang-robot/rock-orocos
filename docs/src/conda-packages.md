# Pixi And Conda Packages

The Prefix.dev channel publishes two platform-native packages for
`linux-64` and `win-64`.

| Package | Description | Choose it when |
|---|---|---|
| `orocos` | RTT and OCL runtime, scripting, type transports, and native OPC UA deployer and TaskBrowser tools | The environment only runs existing components and deployments |
| `orocos-dev` | Headers, build metadata, OroGen, Typegen, and the exact matching `orocos` runtime | The environment generates or builds components and typekits |

The development package pins the full runtime build string, not only its
version. This prevents headers and generators from resolving against a
different runtime build.

## Automatic Pixi Activation

Start from the complete
[`examples/pixi-consumer`](../../examples/pixi-consumer/) example, or copy its
`pixi.toml` and `scripts` directory into a downstream workspace. The manifest
configures both platform wrappers:

```toml
[target.unix.activation]
scripts = ["scripts/activate-orocos.sh"]

[target.win.activation]
scripts = ["scripts/activate-orocos.ps1"]
```

When `orocos-dev` is installed, the wrappers prefer `dev-env.sh` on Unix or
`Library\dev-env.ps1` on Windows. With the runtime-only `orocos` package, they
choose `env.sh` or `Library\env.ps1`, respectively. The scripts set the paths
described by the [Install Contract](./install-contract.md), are relocatable
with the Conda environment, and do not require this repository's Autoproj
workspace.

Open the configured environment with:

```bash
pixi shell
```

Project activation now provides the complete Orocos environment without a
second activation command.

### Linux Verification

After automatic `pixi shell` activation of the development example, verify
the generator and runtime tools:

```bash
orogen --help
typegen --help
deployer-opcua-gnulinux --version
```

### Windows Verification

Run the corresponding checks after automatic `pixi shell` activation:

```powershell
orogen --help
typegen --help
deployer-opcua-win32.exe --check --no-consolelog
```

## Manual Fallback

Use direct script activation only when troubleshooting or working in a shell
that is not using Pixi project activation.

On Unix, activate a development package with:

```bash
source "$CONDA_PREFIX/dev-env.sh"
```

A runtime-only environment uses `source "$CONDA_PREFIX/env.sh"` instead.

On Windows, activate a development package with:

```powershell
. "$env:CONDA_PREFIX\Library\dev-env.ps1"
```

A runtime-only environment uses
`. "$env:CONDA_PREFIX\Library\env.ps1"` instead.

## Local Package Testing

Package maintainers can build and index the local channel:

```bash
pixi install --locked -e package
pixi run --locked linux-package-render
pixi run --locked linux-package-build
```

On Windows, replace the last two tasks with `package-render` and
`package-build`. The local channel root is
`packaging/conda/output`, not its platform subdirectory.

The build runs package-content checks and isolated runtime/development tests.
CI adds clean Pixi installs from the local channel before an artifact is
eligible for publication.
