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

`baseline.csv` and `feature.csv` contain the 2026-09-12 validation run on
Ubuntu 24.04 under WSL2, Linux 6.6.87.2, four virtual CPUs on an Intel Core
Ultra 7 255HX, GCC 13.3, `-O3`, and Boost 1.84. Both executions used the
same host without agent compilation running. No realtime scheduler or CPU
isolation was configured.

The baseline runtime is the unchanged RTT commit
`966fbcf0cf79c8c86b229200e5cfa34562462303`; the feature is the matching
`feat/automatic-cyclic-io` SDK. All 20 scenarios in each run passed their
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
