# Modernization Plan

This page records the modernization direction for the maintained Orocos/Rock
toolchain. The first goal is a repeatable C++17-compatible baseline on Ubuntu
22.04 and Ubuntu 24.04. Ubuntu 26.04 remains the next compatibility target once
the CI runtime can be validated.

## Principles

- Keep the installed prefix contract stable while internals change.
- Prefer small package-level changes that can be built and validated in CI.
- Modernize behavior behind compatibility shims before removing legacy APIs.
- Treat warning-free builds as a gate for maintained forks.
- Document type and scripting policy before changing generator behavior.

## 1. Language Standard

Target C++17 as the supported implementation and downstream-consumption
baseline.

Work items:

- declare C++17 consistently in maintained CMake packages
- default generated oroGen projects and typekits to `c++17`
- remove C++03/C++11 compatibility code only after CI proves it is unused
- replace removed or deprecated standard library APIs such as `std::auto_ptr`
- prefer standard library facilities over Boost when C++17 has a direct match
- keep ABI-sensitive RTT and typekit changes package-scoped and reviewed

Gate:

- maintained packages build on Ubuntu 22.04 and 24.04
- `tools/check-cpp17-policy.rb` verifies maintained package CMake files and
  oroGen defaults
- C++ compiler logs have no warning/deprecation matches
- installed `env.sh` and `dev-env.sh` remain backward compatible

## 2. Type System Naming

Standardize type naming so generated typekits, Typelib names, C++ names, and
script-visible names are predictable.

Work items:

- define canonical namespace and type-name rules for MetaNC types
- document how fixed-width, array, container, enum, and opaque types are named
- add generator checks that reject ambiguous or unstable type names
- provide compatibility aliases for existing deployed type names where needed
- make type-name normalization visible in generated artifacts and tests

Gate:

- type-name policy has examples for C++, Typelib, typekit, and script usage
- generator tests cover accepted names, rejected names, and compatibility aliases
- downstream packages do not need local renaming patches

## 3. Script Level

Improve the deployer/script layer without changing the operational model away
from deployer plus `.ops` files.

Work items:

- define a supported script subset and MetaNC conventions
- add checks for script loading, component creation, connection setup, and
  property assignment
- improve script errors so failed deployments point at the failing operation
- keep script APIs stable until replacement helpers are documented
- add small reusable script helpers only when repeated MetaNC scripts need them

Gate:

- representative `.ops` scripts can be checked non-interactively
- script failures are reproducible in CI logs
- deployer remains launchable from the installed runtime environment

## 4. Gates And Tests

Make CI the main compatibility gate before larger API changes.

Work items:

- run native install CI on Ubuntu 22.04 and 24.04
- fail CI on maintained-package compiler warnings
- keep Docker build validation manual until it is needed as a release artifact
- add package-level tests for changed behavior before API modernization
- archive useful build logs on CI failures

Gate:

- `tools/bootstrap.sh`, `tools/install.sh`, and `tools/validate-install.sh`
  pass in CI
- warning scan passes for `*-build.log`
- policy checks pass before install work starts
- failure logs from Autoproj and package builds are uploaded as CI artifacts
- installed runtime smoke checks prove `deployer-gnulinux`, `orogen`, and
  `typegen` are launchable from the exported environments

Package unit-test policy:

- keep the native install matrix focused on build, install, smoke, and warning
  gates
- add package unit tests in a separate workflow first, with log artifacts and
  non-required status until the legacy test behavior is understood
- start with `utilmm`, `log4cpp`, Typelib C++ tests, the stable RTT core CTest
  subset, and OCL timer/taskbrowser tests on Ubuntu 22.04
- keep RTT CORBA/mqueue tests and broader OCL deployment, reporting, and logging
  tests out of the required gate until their runtime assumptions are documented
- record current package-test results in `docs/src/package-test-results.md`
- run oroGen Ruby tests only after its test dependencies, including
  `flexmock/minitest`, are explicitly staged in CI

## 5. Memory Issues

Reduce undefined behavior and ownership ambiguity before deeper API redesign.

Work items:

- replace deprecated ownership types with `std::unique_ptr` or value ownership
- remove strict-aliasing violations and unsafe type punning
- audit raw pointer ownership in RTT, Typelib, typekits, and bindings
- add sanitizer-friendly tests for modified memory paths where practical
- avoid ABI-breaking ownership changes until call sites and downstream impact
  are mapped

Gate:

- no known strict-aliasing warnings in maintained package builds
- new ownership changes have tests or focused runtime validation
- sanitizer work is tracked separately from normal release CI if runtime cost is
  too high

## Suggested Sequence

1. Establish native CI for Ubuntu 22.04 and 24.04.
2. Fix CI-only compatibility issues exposed by newer system packages.
3. Add targeted tests around type naming and script behavior before changing
   generator APIs.
4. Modernize memory ownership and undefined-behavior hotspots package by
   package.
5. Revisit Ubuntu 26.04 once a reliable CI runtime is available.
