#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 RTT_PREFIX OUTPUT_EXECUTABLE [--build-only | benchmark options]" >&2
    echo "Optional: RTT_DEPENDENCY_PREFIX for the matching Boost/dependency SDK." >&2
    exit 2
fi
benchmark_prefix=$(realpath "$1")
benchmark_binary=$(realpath -m "$2")
shift 2
benchmark_source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
benchmark_flags=()
benchmark_libraries="$benchmark_prefix/lib"
if [[ -n ${RTT_DEPENDENCY_PREFIX:-} ]]; then
    benchmark_dependency=$(realpath "$RTT_DEPENDENCY_PREFIX")
    benchmark_flags+=("-I$benchmark_dependency/include" "-L$benchmark_dependency/lib" "-Wl,-rpath,$benchmark_dependency/lib")
    benchmark_libraries+=":$benchmark_dependency/lib"
fi
mkdir -p -- "$(dirname -- "$benchmark_binary")"
"${CXX:-c++}" -std=c++20 -O3 -DNDEBUG -DOROCOS_TARGET=gnulinux \
    -I"$benchmark_prefix/include/orocos" -I"$benchmark_prefix/include" \
    -L"$benchmark_prefix/lib" -Wl,-rpath,"$benchmark_prefix/lib" \
    "${benchmark_flags[@]}" "$benchmark_source_dir/scaling_benchmark.cpp" \
    -lorocos-rtt-gnulinux -pthread -o "$benchmark_binary"
if [[ ${1:-} == --build-only ]]; then
    echo "Built $benchmark_binary" >&2
    exit 0
fi
RTT_COMPONENT_PATH="$benchmark_prefix/lib/orocos" \
OROCOS_COMPONENT_PATH="$benchmark_prefix/lib/orocos" \
LD_LIBRARY_PATH="$benchmark_libraries" "$benchmark_binary" "$@"
