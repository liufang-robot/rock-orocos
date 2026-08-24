# Install Contract

This page defines the contract that `orocos-rock` exports to downstream Orocos
users.

## Output Model

`orocos-rock` should install to one prefix.

Recommended default:

```text
~/.orocos
```

The exact prefix may be configurable later, but the contract should stay the
same regardless of location.

The native Windows Pixi build uses `install/windows-msvc` by default and
exports the same runtime/development split through `env.ps1`, `env.bat`, and
`dev-env.ps1`.

The published `orocos` and `orocos-dev` packages map the
same split into a Pixi/Conda environment. On Linux, the scripts are installed
at the environment root. On Windows, they are installed below
`Library`. Package relocation may change the prefix location but not
the behavior described here.

## Required Outputs

The installed prefix must provide:

- Orocos runtime tools
- OCL deployer support
- native RTT OPC UA libraries, type transport, deployer, and TaskBrowser client
- the target-specific RTT mqueue transport for Linux targets
- RTT scripting support
- generator tools needed for typekit and component development
- environment setup for runtime use
- environment setup for development use

Autoproj installs toolchain packages below the prefix's `toolchain` directory.
For `gnulinux` and `xenomai`, respectively, the required mqueue transport is:

- `toolchain/lib/orocos/gnulinux/types/librtt-transport-mqueue-gnulinux.so`
- `toolchain/lib/orocos/xenomai/types/librtt-transport-mqueue-xenomai.so`

The prefix does not include RTT or OCL CORBA libraries and executables in
either target build.

The installed `deployer-opcua` binds all IPv4 interfaces by default at
`opc.tcp://0.0.0.0:4840/rtt`. Downstream clients connect through a concrete
server IPv4 address. The CLI exposes `--opcua-port` and
`--opcua-endpoint-path`, but no listener-address override.

The selected Orocos target is part of the prefix contract. The default target
is `gnulinux`; a Xenomai build must be requested explicitly with
`--target xenomai`. The default prefix remains `~/.orocos` unless the caller
passes a different `--prefix`.

## Environment Scripts

### `env.sh`

Runtime-oriented environment.

It should make a shell ready for:

- the selected target deployer, such as `deployer-gnulinux` or
  `deployer-xenomai`
- the selected target OPC UA tools, such as `deployer-opcua-gnulinux` and
  `ctaskbrowser-opcua-gnulinux`
- Orocos component and plugin discovery
- running existing `.ops` scripts

It should not require source-tree state from this workspace or any downstream
project to be useful.

Bootstrap, update, and build failures must not replace an existing installed
`env.sh` or `dev-env.sh` with an Autoproj workspace forwarding script. The
public entrypoints remain usable until a successful install exports their
replacement.

### `dev-env.sh`

Development-oriented environment.

It should extend the runtime environment with the extra tooling needed for:

- `orogen`
- `typegen`
- Typelib-related generators
- configuring and building downstream Orocos packages

This is the script downstream projects should source before configuring their
Orocos-facing packages.

`dev-env.sh` is also responsible for making the Ruby-based generator stack
usable from the installed prefix. Downstream users should expect the sourced
shell to find `orogen`, `typegen`, and their Ruby dependencies without any
access to the internal autoproj workspace.

## Downstream Assumptions

Downstream projects may assume that, after sourcing `dev-env.sh`, the shell can:

- find RTT and OCL build dependencies
- generate new typekits
- configure CMake packages that use Orocos macros
- build downstream Orocos packages against the installed toolchain
- resolve the Ruby gems needed by `orogen` and related generators

Downstream projects should not assume:

- direct access to the internal autoproj workspace layout
- specific checkout paths of third-party packages
- direct modification of the toolchain workspace during normal product builds
- a particular installed gem directory layout under the prefix

## Prefix Stability Rule

The install prefix is the public contract.

The internal autoproj workspace is not.

That means:

- the prefix layout should change rarely
- `OROCOS_PREFIX` is the public environment variable for the installed prefix
- `env.sh` and `dev-env.sh` should remain the stable entrypoints
- downstream builds should avoid depending on workspace-internal paths

The same rule applies to Ruby tooling: downstream users may rely on the
presence of generator commands after sourcing `dev-env.sh`, but should not
depend on how gems are staged inside the prefix.

`env.sh` exports the selected target through `OROCOS_TARGET`. Downstream
projects should treat this as a property of the installed prefix, not as a
workspace-internal setting.

## Development Environment Guarantees

After sourcing `dev-env.sh`, the shell must be usable as a standalone toolchain
environment. At minimum, the script must:

- prepend the installed toolchain executables to `PATH`
- expose the installed prefix through `CMAKE_PREFIX_PATH`
- expose pkg-config metadata through `PKG_CONFIG_PATH`
- expose Orocos plugin discovery paths for runtime tools
- expose the installed Typelib loaders through `TYPELIB_PLUGIN_PATH`
- expose the installed Ruby generator stack through `GEM_HOME`, `GEM_PATH`, or
  equivalent `RUBYLIB` setup
- expose CMake config packages for installed internal toolchain dependencies,
  including `farbot` and `rtlog-cpp`, so downstream configure checks can use
  the same prefix contract

Those variables are part of the behavior contract of `dev-env.sh`, even if the
exact internal directory layout changes later.

On Windows, `env.ps1` and `dev-env.ps1` provide the corresponding PowerShell
contracts. Runtime-only use through `env.ps1` does not require an active Pixi
environment when using the workspace-built prefix. Development through
`dev-env.ps1` does: it exposes the prefix-local generator gems, Typelib
plugins, and bundled dependency SDK, while Ruby, CastXML, CMake, and the
compiler remain Pixi-managed dependencies. The packaged equivalent is an
environment containing `orocos-dev`; that package declares those Pixi-managed
dependencies and installs the exact matching `orocos` runtime. The `win32`
generator defaults to the Typelib transport; CORBA and mqueue are not part of
the Windows contract.

The packaged Windows runtime additionally provides `Library/env.bat` for
explicit `cmd.exe` activation and
`etc/conda/activate.d/orocos-activate.bat` for automatic Pixi/Conda package
activation, plus `etc/conda/deactivate.d/orocos-deactivate.bat` for automatic
deactivation. Both runtime activation entrypoints derive `OROCOS_PREFIX` from
the installed `Library` prefix, set `OROCOS_TARGET=win32`, and expose the same
runtime and component discovery paths. The package hook calls
`Library/env.bat --conda`; that mode preserves the standard Pixi/Conda `PATH`
as a suffix, prepends the single Orocos plugin directory required for Windows
DLL resolution, and applies the Orocos-specific discovery environment.
Pixi/Conda already places `Library\bin` on `PATH`.
Explicit `Library/env.bat` activation applies the standalone runtime paths with
case-insensitive deduplication. The hook does not duplicate the environment
model or invoke PowerShell.

The packaged Linux runtime similarly provides
`etc/conda/activate.d/orocos-activate.sh`. Pixi and Conda source this package
hook automatically, and the hook sources the relocatable
`$CONDA_PREFIX/env.sh`. Runtime-only Linux consumers therefore do not need a
project `[target.unix.activation]` wrapper. Its paired
`etc/conda/deactivate.d/orocos-deactivate.sh` hook reverses the package-owned
runtime environment.

Package activation preserves the exact prior set/unset state of Orocos
discovery variables and does not overwrite that backup on repeated
activation. Deactivation restores those variables, removes only Orocos
`PATH` entries that the matching package hook introduced, retains
pre-existing entries, and clears all internal lifecycle state. It is
idempotent on both platforms. The explicit standalone `env.sh`, `env.bat`,
and `env.ps1` entrypoints do not create this lifecycle state and retain their
existing behavior.

On both platforms, `orocos-dev` receives the runtime hook through its exact
dependency on `orocos`. Development setup remains the responsibility of
`dev-env.sh` or `dev-env.ps1` and the downstream project's platform-specific
Pixi activation wrapper. The Linux package does not install a development
hook or automatically source `dev-env.sh`; there is no `dev-env.bat`
contract on Windows.

## Validation Expectations

An install is considered minimally valid when it can:

1. source `env.sh`
2. run the deployer for the selected target
3. find the target-specific RTT mqueue transport under
   `toolchain/lib/orocos/$OROCOS_TARGET/types`
4. resolve the native OPC UA transport through pkg-config
5. run the target OPC UA deployer and TaskBrowser client version checks
6. source `dev-env.sh`
7. run `orogen`
8. run `typegen`
9. support a downstream Orocos configure step

The Windows acceptance additionally imports a C++ header through CastXML,
resolves an installed task library, typekit, and Typelib transport through the
OroGen pkg-config loader, and runs the generated deployer. It also uses
`typegen` directly to generate a standalone typekit and Typelib transport,
runs the generated regeneration target, builds and installs the result, and
imports the installed typekit in the deployer.

The installed-prefix OPC UA acceptance additionally starts the deployer,
proves that `opcua.start()` exposes an endpoint without publishing a component,
then explicitly proves selected and complete Deployer/component publication.
It verifies that unselected deterministic NodeIds return `BadNodeIdUnknown`,
that a selector failure returns complete diagnostics, and that selected nodes
are usable from separate direct-client and TaskBrowser processes through a
non-loopback IPv4 address. It also proves the listener is wildcard IPv4, the
port closes after deployer shutdown, and the run has no home-prefix
contamination.

## Relationship To Downstream Projects

Downstream projects should consume `orocos-rock` exactly like a third-party
dependency prefix.
