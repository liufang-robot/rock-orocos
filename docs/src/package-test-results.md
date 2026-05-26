# Package Test Results

This page records the package-level test status while the workflow is
experimental and non-required.

The first package-test workflow runs on Ubuntu 22.04 only and keeps
`continue-on-error: true` while legacy package tests are being classified.
Package test steps now return their real exit status.

| Package test | Initial subset | Current status |
|---|---|---|
| `utilmm` | `Suite` CTest case from `utilmm_testsuite` | Passes locally after stabilizing shell expansion and socket tests in `liufang-robot/utilmm` `MetaNC` commit `f3399dc`: 1/1 CTest case. |
| `log4cpp` | Existing CTest tests | Passes locally: 12/12 CTest cases. |
| `typelib-cxx` | `CxxSuiteInstalledPlugins` and `CxxSuiteLocalPlugins` | Passes locally: 2/2 CTest cases. |
| `rtt-core` | `main-test`, `list-test`, and `core-test` | Passes locally: 3/3 selected CTest cases. `task-test` currently fails in `testAbsoluteWaitPeriodPolicy` and is deferred as timing-sensitive. CORBA and mqueue tests stay out of this subset. |
| `ocl-basic` | `timer` and `taskb` | Passes locally after restoring OCL standalone CTest macros in `liufang-robot/ocl` `MetaNC` commit `a1d2b78`: 2/2 CTest cases. Deployment, reporting, and logging tests stay out of this subset. |

Deferred test groups:

- oroGen Ruby tests, until Ruby test dependencies such as `flexmock/minitest`
  are explicitly staged.
- RTT CORBA, mqueue, and transport-sensitive tests, until their runtime
  assumptions are documented.
- RTT `task-test`, until `testAbsoluteWaitPeriodPolicy` is fixed or isolated
  from timing-sensitive CI hosts.
- Broader OCL integration tests, until their external dependency and runtime
  assumptions are documented.
