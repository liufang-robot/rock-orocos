# Pixi And Conda Packages

Release workflows are configured to publish `orocos` and `orocos-dev` for
`linux-64` and `win-64` to Prefix.dev. A platform is installable after its
release workflow has populated the corresponding channel subdirectory.

| Package | Description | Choose it when |
|---|---|---|
| `orocos` | RTT and OCL runtime, scripting, type transports, and native OPC UA deployer and TaskBrowser tools | The environment only runs existing components and deployments |
| `orocos-dev` | Headers, build metadata, OroGen, Typegen, and the exact matching `orocos` runtime | The environment generates or builds components and typekits |

The development package pins the full runtime build string, not only its
version. This prevents headers and generators from resolving against a
different runtime build.

## Automatic Pixi Activation

For a new downstream workspace, copy the complete
[`examples/pixi-consumer`](https://github.com/liufang-robot/rock-orocos/tree/main/examples/pixi-consumer)
example. For an existing workspace, merge the channel, platform, dependency,
and activation entries below into its `pixi.toml`, then copy the example's
`scripts` directory. Do not overwrite an existing manifest.

```toml
[workspace]
channels = ["https://prefix.dev/liufang-robot/orocos", "conda-forge"]
platforms = ["linux-64", "win-64"]

[dependencies]
orocos-dev = "==0.1.0"

[target.unix.activation]
scripts = ["scripts/activate-orocos.sh"]

[target.win.activation]
scripts = ["scripts/activate-orocos.ps1"]
```

Runtime-only users replace `orocos-dev = "==0.1.0"` with
`orocos = "==0.1.0"` under `[dependencies]`. Unix consumers retain
`[target.unix.activation]` so the project wrapper can source `env.sh`.

Runtime-only Windows consumers do not need `[target.win.activation]`.
The `orocos` package installs `Library\env.bat` and the
`etc\conda\activate.d\orocos-activate.bat` package hook, which Pixi and Conda
run automatically through `cmd.exe`. The hook establishes the complete
runtime environment before `pixi run` or `pixi shell` starts a process.

The example keeps `[target.win.activation]` because it installs `orocos-dev`.
Its project wrapper dot-sources `Library\dev-env.ps1` to add OroGen, Typegen,
and build dependencies after package-owned runtime activation. The wrappers
and package hook set the paths described by the
[Install Contract](./install-contract.md), are relocatable with the Conda
environment, and do not require this repository's Autoproj workspace.

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

From `cmd.exe`, the equivalent explicit runtime entrypoint is:

```bat
call "%CONDA_PREFIX%\Library\env.bat"
```

## Local Package Testing

Before public artifacts are available, package maintainers can build and index
the local channel:

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
