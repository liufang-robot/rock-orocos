# Cyclic I/O timing probe

`cycle_benchmark.cpp` compiles against both RTT 2 and RTT 3. Use unchanged RTT 2
headers/libraries for the baseline, and all feature RTT 3 headers/libraries for
the feature. Keep `RTT_COMPONENT_PATH` isolated for each run.

It measures a source and consumer with a fixed 512-byte frame, whole values or
1/4/16/64 selected fields, service depth 0/4, and a sequential or concurrent
producer. Results are nanoseconds per cycle averaged in batches of 100, with
percentiles across 1,000 batches after warmup. The concurrent case measures only
the consumer cycle while a producer publishes independently. Every run checks
that related fields remain coherent.

RTT 2 has no member mapping; its selected-field baseline explicitly acquires the
whole source value and inspects the same selected fields inside the hook. RTT 3
prepares typed field mappings. The whole-frame scenario is the closest direct
comparison. RTT 2 output retention is enabled to include a committed observer
copy; RTT 3 additionally snapshots prepared input images for observers.

These are throughput and scheduling observations on the test host. Batched
percentiles and observed maxima are not single-cycle worst-case latency bounds.

## Recorded run

`baseline.csv` and `feature.csv` contain the 2026-09-13 validation run on
Ubuntu 24.04 under WSL2, Linux 6.6.87.2, four virtual CPUs on an Intel Core
Ultra 7 255HX, GCC 13.3, `-O3`, and Boost 1.84. Both executions used the
same host without agent compilation running. No realtime scheduler or CPU
isolation was configured.

The baseline runtime is the unchanged RTT commit
`966fbcf0cf79c8c86b229200e5cfa34562462303`; the feature is the matching
`feat/automatic-cyclic-io` SDK at the time of that run, before the subsequent
event-port removal and unified deployment endpoint API. These recorded results
are not a benchmark of the latest feature head. All 20 scenarios in each run passed their
coherence checks. The baseline executable loaded the preserved baseline build
library; the feature executable loaded the private RTT 3 installation.

Compile against each matching prefix, using different output filenames:

```bash
c++ -std=c++20 -O3 -DOROCOS_TARGET=gnulinux \
  -I"$RTT_PREFIX/include/orocos" -I"$RTT_PREFIX/include" \
  cycle_benchmark.cpp -L"$RTT_PREFIX/lib" \
  -Wl,-rpath,"$RTT_PREFIX/lib" -lorocos-rtt-gnulinux -pthread -o cycle-benchmark
RTT_COMPONENT_PATH="$RTT_PREFIX/lib/orocos" \
  LD_LIBRARY_PATH="$RTT_PREFIX/lib" ./cycle-benchmark > timing.csv
```

Dependency include/library paths may also be needed for a prefix that does not
bundle them. Do not mix RTT major versions within one process.

## RTT 3 scaling probe

`scaling_benchmark.cpp` compares selected-field graphs at 128, 512 and 2,048
mappings. Source frames contain 64 or 1,024 doubles (512 bytes or 8 KiB). Source
indices repeat when there are more destinations than source fields. Every field
encodes both its source index and publication generation.

Each source size and mapping count runs four layouts with a sequential and a
concurrent producer:

| Layout | Consumer components | Input ports | Fields per input |
| --- | --- | --- | --- |
| `grouped` | 1 | 1 structured | all mappings |
| `scalar` | 1 | one scalar per mapping | 1 |
| `grouped16` | 16 | one structured per consumer | mappings / 16 |
| `scalar16` | 16 | one scalar per mapping | 1 |

Consumers run sequentially on the calling thread through `SlaveActivity`.
Concurrent mode adds one independently cycling source thread. It does not add
16 competing consumer threads or promise a common snapshot across components.
The source fills its entire frame on each publication. Each timed consumer hook
reads only its first and last fields so correctness checks do not dominate the
transfer measurement.

The probe separates three phases:

1. Construct, connect and start the graph with allocation accounting enabled.
   `setup_ms` includes construction, connection preparation, start and accounting
   overhead; it is not an uninstrumented connection-time comparison. Report live/
   peak **requested C++ allocation bytes** attributed to this phase. Type
   registration occurs first and is excluded. Allocation headers, allocator
   metadata, direct C allocation, stacks, resident pages and shared libraries
   are excluded, so these numbers are not RSS or total process memory.
2. Check initial `NoData`, first `NewData`, retained `OldData`, exact selected
   fields, and coherent source generations within each consumer hook. A separate
   checked cyclic pass intercepts global `new`, `new[]`, aligned `new` and aligned
   `new[]`. Its cyclic totals count calls made during `Activity::execute()` on
   either the consumer or producer thread, including automatic input acquisition
   and output publication. `background_cpp_allocations` and
   `background_cpp_requested_bytes` separately report other threads' allocations
   observed during this pass; those bytes are cumulative requested bytes, not
   live or peak memory. RTT's asynchronous logger can drain setup messages while
   component cycles run, so a process-wide zero-allocation claim would be false.
   An allocation-free bookkeeping lock serializes phase changes and tracked
   allocations/frees, including background activity. This instrumentation affects
   the setup and correctness passes. The timed fixed-storage component cycles
   do not acquire that lock.
   Producer-thread creation and
   the initial deterministic publication occur before this counted pass. All
   port payloads have fixed storage. The previous-value check retains a bounded
   setup-allocated vector per consumer. `new_field_samples`/`old_field_samples`
   count fields, so a structured input's status contributes once per member.
   `checked_producer_cycles` must be nonzero; a producer pause/resume handshake
   ensures the concurrent check actually runs the source thread.
   After that producer has paused, another consumer sweep must acquire its
   final generation in every mapped field. The following sweep must retain it
   as `OldData`. `latest_generation_failures` rejects a consumer that remains
   stuck on an older coherent frame despite producer progress.
3. Disable allocation accounting and correctness scans, warm up the graph, then
   time each individual consumer execution. `consumer_*` reports percentiles
   across these individual calls; `sweep_*` reports a full sequential sweep of
   all consumers and includes the inner timing calls. Source execution is
   outside the timing interval in sequential mode. Concurrent mode measures
   consumers while the source publishes independently. `timing_producer_cycles`
   records publications over the measured interval. No batch averaging is used.
   `round_*` additionally includes the source execution in sequential mode and
   the full consumer sweep, including measurement overhead. This is the complete
   execution cost of the sequential source/consumer round. In concurrent mode
   that interval contains only the consumer work and timing overhead.

Percentiles use the nearest-rank convention. `p99_minus_p50` is the percentile
spread of execution durations, **not** periodic-release jitter. Maxima are
observations from the run, not worst-case execution-time bounds. This program
does not configure realtime priorities, CPU affinity or CPU isolation. Record
the host, OS/runtime, scheduling, compiler, exact RTT revision and SDK library
hash with a result. Run baseline and candidate on the same otherwise idle host;
do not compare one run during a build with another run after compilation.

Compile against an isolated matching RTT 3 prefix (the prefix contains
`include/orocos` and `lib`):

```bash
RTT_DEPENDENCY_PREFIX=/path/to/dependency-sdk \
  tests/cyclic-io/run-scaling-benchmark.sh \
  /path/to/rtt3-prefix /tmp/scaling-benchmark --build-only
```

Run the preserved executable without recompiling, for example after builds have
finished. Keep its matching RTT library and headers with the result; RTT port
templates are instantiated in the executable.

```bash
RTT_COMPONENT_PATH=/path/to/rtt3-prefix/lib/orocos \
OROCOS_COMPONENT_PATH=/path/to/rtt3-prefix/lib/orocos \
LD_LIBRARY_PATH=/path/to/rtt3-prefix/lib:/path/to/dependency-sdk/lib \
  /tmp/scaling-benchmark --require-coherence > /tmp/scaling.csv
```

Omit `--build-only` to compile and run in one command when the host is ready.
The defaults are 2,000 measured sweeps, 200 warmup sweeps and 128 allocation/
correctness sweeps per scenario. Optional filters are `--source-bytes 512|8192`,
`--mappings 128|512|2048`, `--layout grouped|scalar|grouped16|scalar16`, and
`--mode sequential|concurrent`. Counts can be changed with `--iterations`,
`--warmup` and `--check-iterations`.

`--period-us 1000` makes a separate observation of sequential rounds scheduled
at absolute 1 ms releases using `steady_clock` and `sleep_until`. It selects
sequential mode and rejects an explicitly concurrent mode. The wait occurs
outside the execution interval. `wake_lateness_*` measures actual start minus
planned release, clamped to zero; `deadline_misses` counts rounds finishing
after their planned release plus the period. After an overrun, subsequent
releases keep their original phase, so the loop may execute catch-up rounds.
The correctness/allocation pass and warmup remain unpaced. Without a period,
the wake-lateness and deadline-miss columns are zero and have no scheduling
meaning. These are observations of the host scheduler, not realtime deadline
guarantees; collect throughput comparisons before these separate paced runs.

The program returns nonzero for allocation, selector, status, retention or final-generation
failures. `--require-coherence` also rejects mixed source generations within one
consumer hook. Without this flag, coherence failures remain visible in the CSV
so an older implementation can be measured as a baseline. A baseline with
coherence failures must not be described as having passed the candidate's
coherence requirement. No coherence claim is made across different consumers.

## Recorded scaling run

[scaling-baseline.csv](scaling-baseline.csv),
[scaling-feature.csv](scaling-feature.csv) and
[scaling-periodic.csv](scaling-periodic.csv) record the 2026-09-14 run.
[scaling-environment.json](scaling-environment.json) records exact commands,
timestamps, revisions, compiler, SDK/header/library/binary hashes and allocation
scope. Both variants use RTT 3: baseline
`c2554980b455e13189585a4b0ce92c4bfac77fd6` and candidate
`0b38144ced83418e52cfbcd3a1b049ad5b4a773b`.

The host was Ubuntu 24.04.4 on WSL2 Linux 6.6.87.2, four virtual CPUs on an Intel
Core Ultra 7 255HX, GCC 13.3, `-O3 -DNDEBUG`, with `SCHED_OTHER` priority 0 and
no explicit CPU affinity or isolation. Local builds/tests were paused. The
48-case baseline ran first, then the 48-case candidate, then the two paced
candidate cases. Each case used 10,000 measured rounds, 1,000 warmup rounds and
a separate 1,000-round correctness/allocation pass.

Representative **sequential full-round** observations for an 8 KiB source and
one consumer with scalar input ports are below. Durations include source
publication and consumer execution. Memory is setup peak requested C++ bytes,
expressed in KiB; it is not RSS.

| Mappings | Baseline p50 / p99 (µs) | Candidate p50 / p99 (µs) | Baseline / candidate max (µs) | Baseline / candidate setup peak (KiB) |
| --- | --- | --- | --- | --- |
| 128 | 106.928 / 247.713 | 3.541 / 4.615 | 665.428 / 162.304 | 9,724.721 / 312.799 |
| 512 | 1,185.970 / 1,660.570 | 11.521 / 20.512 | 9,059.610 / 642.464 | 38,683.346 / 911.188 |
| 2,048 | 7,045.260 / 8,650.760 | 51.510 / 112.369 | 11,960.100 / 775.222 | 154,517.850 / 3,303.959 |

The grouped layout already shares one structured input: for 512 mappings its
baseline/candidate medians were 5.722/5.709 µs, p99 values 9.080/13.193 µs and
setup peaks 422.946/390.898 KiB. The candidate's benefit is concentrated in
graphs that previously duplicated source acquisition across scalar input ports;
these observations do not establish an improvement for every layout or tail.
The CSV also contains consumer-only durations and p99-minus-p50 spreads.

All 48 candidate cases passed strict within-consumer coherence, selector,
status, retention and final-generation checks. The baseline recorded 14,233
mixed-generation consumer hooks across its scalar concurrent cases; its other
correctness checks passed. Every case in both variants recorded zero C++
allocations during checked component execution, including the source thread.
Concurrent background allocation counts totaled 540 for the baseline and 603
for the candidate. An initial process-wide allocation check exposed RTT's
asynchronous logger draining setup messages; the final harness reports this
activity separately and synchronizes accounting across phase changes.

The separate 1 ms release observations used the same 8 KiB source and scalar
input layout:

| Mappings | Round p99 / max (µs) | Wake lateness p99 / max (µs) | Deadline misses / 10,000 |
| --- | --- | --- | --- |
| 128 | 62.856 / 208.240 | 152.279 / 6,013.810 | 8 |
| 512 | 129.952 / 3,334.220 | 189.597 / 3,462.280 | 17 |

The observed scheduler delays and deadline misses mean these WSL2 results do
not establish a guaranteed 1 ms runtime. A target realtime OS and scheduling
configuration need their own acceptance run.
