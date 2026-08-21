# Dual-Organization Publication

This page defines how the maintained Orocos/Rock sources are published to both
`liufang-robot` and `OptimalCNC` while keeping each organization's root
workspace independently buildable.

## Decision

`liufang-robot` is the canonical development source for this workspace.
Maintained package commits are first published there and then synchronized to
the corresponding default branches in `OptimalCNC`.

`OptimalCNC/rock-orocos` is a self-contained distribution root, not an exact
Git mirror. Its package selections point to `OptimalCNC` forks, while the
`liufang-robot/rock-orocos` selections point to `liufang-robot` forks.

The official `open62541`, `open62541pp`, and `utilrb` selections remain on
their upstream repositories in both organizations.

## Prefix Channels

| Root repository | Upload reference | Consumer URL |
|---|---|---|
| `liufang-robot/rock-orocos` | `liufang-robot/orocos` | `https://prefix.dev/liufang-robot/orocos` |
| `OptimalCNC/rock-orocos` | `metanc/orocos` | `https://prefix.dev/metanc/orocos` |

The canonical `liufang-robot/orocos` channel authorizes only
`liufang-robot/rock-orocos` and the exact
`linux-packages.yml` and `windows-packages.yml` workflow
files through Repository Access. The tracked workflows reject publication
from the `OptimalCNC` mirror. Publishing `metanc/orocos`
would require a separately reviewed organization-specific workflow and
channel authorization; it is not enabled by the canonical configuration.

## Repository Matrix

| Workspace package | `liufang-robot` repository | `OptimalCNC` repository | Published branch |
|---|---|---|---|
| Root workspace | `rock-orocos` | `rock-orocos` | `main` |
| `farbot` | `farbot` | `farbot` | `master` |
| `rtlog-cpp` | `rtlog-cpp` | `rtlog-cpp` | `main` |
| `rtt` | `rtt` | `rtt` | `dev` |
| `rtt_opcua` | `rtt_opcua` | `rtt_opcua` | `dev` |
| `ocl` | `ocl` | `ocl` | `dev` |
| `orogen` | `tools-orogen` | `tools-orogen` | `dev` |
| `typelib` | `tools-typelib` | `tools-typelib` | `dev` |
| `utilmm` | `utilmm` | `utilmm` | `dev` |
| `rtt_typelib` | `tools-rtt_typelib` | `tools-rtt_typelib` | `dev` |

All organization-owned repositories are public. Remote feature branches are
not part of this publication flow.

## Package Publication

Normal feature work still follows the repository's pull-request and review
rules. Publication begins only after the reviewed commits have been integrated
into the intended local default branch. Synchronizing that approved branch to
the organization remotes does not create a remote feature branch.

For each maintained package:

1. verify the local default branch and its tests;
2. fetch both organization remotes;
3. reject a non-fast-forward update instead of rewriting remote history;
4. push the verified default branch to `liufang-robot`;
5. fast-forward the same package commit to `OptimalCNC`;
6. verify that both remote branch names resolve to the intended commit.

The canonical local checkout tracks the `liufang` remote. Synchronization to
the `optimalcnc` remote is explicit because one local branch cannot track two
upstreams simultaneously. Autoproj's managed `autobuild` remote is left under
Autoproj control.

If an OptimalCNC branch ever contains unique commits, synchronization stops for
review. A reviewed merge may preserve both histories; force-pushing or deleting
the unique commits is not allowed by this workflow.

## Root Workspace Policy

The root repositories intentionally differ by one organization policy lineage.
The `liufang-robot/main` version selects `liufang-robot` for every maintained
fork. The `OptimalCNC/main` version selects `OptimalCNC` for the same packages.

The organization-specific root change updates these live policy surfaces
together:

- `autoproj/overrides.yml`, which controls the sources used by Autoproj;
- `tools/check-autoproj-policy.rb`, which enforces those source selections;
- `docs/src/package-policy.md`, which names the active organization source.

Canonical changes are merged into the OptimalCNC lineage without removing its
organization policy commit. The OptimalCNC policy checks must pass after every
such merge.

## Validation Gates

Before publishing:

- all maintained worktrees must be free of uncommitted source changes;
- generated build directories and TaskBrowser history must remain untracked;
- package tests and root repository policy checks must pass;
- both root policy variants must pass `tools/check-autoproj-policy.rb`;
- `git diff --check` must pass for every commit being published.

After publishing, query every remote default branch and compare its commit ID
with the expected local commit. A rejected push, missing permission, branch
protection rule, or unexpected remote commit stops the operation for review.
