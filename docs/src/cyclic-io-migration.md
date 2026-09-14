# Migrating Applications to 0.2.0

The `orocos` and `orocos-dev` 0.2.0 distribution introduces the RTT 3 cyclic
data-port model. This is a breaking source and ABI change. Applications must
update their components, generated code, deployment scripts, and transport
integration, then rebuild against one matching SDK.

> The version is being prepared on `feat/automatic-cyclic-io`. The feature PRs
> remain unmerged; this guide does not imply that 0.2.0 packages are published.
> Until release, use a complete private feature installation. Keep its library
> and plugin paths separate from an RTT 2 installation.

The distribution version is 0.2.0; RTT and OCL use ABI version 3.0. See
[Automatic Cyclic Data Ports](./automatic-cyclic-io.md) for the runtime contract
and [Cyclic I/O Validation](./cyclic-io-validation.md) for evidence and limits.

## Component Changes

Keep `RTT::TaskContext`, ordinary `RTT::InputPort<T>` and
`RTT::OutputPort<T>`, and registration through `addPort()`. Ports registered in
nested services participate in their owning component's cycle automatically.
There is no additional component base class or legacy manual-I/O mode.

Replace this old hook:

```cpp
void updateHook() override {
    Input sample;
    if (input.read(sample) == RTT::NewData) {
        Output result;
        result.y = sample.y * 2.0;
        result.z = sample.x + sample.y;
        output.write(result);
    }
}
```

with image access in the owning execution context:

```cpp
void updateHook() override {
    const auto& sample = input.data();
    auto& result = output.data();
    result.y = sample.y * 2.0;
    result.z = sample.x + sample.y;
}
```

Before the hook, RTT refreshes input images. After a successful hook, it commits
output images if the component remains Running. Exceptions, error transitions,
and requested stops suppress publication from that hook.

Decide explicitly whether application calculations should run every cycle or
only on fresh input. `input.status()` reports `NoData`, `NewData`, or `OldData`
from the last acquisition boundary. Returning early on `OldData` skips the
calculation but a successful scheduled cycle still commits the retained output
image. There is no per-port manual `write()` to suppress that publication.

Input images are const and retain defaults or the last acquired value when a
source has no new publication. Use `setDataSample()` while stopped to establish
defaults and required storage shape. For a structured input assembled from
several sources, `NewData` does not mean every member was updated together.
Unmapped members retain their configured values.

Keep `data()` access inside the owning hooks or correctly scheduled owner
operations. Do not hand mutable output references to browser or network threads.
Use passive observation for external reads. User-defined copies and dynamic
values can allocate; prepare bounded storage for realtime paths and validate
the application on its actual target.

## Scheduling and Delivery

Replace `addEventPort()` and port-trigger callbacks with ordinary `addPort()`
registration and an explicit activity or external scheduler. Receiving data no
longer schedules a component. A nonperiodic activity needs an explicit trigger
for subsequent cycles. Audit service ports as well as root-level ports.

Latest-state connections can coalesce intermediate samples. FIFO/circular
data-port modes and buffered-input helpers are removed. If every event or
command must be processed, choose an explicit application command mechanism;
do not assume a latest-state port delivers every publication.

Rebuild generated tasks and typekits with the matching OroGen/Typegen tools.
Migrate `port_driven`, `task_trigger`, event-input declarations and
input-dependent output triggers to an explicit schedule. Lua components use
ordinary input/output declarations; `in+event` is removed. Consult the
[cyclic scheduling examples](./automatic-cyclic-io.md#execution-scheduling).

## Deployment Changes

Use `connectPortData(source, destination)` for both entire port values and
selected data regions:

```text
connectPortData("pair_source.output", "sink.io.whole")
connectPortData("pair_source.output.y", "sink.io.input.y")
connectPortData("scalar_source.output", "sink.io.input.x")
connectPortData("pair_source.output.z", "sink.io.z")
connectPortData("axis_source.output.axes[2].position", "sink.target.position")
```

The resolver walks actual services to a registered port, then selects members or
constant fixed-array indices. Properties and attributes are not connection
endpoints. Selected types and shapes must match; there are no implicit numeric
conversions. Different enclosing structures can connect through matching member
types. Dynamic container element selectors are rejected; matching whole dynamic
values remain supported. Root port images must own their storage: nonowning
`carray` wrappers are rejected during preparation. Wrap fixed C arrays in an
owning structure and register the matching type metadata.

| Previous API or syntax | Migration |
|---|---|
| Explicit `connectPort(source, destination)` | `connectPortData(source, destination)` |
| Separate `connectMember(...)` | Select the members in two `connectPortData` endpoint strings |
| `source.output::axes[2].position` | `source.output.axes[2].position` |
| Deprecated `connectTwoPorts(...)` | Two qualified `connectPortData` endpoints |
| Generated port methods such as `output.connected()` | `isPortConnected("component.output")` |

The former explicit `connectPort` name is removed without an alias. Bulk
`connectPorts` and the peer, operation, and service connection APIs have separate
roles and remain available.

Each input region has one writer. A whole-input connection excludes additional
writers to any member, even from the same output. A selected parent region
excludes writers to its children. Different sources may populate disjoint
members, and an output can supply multiple inputs through whole and member
connections simultaneously. Independent producers have independent cycle
boundaries; the assembled input is not a globally synchronized producer frame.

Configure storage and connections while affected components are stopped.
`startComponent()` prepares its graph automatically. `finalizeConnections()`
remains an optional deployment preflight. Use
`disconnectPort("sink.io.input")` to remove that input's connections before
replacing a whole connection with individual member mappings.

## Browser Changes

Use the same paths for inspection and connections:

```text
pair_source.output.y
sink.io.input.x
sink.io.input
ls sink.io
isPortConnected("sink.io.input")
```

The port directly represents its data in expressions. There is no `.data` or
`.snapshot` wrapper, and no synthetic service under the port name. Real services
remain services. Port expressions are read-only; a registered port takes
precedence over a same-name service or attribute in a data expression.

Input inspection reports defaults and then the last image actually acquired by
the component. Output inspection reports the last committed publication and is
unavailable before the first commit. Unavailable expressions cannot silently
supply a default argument to an operation. `ls` shows the output endpoint
supplying each connected input region.

## HTTP and OPC UA Changes

Publishing a component observes its ports without adding input writers or
output consumers. Publication therefore preserves existing local connections.
Both input and output values are read-only by default. Property, attribute,
and operation surfaces retain their own existing contracts.

Applications that accept external port commands must configure an explicit
source after publication, while the component is stopped:

```text
opcua.publishComponent("sink")
opcua.enableInputWrite("sink.io.input.x")
```

The HTTP service has equivalent `enableInputWrite` and `disableInputWrite`
operations. A source can target the whole input or an allowed member/fixed-index
region, with the same type, shape and overlap rules as local connections.
An existing whole writer prevents enabling any external member writer.

An accepted network write stages a sample for the next input boundary. An
immediate read continues to report the old acquired image. If the component is
stopped, it does not acquire the staged sample until a cycle runs. Acceptance is
not an application execution acknowledgement. Multiple clients use the same
enabled source, with latest-state delivery; enabling input writing does not
provide per-client arbitration.

Whole OPC UA values remain under `ports/P/value`; selected input Variables use
`ports/P/members/<encoded selector>`. Disabling a selected source leaves its
Variable read-only. HTTP exposes input and output `/latest` observations and
explicitly enabled `/samples` ingress, including member routes. Outputs do not
accept external port writes. See the exact wire contracts in
[Native OPC UA Reference](./opcua-reference.md) and
[HTTP REST Reference](./http-reference.md).

## Application Acceptance

1. Inventory native and generated components, service ports, manual I/O calls,
   event scheduling, buffer policies, deployment scripts, and external writers.
2. Update component calculations and scheduling together. Test startup defaults,
   retained values, freshness handling, stopped producers, and failure paths.
3. Migrate deployment names and paths. Verify whole/member connections,
   disjoint sources, fan-out, rejected overlaps, and stopped reconfiguration.
4. Rebuild every application component, typekit and transport against one SDK.
   Use fresh application build directories and verify loaded library/plugin
   paths; do not reuse RTT 2 artifacts.
5. Check real browser values and `ls` source rows. Verify that inspection cannot
   modify port data and does not consume the component's freshness.
6. Verify network publication is passive, ingress is explicitly configured,
   wrong types/shapes are rejected, and staged values become visible after
   acquisition. Keep application acknowledgement separate from write acceptance.
7. Measure allocations, execution time and deadlines with the application's
   actual data types, rates and deployment target. Toolchain functional tests
   do not certify the application's realtime bounds.
