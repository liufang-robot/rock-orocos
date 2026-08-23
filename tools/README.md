# tools

This directory contains the small wrapper scripts that operate the workspace.

User entrypoints:

- `setup.sh`
- `update.sh` updates the root and configured Autoproj package sources without
  building or installing them
- `build-windows-msvc.ps1` builds and validates the native Windows RTT/OCL/OPC
  UA and OroGen development prefix; the `windows-build` Pixi task is the normal
  entrypoint. Pass `-SourceLockPath packaging/source-lock.json` to reproduce a
  release candidate from exact commits; omit it for development ref overrides.

Maintainer building blocks:

- `bootstrap.sh`
- `install.sh`
- `export-env.sh`
- `export-windows-env.ps1` writes the installed Windows `env.ps1` and
  `dev-env.ps1` activation scripts
- `install-ruby-tools.ps1` installs the Windows Ruby generator gems into the
  public toolchain prefix
- `install-autoproj.sh`
- `validate-install.sh`
- `docker-build.sh`
- `prepare-windows-conda-release.ps1` verifies package metadata, file
  separation, local channel indexes, source provenance, and checksums before
  staging the two release artifacts

Focused regression tests:

- `check-source-provenance.rb` validates canonical source repositories across
  Autoproj, the Windows source lock, and Windows build defaults
- `test-source-provenance.rb` proves source-provenance rejection behavior with
  copied policy fixtures
- `test-update.sh`
- `test-windows-source-lock.ps1` validates the complete, immutable Windows Git
  source contract and its rejection behavior
- `test-windows-conda-consumer.ps1` installs the exact runtime and development
  package builds through clean Pixi caches from a local or public channel
- `check-windows-package-ci.rb` enforces the GitHub release, OIDC, immutable
  publication, and post-publication test boundaries
- `test-windows-package-ci.rb` mutation-tests the release guard, protected-main
  ancestry gate, action pins, and release-tag command boundary
- `check-linux-glibc-compatibility.rb` rejects package-owned ELF files that
  require a newer GLIBC symbol version than the configured Linux baseline
- `test-linux-glibc-compatibility.rb` proves the GLIBC scanner's acceptance and
  rejection behavior with deterministic `readelf` fixtures
- `windows-generator-smoke/` is generated and compiled by the Windows Pixi
  build to exercise Typelib, OroGen, standalone Typegen regeneration, typekit,
  transport, and deployer support

These scripts should stay thin.

The source of truth for package policy belongs in tracked autoproj config and
repository documentation, not in ad hoc shell logic.
