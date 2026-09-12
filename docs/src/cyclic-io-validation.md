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
| New port image and mapping cases | 8 image cases and 20 runtime cases passed |
| AddressSanitizer + UndefinedBehaviorSanitizer | Image, mapping, and channel suites passed, leak checks enabled |
| OCL | 39/39 CTest suites passed |
| TaskBrowser values and input-source listings | 35 cases passed, including nested services, reconnects, and nonconsuming inspection |
| OPC UA | 11/11 CTest suites passed |
| HTTP | 6/6 CTest suites passed |
| Typelib bridge | 1/1 CTest suite passed |
| Native OroGen component/typekit cases | 3 tests, 11 assertions passed |
| Native generated deployment and shutdown | 1 test, 27 assertions passed |
| Separate installed SDK consumers | HTTP and OPC UA custom datatype tests passed |
| CTaskBrowser with the installed OPC UA fixture | Scalar and nested writes, compact arrays, persistence, constant rejection, truncation, and clean shutdown passed |

A pre-existing yielding-function hang also reproduced against the RTT 2 baseline.
The executor could finish its callback before the caller recorded queue acceptance,
then wait indefinitely on the overwritten flag. The feature branch includes a
separate fix and deterministic regression for this race. The complete scripting
suite passes 22 cases, and the real yielding case passed 64 consecutive repeats.
The final full RTT run passes without retries.

Input-source inspection checks cover whole and selected endpoints, canonical
array selectors, multiple field producers, all local writers of a shared
channel, opaque transport identities, and metadata cleanup after disconnect,
source destruction, and service removal. The native three-component deployment
also displays the four expected source rows in `ls sink.io` while running;
changing producer values updates the sink's computed sum without changing those
rows. Stopping a producer retains its connection row and last input value.

## Platform CI

The draft RTT pull request passes its Windows core and scripting test workflow.
The HTTP pull request passes all seven Linux and six Windows CTest suites.
The integrated feature branch builds and installs successfully on Ubuntu 22.04,
Ubuntu 24.04, and Debian 13. The full integration matrix and packaged-consumer
checks must also pass before this feature is considered ready for review.

## Realtime evidence

Instrumentation found zero C++ `new`/`new[]` calls over 10,000 prepared cycles
with fixed structs and member arrays. A concurrent producer test checked 20,000
related-field publications without mixed source samples. This does not measure
arbitrary `malloc`, user-defined copy implementations, or target scheduling.

The timing probe uses a 512-byte frame and a source/sink pair. Sequential cases
include both component cycles; concurrent cases measure the consumer while the
producer runs independently. Each reported percentile is across 1,000 batches
of 100 cycles after 2,000 warmup cycles.

Measurements on 2026-09-12 used GCC 13.3 `-O3`, Boost 1.84, Ubuntu 24.04 under
WSL2/Linux 6.6.87.2, and four virtual CPUs on an Intel Core Ultra 7 255HX.
Compilation was paused during measurements. There was no realtime scheduling
or CPU isolation.

| Scenario, root service | RTT 2 median | RTT 3 median | RTT 3 p99 batch average |
|---|---:|---:|---:|
| Whole frame, sequential pair | 213.83 ns | 256.60 ns | 429.92 ns |
| One selected field, sequential pair | 189.90 ns | 267.97 ns | 446.64 ns |
| Four selected fields, sequential pair | 190.20 ns | 295.04 ns | 421.78 ns |
| Sixteen selected fields, sequential pair | 192.09 ns | 370.80 ns | 695.88 ns |
| Sixty-four selected fields, sequential pair | 213.22 ns | 722.23 ns | 1369.70 ns |
| Whole frame, concurrent producer | 337.93 ns | 425.37 ns | 619.95 ns |

RTT 2 does not implement member mappings: its selected-field comparison acquires
the whole value and inspects the selected fields in the hook. Both versions
retain output snapshots; RTT 3 also retains prepared input snapshots. Whole-frame
median overhead was about 20% in this run. Prepared field assignments add work
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
