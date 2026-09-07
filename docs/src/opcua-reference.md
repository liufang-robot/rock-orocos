# Native OPC UA Reference

This chapter defines the native OPC UA behavior currently exported by the
installed Orocos/Rock toolchain.

> [!IMPORTANT]
> The installed endpoint listens on all IPv4 interfaces by default. It uses
> `SecurityPolicy None` and currently has no authentication or authorization;
> restrict access with network controls.

## Commands And Endpoint

- `deployer-opcua` selects the executable for `OROCOS_TARGET`.
- `ctaskbrowser-opcua URL COMPONENT` connects to a published component.
- The default listener is `opc.tcp://0.0.0.0:4840/rtt`; clients use a concrete
  server IPv4 address.
- `--opcua-port` and `--opcua-endpoint-path` select a different local endpoint.

## Component Service

`deployer-opcua` remains supported. The ordinary `deployer` can instead attach
the same implementation as a component-owned service:

```text
import("required_typekits")
import("ocl")
loadService("Deployer", "opcua")
opcua.start()
```

The plugin supports `OCL::DeploymentComponent` and its subclasses only.
Global `require("opcua")`, other component owners, and duplicate loads fail.
Loading the plugin neither starts the listener nor publishes components.
Its default endpoint is `opc.tcp://0.0.0.0:4840/rtt`, with an application name
derived from the owner. Use `deployer-opcua` and its existing CLI options when
a non-default port or endpoint path is required.

Both paths preserve the same publication API, datatype registry, and wire
model. `ctaskbrowser-opcua` works with either path. There is no service unload,
public `opcua.stop()`, or unpublish API. Published components cannot be unloaded
until final deployment teardown.

On exit, the deployer first closes admission for every deployment service,
then joins their servers and drains pending operations before tearing down
components. The existing optional `Application.shutdownDeployment` callback
keeps its earlier position. Cleanup also runs when `AutoUnload=false`.
An operation that never returns can delay final shutdown; it is not forcibly
terminated. Embedded C++ deployers may call `prepareDeploymentShutdown()`
explicitly while their owner and components are intact; destructors provide
an idempotent fallback. Subclasses must call it before destroying any of their
own resources that have been published.

## Startup And Datatype Registry

Import every required typekit and OPC UA transport plugin before the first
`opcua.start()` attempt. The first start attempt freezes the process-wide
datatype registry. `opcua.endpointUrl()` reports configuration while stopped;
`opcua.isRunning()` reports only listener startup.

`opcua.start()` is endpoint-only: it freezes the registry, starts the listener,
and creates an empty object model. It publishes no RTT component, including the
Deployer. Starting an already running endpoint is a successful no-op. A failed
startup exposes no endpoint.

## Publication API

Every component is published explicitly after startup. The OCL deployment
service provides:

```text
bool publishComponent(String component)
bool publishComponentSelected(String component, StringArray selectors)
StringArray publicationDiagnostics(String component)
StringArray unsupportedResources(String component)
```

`publishComponentSelected` is the selective API; `StringArray` is required and
must contain at least one selector. `publishComponent` remains the separate
complete-publication API. It validates the full supported interface and is
strict: one unsupported operation, property, attribute, constant, port, or
service rejects the whole component. `Server=true` does not publish a component.

For example:

```text
var StringArray deployer_selectors = StringArray(
    "operations/unloadComponent", "services/opcua/**")

opcua.start()
opcua.publishComponentSelected("Deployer", deployer_selectors)
opcua.publishComponent("diagnostic_fixture")
```

## Selectors And Resource Bundles

Selectors are canonical paths over semantic logical RTT resources, not regular
expressions.
The root forms are `operations/<operation>`, `properties/<property>`,
`attributes/<attribute>`, `ports/<port>`, and `services/<service>`, with
nested service contents below `services/<service>/...`.

- An exact selector matches that resource.
- `*` occupies a whole segment and matches exactly one segment.
- `**` occupies a whole final segment and recursively matches descendants.

Partial wildcards, regex syntax, empty segments, and a non-terminal `**` are
invalid. Every selector must match at least one logical resource, even when
other selectors match. An exact service selector chooses that service object;
use `services/<service>/**` to select its contents.

Literal segments use the same canonical percent escaping as NodeId paths:
unreserved ASCII characters are literal and every other byte is uppercase
`%HH`. A literal service named `motion/raw*`, for example, is selected as
`services/motion%2Fraw%2A/**`; the `*` inside the escaped name is not a glob.

Each selected logical resource maps as one complete atomic OPC UA node bundle,
including its required metadata and values. Service ancestors are included as
needed. A port and a same-named generated service are independent resources:
`ports/Command` does not select `services/Command/**`, and vice versa.

## Mandatory Proxy Baseline

Selected publication always includes and validates these eight root lifecycle
query operations, even if no selector names them:

```text
getTaskState
getTargetState
isConfigured
isActive
isRunning
inFatalError
inException
inRunTimeError
```

They must have proxy-compatible schemas. Mutating lifecycle operations are not
included automatically. This baseline allows `TaskContextProxy` and
`ctaskbrowser-opcua` to work against an intentionally sparse publication.

## Validation, Diagnostics, And Static Topology

Selected publication validates only the effective selected set, required
service ancestors, and mandatory baseline. Unsupported unselected resources do
not reject the attempt and do not appear in `unsupportedResources` for it.
Complete publication remains strict over the whole interface.

Selector, inventory, selected-resource, mandatory-baseline, and publication
mode or effective-set conflicts are collected before commit in deterministic
order. Native callers receive structured `PublicationDiagnostic` records; the
OCL `publicationDiagnostics(component)` operation returns their complete,
stable messages in a `StringArray`. `lastError()` supplies a concise summary.
`unsupportedResources(component)` remains the legacy unsupported-resource
view, so callers should use `publicationDiagnostics` when they need selector
or topology failures. A failed publication creates no component subtree.

Publication is static. Repeating publication of the same component instance,
mode, and normalized effective resource set is a successful no-op; selector
order, duplicates, and overlaps do not change that identity. Switching between
complete and selected modes, changing the effective set, or replacing the
component instance fails. If a wildcard would match a different live interface,
the new topology also fails. Apply those changes by restarting the endpoint or
process; there is no public unpublish, replacement, or live policy update.

## Publication And Authorization

Publication controls whether a resource exists in the endpoint. Authorization,
when added later, controls whether a session may browse, observe, write, or
call an existing resource. Authorization cannot grant access to an unselected
resource because no NodeId exists for it.

Resources added after publication are not added to the endpoint. There is no
public unpublish or replacement operation, and the Deployer rejects unloading
a published component while the endpoint exists.

## RTT Interface Mapping

The object model recursively maps root and nested services. Non-empty
`Operations`, `Properties`, `Attributes`, `Ports`, and `Services` categories
are published; empty category objects are omitted. Empty RTT services remain
visible so their identity and documentation are preserved.

- operations become OPC UA Methods;
- properties become readable and, when supported by RTT, writable Variables;
- attributes become Variables with RTT mutability preserved;
- constants are read-only Variables;
- ports become metadata Objects with one direction-specific sample Variable;
- nested services use the same recursive mapping; and
- generated RTT port services remain available below their owning service.

## Port Contract

Each supported port has an Object below `Ports/<name>`. Its `type` and
`description` children are read-only String Variables. Its read-only
`direction` child is a scalar `Int32`: input is `0` and output is `1`.

The canonical sample surface is a child Variable named `value`. Its OPC UA
datatype and value rank exactly match the registered RTT type protocol:

| RTT port | `value` access | Behavior |
|---|---|---|
| Input | `CurrentRead \| CurrentWrite` | Each valid OPC UA Write attempts one delivery to the RTT input port. |
| Retaining output | `CurrentRead` only | Read or monitor the latest retained RTT sample without consuming it. |
| Non-retaining output | absent | No canonical sample Variable is published. |

Input `value` reads return the last OPC UA sample successfully delivered to the
RTT input port. Before the first successful delivery, Read and monitoring
return `BadWaitingForInitialData`. Every valid Write still attempts one RTT
delivery, including an equal value; failed Writes do not replace the readback.
A type or rank mismatch returns `BadTypeMismatch`. A successful Write means
that the bridge accepted delivery to the RTT port. The readback is bridge-owned
command state, not component consumption, acknowledgement, or process state,
and does not mean that component logic consumed, processed, or acted on the
sample.

Retaining output `value` returns `BadWaitingForInitialData` until the first
sample exists. Later reads are non-consuming and return the current retained
sample. This is a latest-state contract: intermediate samples may be coalesced
or missed. It does not project RTT connection policy, FIFO depth, buffering,
locking, transport, or other QoS into OPC UA.

There are no canonical `Ports/<name>/read` or `Ports/<name>/write` Methods.
The ordinary RTT-generated port service remains recursively mapped below
`Services/<name>`, including operations such as `read`, `clear`, `write`, or
`last` when RTT provides them. Those operations belong to the service mapping;
they are not the canonical OPC UA dataport transfer surface.

## Task State Contract

Every ordinary `TaskContext` provides the root operations `getTaskState()` and
`getTargetState()`. They are read-only `ClientThread` operations: the first
reports the state currently occupied, while the second reports the transition
destination. Their values can differ while a lifecycle transition is in
progress.

Both operations are published through the ordinary operation mapper as OPC UA
Methods. Their RTT result type remains `TaskState`, represented on the wire by
one scalar built-in `Int32`:

| Code | RTT state |
|---:|---|
| `0` | `Init` |
| `1` | `PreOperational` |
| `2` | `FatalError` |
| `3` | `Exception` |
| `4` | `Stopped` |
| `5` | `Running` |
| `6` | `RunTimeError` |

Other scalar types, arrays, and codes outside `0..6` are schema errors. The
component object has no synthetic `lifecycleState` child.

## Custom Datatypes

RTT typekits own C++ structure and sequence metadata. OPC UA transport plugins
register provider-owned namespace URIs, NodeIds, dependency information, and
codecs before endpoint startup. Identical registrations are idempotent;
conflicting, cyclic, missing-dependency, and late registrations fail with
deterministic diagnostics.

Canonical sequence names include `Float64Array`, `Int32Array`, `StringArray`,
and `RtString`. Remote endpoints cannot trigger local plugin loading.

## Proxy And TaskBrowser

`TaskContextProxy` reconstructs the supported RTT service graph, resource
mutability, operations, and ports from the endpoint. It validates each port's
`direction`, `value` datatype, value rank, and access before creating a local
mirror. Proxy inputs write the remote Variable. Proxy outputs poll its latest
value at `port_poll_interval`; they do not reconstruct server-side sample
history or `FlowStatus`. Polling may publish an unchanged retained value again,
so local `NewData` identifies a proxy update, not necessarily a distinct remote
RTT write. Outputs without `value` are not mirrored as ports, while their
generated services remain available.

The proxy invokes the native `getTaskState` and `getTargetState` Methods
independently and validates their exact `TaskState` result schema. Its
lifecycle predicates invoke the matching
native Boolean operations rather than inferring results from enum ordering.
An unavailable Method, incompatible result, or invalid state code marks the
remote interface stale.

The installed TaskBrowser can inspect and edit supported scalar and structured
values, invoke mapped operations, and reconnect without depending on the
server's source tree.

## Failure And Lifetime Rules

Published callbacks retain the component and operation storage they use. A
non-returning OwnThread operation can delay endpoint shutdown; its storage is
never released early.

## Verification

Run the maintained package and installed-prefix checks described in
[Package Test Results](./package-test-results.md). The public contract is the
observable installed behavior, not temporary probe output or a historical
feature-plan transcript.
