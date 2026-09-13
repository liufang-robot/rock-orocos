# Cyclic I/O validation

The automatic cyclic I/O feature remains unmerged. Validation uses a private
RTT 3 installation and matching feature branches of OCL, OroGen, `rtt_typelib`,
`rtt_opcua`, and `rtt_http`.

## Scope

Behavioral checks cover whole ports, scalar/struct member selection, nested
fixed arrays, mixed whole/member endpoints, multiple sources, overlapping-writer
rejection, nested services, defaults and freshness, and active-topology rejection.
Failure checks verify that throw, error, and stop paths suppress publication of
partially modified output images. Observer checks include independent freshness,
retained lifetime, storage resizing, and slow observers exhausting the bounded
cache without suppressing channel delivery.

Installed SDK tests exercise OPC UA and HTTP custom datatypes from separate
consumer projects. Native generated components exercise normal image cycles,
lifecycle state observation, failure suppression, and deployment shutdown.

## Local results

| Validation | Result |
|---|---|
| Preserved RTT 2 baseline | 43/43 CTest suites passed |
| RTT 3 complete core build | 46/46 CTest suites passed |
| New port image and mapping cases | 15 image cases and 28 runtime cases passed |
| AddressSanitizer + UndefinedBehaviorSanitizer | Five endpoint, scripting, image, mapping, and channel suites passed, leak checks enabled |
| OCL | 40/40 CTest suites passed |
| TaskBrowser values and input-source listings | 44 cases passed, including nested services, reconnects, unavailable values, name collisions, and read-only inspection |
| OPC UA | 11/11 CTest suites passed |
| HTTP | 10/10 CTest suites passed |
| Typelib bridge | 1/1 CTest suite passed |
| Native OroGen component/typekit cases | 3 tests, 11 assertions passed |
| Native generated deployments and activities | Four scenarios passed: periodic state/shutdown, cross-project types, activity kinds, and file-descriptor scheduling |
| Separate installed SDK consumers | HTTP and OPC UA custom datatype tests passed |
| CTaskBrowser with the installed OPC UA fixture | Scalar and nested writes, compact arrays, persistence, constant rejection, truncation, and clean shutdown passed |

The unified `connectPort` deployment fixture covers whole values, selected
members, nested fixed-array elements and structures, whole fixed-array fields,
multiple sources, and invalid endpoints. Removed `connectMember` and event-port
registration APIs are checked in the installed C++ SDK and Lua interface.
Connection endpoints and browser values use the same dot/index paths. The 19
endpoint cases include live typed member expressions, frozen compound samples,
unavailable output propagation, read-only member storage, and retained observer
lifetime. An unavailable operation argument must prevent the operation from
executing; a same-name attribute or service must not bypass a registered port.
All 44 browser cases also pass with AddressSanitizer, UndefinedBehaviorSanitizer,
and leak checks against the matching sanitized RTT libraries. Browser fixtures
use isolated history storage.

HTTP and OPC UA publication tests retain existing local connections and permit
passive observation of running components. Explicit input sources stage values
for the next input acquisition; network reads continue to show the last acquired
image. Checks cover disjoint writers, source reconnection, rejected overlaps,
type/shape validation, and read-only defaults. HTTP also checks observation after
port destruction and concurrent requests. OPC UA failure injection verifies that
failed writer removal preserves the connected source and writable access, and
failed member-node creation preserves foreign nodes and permits a clean retry.

OroGen model specifications pass 124 tests with 191 assertions, and focused
generation checks pass nine tests with 27 assertions. Generated native components
and explicit nonperiodic service-port tests verify that data ingress alone does
not execute a hook; an explicit scheduled cycle still refreshes and publishes.

A pre-existing yielding-function hang also reproduced against the RTT 2 baseline.
The executor could finish its callback before the caller recorded queue acceptance,
then wait indefinitely on the overwritten flag. The feature branch includes a
separate fix and deterministic regression for this race. The complete scripting
suite passes 22 cases, and the real yielding case passed 64 consecutive repeats.
The final full RTT run passes without retries.

Input-source inspection checks cover whole and selected endpoints, canonical
array selectors, multiple field producers, upstream writers of unowned shared
transport channels, opaque transport identities, and metadata cleanup after disconnect,
source destruction, and service removal. The native three-component deployment
also displays the four expected source rows in `ls sink.io` while running;
changing producer values updates the sink's computed sum without changing those
rows. Stopping a producer retains its connection row and last input value.

The latest-state policy checks reject FIFO/circular modes through port factories,
deployment, Lua, generated policies, and the OPC UA codec. Component inputs reject
a second whole writer through ordinary and shared connections. Shared storage
checks cover independent consumer freshness and snapshots, repeated identical
publications, concurrent reads/writes, clear/reconnect, and inactive release of
old storage. The rejected-handshake path also has a leak regression; internally
allocated connection IDs are released when registration fails.

## Platform CI

Platform validation covers RTT Windows core/scripting tests, the HTTP Linux and
Windows suites, and the integrated Ubuntu 22.04, Ubuntu 24.04, Debian 13, and
Windows builds. The full integration matrix and packaged-consumer checks must
pass on the selected revisions before review. The coordinated draft pull requests
record the current commit IDs and CI results; local results above do not substitute
for those platform checks.

## Realtime evidence

Instrumentation found zero C++ `new`/`new[]` calls over 10,000 prepared cycles
with fixed structs and member arrays. A concurrent producer test checked 20,000
related-field publications without mixed source samples. This does not measure
arbitrary `malloc`, user-defined copy implementations, or target scheduling.

The timing results below were recorded before event-port scheduling was removed
and deployment member selection was unified under `connectPort`. They describe
that earlier feature revision; they are not new measurements of the latest head.

The timing probe uses a 512-byte frame and a source/sink pair. Sequential cases
include both component cycles; concurrent cases measure the consumer while the
producer runs independently. Each reported percentile is across 1,000 batches
of 100 cycles after 2,000 warmup cycles.

Measurements on 2026-09-13 used GCC 13.3 `-O3`, Boost 1.84, Ubuntu 24.04 under
WSL2/Linux 6.6.87.2, and four virtual CPUs on an Intel Core Ultra 7 255HX.
Compilation was paused during measurements. There was no realtime scheduling
or CPU isolation.

| Scenario, root service | RTT 2 median | RTT 3 median | RTT 3 p99 batch average |
|---|---:|---:|---:|
| Whole frame, sequential pair | 401.27 ns | 421.85 ns | 1639.44 ns |
| One selected field, sequential pair | 355.96 ns | 420.70 ns | 1903.54 ns |
| Four selected fields, sequential pair | 356.93 ns | 431.10 ns | 1660.68 ns |
| Sixteen selected fields, sequential pair | 359.05 ns | 489.02 ns | 2057.22 ns |
| Sixty-four selected fields, sequential pair | 400.20 ns | 896.90 ns | 6188.81 ns |
| Whole frame, concurrent producer | 529.24 ns | 707.65 ns | 1405.46 ns |

RTT 2 does not implement member mappings: its selected-field comparison acquires
the whole value and inspects the selected fields in the hook. Both versions
retain output snapshots; RTT 3 also retains prepared input snapshots. Whole-frame
median overhead was about 5% in this run. Prepared field assignments add work
with increasing mapping count.

The probe also covers service depth four and all selected-field counts with a
concurrent producer. All 20 scenarios per version passed coherence checks. Source,
raw CSV results, and reproduction instructions are under `tests/cyclic-io/` in
the repository. Batch averages and observed maxima are not single-cycle latency
bounds or worst-case execution-time guarantees. Dynamic whole values can still
allocate; target-specific realtime validation remains necessary.

## Validation limits

Local runtime and sanitizer validation is on Linux/WSL2 with CORBA disabled,
matching this distribution's supported configuration. Platform CI establishes
build and functional results; it does not certify realtime timing on Windows,
Xenomai, a realtime kernel, or remote transports.

The existing OroGen Ruby loader suite also has failures with the host's Ruby 3
and FlexMock combination on the unchanged baseline. Compiled native generator
and deployment acceptance tests are evaluated separately from those baseline
loader failures.
