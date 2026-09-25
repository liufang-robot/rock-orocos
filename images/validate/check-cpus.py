#!/usr/bin/env python3
"""Reject a boot that does not implement the image's declared CPU isolation."""
import json
import os
from pathlib import Path


def cpu_list(value):
    result = set()
    for part in value.strip().split(','):
        if not part:
            continue
        bounds = [int(item) for item in part.split('-')]
        result.update(range(bounds[0], bounds[-1] + 1))
    return result


def validate(profile, state):
    online = cpu_list(profile['online'])
    housekeeping = cpu_list(profile['housekeeping'])
    isolated = cpu_list(profile['isolated'])
    rt_cpu = profile['realtime_cpu']
    assert state['online'] == online, 'Unexpected online CPUs; select a matching image profile'
    assert housekeeping | isolated == online and not housekeeping & isolated
    assert 0 in housekeeping and rt_cpu in isolated
    for cpu in isolated:
        assert state['siblings'][cpu] <= isolated, f'CPU {cpu} shares a core with housekeeping'
    assert state['isolated'] == isolated, 'Scheduler isolation mismatch'
    assert state['nohz_full'] == isolated, 'Full-dynticks isolation mismatch'
    assert state['manager_affinity'] <= housekeeping, 'System services can run on the RT core'
    assert state['runner_affinity'] <= housekeeping, 'Runner can run on the RT core'
    irq_cpus = {cpu for cpu in online if state['irq_affinity'] & (1 << cpu)}
    assert irq_cpus == housekeeping, 'Default IRQ affinity mismatch'
    mask = int(profile['supported_cpus'], 0)
    assert mask & 1 and mask & (1 << rt_cpu), 'Cobalt needs CPU 0 and the RT CPU'
    assert state['supported_cpus'] == mask, 'Cobalt CPU mask mismatch'
    assert state['allowed_group'] == profile['allowed_group'], 'Cobalt group mismatch'
    args = dict(item.split('=', 1) if '=' in item else (item, '')
                for item in state['cmdline'].split())
    for key, expected in {
        'nowatchdog': '',
        'irqaffinity': profile['housekeeping'],
        'isolcpus': 'managed_irq,domain,' + profile['isolated'],
        'nohz_full': profile['isolated'],
        'rcu_nocbs': profile['isolated'],
        'xenomai.supported_cpus': profile['supported_cpus'],
        'xenomai.allowed_group': str(profile['allowed_group']),
    }.items():
        assert args.get(key) == expected, f'Boot argument mismatch: {key}'


def main():
    profile = json.loads(Path('/usr/local/share/rock-orocos-image/manifest.json').read_text())['cpu_profile']
    cpu_root = Path('/sys/devices/system/cpu')
    online = cpu_list((cpu_root / 'online').read_text())
    state = {
        'online': online,
        'siblings': {cpu: cpu_list((cpu_root / f'cpu{cpu}/topology/thread_siblings_list').read_text())
                     for cpu in online},
        'isolated': cpu_list((cpu_root / 'isolated').read_text()),
        'nohz_full': cpu_list((cpu_root / 'nohz_full').read_text()),
        'manager_affinity': os.sched_getaffinity(1),
        'runner_affinity': os.sched_getaffinity(0),
        'irq_affinity': int(Path('/proc/irq/default_smp_affinity').read_text().replace(',', ''), 16),
        'supported_cpus': int(Path('/sys/module/xenomai/parameters/supported_cpus').read_text()),
        'allowed_group': int(Path('/sys/module/xenomai/parameters/allowed_group').read_text()),
        'cmdline': Path('/proc/cmdline').read_text().strip(),
    }
    print(json.dumps({'profile': profile, 'observed': state}, default=sorted, indent=2), flush=True)
    validate(profile, state)
    print('CPU isolation matches the image profile; the RT core has no housekeeping sibling')


if __name__ == '__main__':
    main()
