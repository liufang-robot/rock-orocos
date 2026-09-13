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
| RTT 3 complete core build | 45/45 CTest suites passed |
| New port image and mapping cases | 13 image cases and 28 runtime cases passed |
| AddressSanitizer + UndefinedBehaviorSanitizer | Image, mapping, and channel suites passed, leak checks enabled |
| OCL | 39/39 CTest suites passed |
| TaskBrowser values and input-source listings | 35 cases passed, including nested services, reconnects, and nonconsuming inspection |
| OPC UA | 11/11 CTest suites passed |
| HTTP | 6/6 CTest suites passed |
| Typelib bridge | 1/1 CTest suite passed |
| Native OroGen component/typekit cases | 3 tests, 11 assertions passed |
| Native generated deployment and shutdown | 1 test, 28 assertions passed |
| Separate installed SDK consumers | HTTP and OPC UA custom datatype tests passed |
| CTaskBrowser with the installed OPC UA fixture | Scalar and nested writes, compact arrays, persistence, constant rejection, truncation, and clean shutdown passed |

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
