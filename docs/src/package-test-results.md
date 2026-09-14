# Package Verification Matrix

This page defines the maintained package and installed-prefix verification
surface. It is a repeatable contract, not a record of one local run.

The package-test workflow covers Ubuntu 22.04, Ubuntu 24.04, and Debian
13/Trixie. Package steps return their real exit status even while a workflow is
configured as non-required. OPC UA and HTTP jobs do not allow failures and
additionally run installed-prefix acceptance; the other package jobs remain
experimental.

## Package Gates

The package entries use the public maintenance branches selected in
`autoproj/overrides.yml`.

| Package gate | Maintained coverage | Gate status |
|---|---|---|
| `utilmm` | `Suite` from `utilmm_testsuite` | Cross-distribution package workflow |
| `typelib-cxx` | `CxxSuiteInstalledPlugins` and `CxxSuiteLocalPlugins` | Cross-distribution package workflow |
| `rtt-typelib` | `rtt-typelib`, `get_marshaller_for_test`, and `rtt_typelib-gnulinux` metadata | Cross-distribution package workflow |
| `rtt-core` | `main-test`, `list-test`, `core-test`, `task-test`, `mqueue-test`, `mqueue_archive_test`, `cyclic_ports_test`, `cyclic_dataflow_test`, and `scripting_test` | Maintained selected subset |
| `rtt-opcua` | Target-correct maintained Xenomai subsets of `rtt_opcua_*_test`, split `ocl_opcua_deployment_*`, and TaskBrowser argument cases; OPC UA deployer/browser targets; `rtt_opcua-xenomai` plus installed OCL pkg-config metadata; and installed-prefix selective-publication acceptance | Xenomai maintained gate; GNU/Linux `rtt_opcua_*_test`, `rtt_opcua-gnulinux` metadata, and installed-prefix LAN verification pending |
| `ocl-basic` | `timer`, `taskb`, `ocl_cyclic_timer`, and `taskbrowser_value_renderer_test` (primitive, custom, nested, indexed, and bounded array output) | Cross-distribution package workflow; renderer also runs in Linux and Windows OCL CI |
| `rtt-http` | JSON/REST and HTTP/TLS SDK contracts; combined OCL HTTP/OPC UA deployment; installed service stop/restart; separately built custom JSON codec | Required cross-distribution package workflow; native Windows SDK and service CI |
| `ocl-integration` | `deploy`, `testlogging`, `report`, `tcpreport`, `ocl_cyclic_deployment`, `ocl_cyclic_reporting`, and optional `ncreport` | Cross-distribution package workflow |

The optional NetCDF reporting case runs only when NetCDF is available. The
interactive state-machine browser remains outside the maintained OCL subset.

## Installed-Prefix Acceptance

An installed-prefix acceptance run must:

- source `env.sh` and `dev-env.sh` from an isolated prefix;
- run the deployer and native OPC UA commands for the selected target;
- use both `deployer-opcua` and ordinary `deployer` with the component-owned
  `opcua` service, including the same client and TaskBrowser acceptance;
- verify target-specific mqueue and OPC UA transport discovery;
- prove endpoint-only `opcua.start()` and an initially absent Deployer;
- explicitly publish selected Deployer and component surfaces, then separately
  prove complete Deployer/component publication remains available and strict;
- prove unselected-resource NodeIds are absent with
  `BadNodeIdUnknown`, and selector failures return every diagnostic;
- verify direct-client and TaskBrowser inspection, updates, and operation calls
  through a non-loopback IPv4 address;
- verify wildcard IPv4 listening, socket closure after shutdown, and no CORBA
  or home-prefix contamination; and
- configure a downstream Orocos package.

HTTP acceptance loads `rtt_http` and the `http` service through the ordinary
deployer alongside OPC UA, then stops and restarts HTTP. The SDK check builds
an ordinary RTT typekit/component and a separate JSON transport against the
installed prefix. It verifies composite assignment and retained output reads
without an OPC UA codec dependency. Runtime packages contain the HTTP libraries
and plugins; development packages supply the public headers and build metadata.

The GNU/Linux mqueue acceptance requires
`toolchain/lib/orocos/gnulinux/types/librtt-transport-mqueue-gnulinux.so` with
`ENABLE_MQ=ON` and `ENABLE_CORBA=OFF`.

## Target Status

- GNU/Linux package and installed-prefix acceptance is maintained.
- Xenomai compilation and selected package tests are maintained; target-machine
  real-time acceptance remains a separate hardware gate.
- Cross-distribution OPC UA package results become authoritative only when the
  repository workflow runs them as required checks.

## Known Limits

- A non-returning RTT operation can delay endpoint shutdown because its
  component lease and invocation storage must not be released early.
- Third-party open62541 and open62541pp unit suites are not part of this
  workspace's maintained gate.
- Target-machine timing and EtherCAT behavior require the Xenomai validation
  described in [Xenomai 3 Integration](./xenomai3-integration.md).
- OPC UA PubSub port mapping and downstream application migration are separate
  contracts.
