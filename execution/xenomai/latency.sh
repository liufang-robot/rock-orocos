#!/bin/bash
# Measure the selected RT CPU with the housekeeping core idle and busy.
set -euo pipefail
directory=${1:?output directory required}
mkdir -p "$directory"
manifest=/usr/local/share/rock-orocos-image/manifest.json
rt_cpu=$(jq -r '.cpu_profile.realtime_cpu' "$manifest")
housekeeping=$(jq -r '.cpu_profile.housekeeping' "$manifest")
readarray -t cpus < <(python3 - "$housekeeping" <<'PY'
import sys
for part in sys.argv[1].split(','):
    bounds = [int(value) for value in part.split('-')]
    print(*range(bounds[0], bounds[-1] + 1), sep='\n')
PY
)
workers=()
cleanup() {
    if ((${#workers[@]})); then
        kill "${workers[@]}" 2>/dev/null || true
        wait "${workers[@]}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
for scenario in idle loaded; do
    if [[ "$scenario" == loaded ]]; then
        for cpu in "${cpus[@]}"; do
            taskset -c "$cpu" sha256sum /dev/zero >/dev/null &
            workers+=("$!")
        done
    fi
    timeout 90s /usr/xenomai/bin/latency -c "$rt_cpu" -p 1000 -P 80 -T 60 -q -s \
        2>&1 | tee "$directory/latency-$scenario.log"
    grep '^RTS|' "$directory/latency-$scenario.log"
done
