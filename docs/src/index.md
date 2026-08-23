# orocos-rock

`orocos-rock` is a standalone distribution boundary for the Orocos
RTT runtime and Rock generator stack. It supports current Linux distributions,
Xenomai 3 source builds, and a native Windows MSVC toolchain.

The output is a relocatable package environment or one installed prefix with
two entrypoints:

| Entrypoint | Purpose |
|---|---|
| `env.sh` / `env.ps1` | Run deployers, scripts, components, typekits, and OPC UA tools |
| `dev-env.sh` / `dev-env.ps1` | Extend the runtime with headers, build metadata, OroGen, Typegen, and Ruby generator support |

## Start Here

| Reader | Chapter |
|---|---|
| Installing or evaluating the toolchain | [Getting Started](./getting-started.md) |
| Adding it to a Pixi workspace | [Pixi And Conda Packages](./conda-packages.md) |
| Running deployments or updating a source install | [User Workflows](./user-guide.md) |
| Maintaining sources, CI, or package releases | [Maintaining The Toolchain](./maintainer-guide.md) |
| Changing a public guarantee | [Contracts And Reference](./reference.md) |

## What Is Included

- Orocos RTT with scripting and the Linux mqueue transport
- OCL deployers and TaskBrowser tools
- `open62541`, `open62541pp`, and the native
  `rtt_opcua` transport
- Typelib and `rtt_typelib`
- OroGen, Typegen, utilrb, and metaruby
- environment scripts that are independent of workspace checkout paths

CORBA remains available in upstream sources but is disabled in this
distribution.

## Repository Boundary

This repository owns toolchain selection, maintenance fork policy, installed
prefix behavior, package construction, and validation. Application types,
components, deployment semantics, and product integration stay in downstream
repositories.

Planned work below `todo/` is design input and is not part of the
current install contract.
