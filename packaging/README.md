# Conda Packaging

This directory owns the Rattler recipes and smoke tests for the
`liufang-robot/orocos` Prefix.dev channel.

The canonical package contract, CI behavior, OIDC publication gate, channel
setup, and release sequence are documented in
[Packaging And Release](../docs/src/release-guide.md). Consumer installation
is documented in
[Pixi And Conda Packages](../docs/src/conda-packages.md).

## Local Linux Build

```bash
pixi install --locked -e package
pixi run --locked linux-package-render
pixi run --locked linux-package-build
```

Artifacts are written below `conda/output/linux-64` and the local
channel root is `conda/output`.

## Local Windows Build

```powershell
pixi install --locked -e package
pixi run --locked package-render
pixi run --locked package-build
```

Artifacts are written below `conda/output/win-64`.

Building and testing never publish. Only the release-gated GitHub workflows
upload verified package bundles. Published filenames are immutable; increase
the recipe build number instead of replacing an existing artifact.
