# Pixi Consumer Activation And Prefix Channel Description

## Goal

Make a downstream Pixi workspace activate an installed Orocos package without
requiring a second manual shell command:

- `orocos` selects the runtime environment script
- `orocos-dev` selects the development environment script

Also define the public Prefix.dev channel description and document how a
maintainer applies it.

## Boundary

Pixi activation belongs to the downstream workspace manifest. A Conda package
cannot add `target.unix.activation` or `target.win.activation` to the manifest
that consumes it. The repository will therefore provide a complete consumer
example that downstream projects can adopt.

The package-building workspace remains unchanged by this activation. It builds
the packages and must not try to source files from packages that it does not
install.

## Consumer Example

Add an `examples/pixi-consumer` workspace containing:

- a `pixi.toml` with the public Orocos and conda-forge channels
- `target.unix.activation` pointing at a project-relative shell script
- `target.win.activation` pointing at a project-relative PowerShell script
- an `orocos-dev` dependency as the default development example

The documentation will state that runtime-only consumers replace `orocos-dev`
with `orocos`; the activation entries and wrapper scripts stay identical.

## Activation Selection

The Unix wrapper inspects the active Pixi prefix in this order:

1. Source `$CONDA_PREFIX/dev-env.sh` when it exists.
2. Otherwise source `$CONDA_PREFIX/env.sh` when it exists.
3. Fail with a concise diagnostic when neither file exists.

The Windows wrapper applies the same rule to
`$env:CONDA_PREFIX\Library\dev-env.ps1` and
`$env:CONDA_PREFIX\Library\env.ps1`.

This file-presence rule maps directly to the package split. `orocos-dev`
depends on the exact matching `orocos` build, so both runtime and development
scripts exist in a development environment. Selecting `dev-env` first is
therefore required. The development script already includes the runtime
environment.

The wrappers will not silently fall back when `CONDA_PREFIX` is absent. That
indicates they were invoked outside a Pixi environment and should be reported
as a configuration error.

## Documentation

Update the package guide so its primary workflow is `pixi shell`, with no
manual source or dot-source command when the consumer activation entries are
present. Retain the explicit commands as a troubleshooting and non-Pixi
fallback.

Document that activation is a consumer-workspace feature, not metadata carried
inside the uploaded package.

## Prefix.dev Channel Description

Use this channel description:

> Standalone Orocos RTT runtime and development toolchain for Linux and
> Windows, including OCL, OroGen, Typegen, and native OPC UA.

Package `about.summary` and `about.description` remain in both recipes. They
describe individual package records and do not set the channel profile.

Prefix.dev channel profile metadata is configured through the authenticated
channel settings. The release guide will record the exact text and a
maintainer verification step. Package publication CI will not mutate channel
settings because its OIDC permission is intentionally limited to package
publication.

## Validation

Automated checks will prove that:

- the example manifest parses with the locked Pixi version
- the Unix target selects the shell wrapper and the Windows target selects the
  PowerShell wrapper
- a runtime-only prefix activates `env.sh`
- a development prefix activates `dev-env.sh` instead of `env.sh`
- activation fails when `CONDA_PREFIX` or both installed scripts are missing
- existing clean Linux and Windows package-consumer checks use the wrappers
  and still pass
- documentation structure, package recipes, and CI policy remain valid

The Prefix.dev channel description itself requires authenticated external
state, so repository validation can check the documented source of truth but
cannot prove the live channel setting during an untrusted pull request.

## Non-Goals

- injecting activation configuration into arbitrary downstream manifests
- adding Conda `activate.d` hooks that Pixi did not request
- changing the runtime/development package split
- granting broader publication credentials to CI
