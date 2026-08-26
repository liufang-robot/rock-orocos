# Packaging And Release

This chapter is the maintainer contract for producing and publishing the
`orocos` and `orocos-dev` packages.

## Build Matrix

| Platform | Recipe | Pixi tasks | Workflow |
|---|---|---|---|
| `linux-64` | `packaging/conda/recipe-linux.yaml` | `linux-package-render`, `linux-package-build` | `linux-packages.yml` |
| `win-64` | `packaging/conda/recipe.yaml` | `package-render`, `package-build` | `windows-packages.yml` |

Both recipes compile the toolchain once into a Rattler staging output, split
it into non-overlapping runtime and development artifacts, and test each
artifact in an isolated environment.

## Reproducible Sources

`packaging/source-lock.json` records the repository and exact
40-character revision for every package source. Linux package builds also pin
the Rock package set before Autoproj resolves the layout. Windows builds use
the same lock for direct native checkouts and vcpkg.

Moving branch selections remain useful for ordinary source development. A
release package is built from the lock so the retained bundle identifies the
source payload exactly.

## Compatibility Constraints

The Linux build uses Rattler's C standard-library variant with the conda-forge
glibc 2.17 baseline. Both published outputs declare `__glibc >=2.17`, and the
build rejects package-owned ELF files that reference a newer GLIBC symbol
version. Do not remove or raise this baseline without an intentional platform
support decision and matching consumer coverage.

The Linux recipe currently selects Boost `1.84.x`. Boost 1.85 removed the
numbered `boost::function` argument aliases still used by the pinned RTT
source. Lift this upper bound only after RTT uses signature traits for those
arguments and the Linux package build passes with the newer Boost line.

## CI Behavior

Pull requests, pushes to `main`, and manual runs:

1. validate source and publication policy;
2. render and solve the platform recipe;
3. build and run native package tests;
4. inspect the two package archives structurally;
5. verify exact runtime pinning and non-overlapping file sets;
6. stage `source-lock.json`, `release-manifest.json`, and
   `SHA256SUMS.txt`;
7. install both exact builds through a clean local-channel Pixi cache; and
8. install and execute both exact Linux builds again on Ubuntu 22.04; and
9. retain the verified bundle as a workflow artifact.

The Windows runtime package and clean-consumer checks invoke the real batch
hook with command echo enabled and a structured inherited `PATH` of roughly
7 KB. They require repeated activation and deactivation to finish within 30
seconds, preserve all inherited entries, avoid duplicate Orocos entries, and
emit no `__OROCOS_ROCK_PATH_` implementation commands.

These events never upload to Prefix.dev.

## Publication Gate

Publication requires all of the following:

- a published, non-prerelease GitHub Release;
- a release commit reachable from the freshly fetched protected
  `main` branch;
- repository identity `liufang-robot/rock-orocos`;
- a release tag exactly equal to `v` plus the package version;
- a verified bundle produced by the build job; and
- short-lived Prefix Repository Access through GitHub OIDC.

Only the publish job receives `id-token: write`. Workflows contain no
Prefix API key and do not use overwrite or skip-existing flags. Package
filenames are immutable; increment the build number to correct a released
artifact.

## Prefix Channel Setup

In the `liufang-robot/orocos` channel's Repository Access settings,
authorize:

- repository `liufang-robot/rock-orocos` with workflow
  `linux-packages.yml`; and
- the same repository with workflow `windows-packages.yml`.

Grant package upload permission only. Delete and lifecycle permissions are not
required.

Set the public channel description to:

> Standalone Orocos RTT runtime and development toolchain for Linux and
> Windows, including OCL, OroGen, Typegen, and native OPC UA.

Channel profile metadata is managed in Prefix.dev channel settings. Package
`about.description` fields describe individual records and do not update this
text. After saving, reopen the public channel page and verify the description
exactly matches this source of truth.

## Release Sequence

1. Update the version and build number in both recipes together.
2. Update and validate `packaging/source-lock.json`.
3. Let Linux and Windows package workflows pass on `main`.
4. Publish GitHub Release `vVERSION` at that exact commit.
5. Confirm both workflows verify and upload their platform artifacts.
6. Confirm clean runtime and development installs pass through
   `https://prefix.dev/liufang-robot/orocos`.

The Linux and Windows uploads use different Conda subdirectories and can share
the same package names, versions, and channel.
