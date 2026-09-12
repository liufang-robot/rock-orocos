# Native automatic cyclic I/O

Status: accepted direction, implementation on `feat/automatic-cyclic-io`; unmerged.

## Requirements

The public component model remains RTT::TaskContext, nested RTT::Service interfaces,
InputPort<T>, OutputPort<T>, and updateHook(). All data ports use automatic cyclic
I/O. Remove public consuming read()/readNewest() and publishing write() operations,
including their scripting wrappers. No legacy/manual mode or compatibility switch.

Each port owns a stable, value-initialized typed process image. Input data() returns
a const reference; output data() returns a mutable reference. Accessing an image
never consumes or publishes a sample. Components register ports in their usual
service interfaces. Input images are refreshed before updateHook(); eligible output
images are published after it returns. Runtime errors, exceptions, pending stops,
and invalid topology must not publish partially executed output images.

Whole ports, nested structures, scalar members, and fixed-array elements are typed
endpoints. Every combination of whole/member source and whole/member destination
is valid when the selected types match exactly. Do not allow implicit numeric
conversion or byte-size-based compatibility. Array shapes must also match.

Multiple output ports can supply nonoverlapping parts of one input image. Read
each distinct source subscription once per assembly. Assemble each destination
once, preserving fields with configured/default values when they have no new
sample. Images are value-initialized; freshness is observable without consuming
data. There is no waiting for sources within a realtime update.

Root and arbitrarily nested service ports participate in the same owning component
cycle. Service discovery and mapping resolution happen outside the cyclic path.
Retain full service-qualified names for deployment and diagnostics.

## Deployment interface

`connectPort(sourcePort, destinationPort)` connects complete matching values.
`connectMember(sourcePort, sourcePath, destinationPort, destinationPath)` selects
typed endpoints; an empty member path selects the whole port value. This makes
whole-to-member and member-to-whole connections explicit. Paths support nested
members and constant array indices, such as `axes[2].position`.

`finalizeConnections()` validates all declarations and prepares execution lists
before activation. Reject unknown paths, malformed/negative/out-of-range indices,
type/shape mismatches, duplicate or overlapping destination writers, and active
topology changes. The two connection operations use one execution model.

## Internal implementation

Retain typed RTT channels for synchronized sample transport. A private runtime
capability performs acquisition/publication for execution engines and transport
plugins. It is not a replacement manual component API. External network ingress
must stage samples in transport-owned channels; it cannot mutate a running
component's input image. External observers read committed output snapshots.

For mapping between different parent types, subscribe to source-typed samples
using internal ports and bind selected members into the destination image at
configuration time. Reuse subscriptions for mappings from the same source into
the same destination. Preallocate all snapshots and assignment actions. Fixed
arrays require elementwise validated assignments to avoid carray wrapper aliasing.

The ExecutionEngine runs a flattened prepared plan around the existing virtual
updateHook. Existing lifecycle checks and exception handling remain authoritative.
Callbacks/operations retain RTT execution policies; direct process-image mutation
is confined to the owner execution context. Port/service destruction invalidates
affected plans before releasing storage; active topology mutation is rejected.

This implementation guarantees a component-local input boundary. Independent
components may observe latest completed outputs from other cycles. A group-wide
all-input/all-hook/all-output barrier is a distinct scheduler capability and must
not be claimed without an implementation and validation of group scheduling.

## Realtime and delivery gates

No service traversal, path parsing, reflection construction, allocation, unbounded
buffer draining, or additional worker thread in the new steady-state cycle path.
State ports use latest-value delivery. Existing transport locking and user-defined
copy behavior still require target-specific review; arbitrary registered types
are supported where their type operations are available, but only validated fixed
types qualify for an allocation-free timing claim. Queued events cannot silently
be treated as lossless cyclic state; affected facilities must use explicit bounded
state/batch or runtime observation semantics.

Use a private install prefix and coordinated feature worktrees for every modified
package. Preserve canonical and distribution checkouts. Do not merge or release
this feature while implementation or validation is incomplete. Keep the feature
unmerged for review even after local validation; do not begin the OptimalCNC port
before canonical publication gates are satisfied.

## Required validation

Native tests: stable input within hooks; automatic publication; retained/default
values; no public read/write; lifecycle failure publication; root/nested services;
whole/whole, whole/member, member/whole, member/member, nested structs, array shapes
and bounds; multi-source assembly; duplicate/overlap rejection; destruction and
reconfiguration; snapshot freshness; allocation-free fixed-type steady state;
concurrent producer snapshots. Run existing RTT tests after explicit migration.

Integration: real OCL deployment scripts, generated component/typekit consumer,
native mqueue and OPC UA/HTTP transport tests using the private prefix. Validate
observation and staged ingress independently of component execution.

Compare equivalent manual baseline and automatic cycle timing with fixed sample
sizes, increasing mapping counts, service depth, and concurrent producers. Report
measured distributions and limitations; do not present measurements as a proven
hard worst-case bound. Required CI/platform checks remain release gates.
