import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('check_cpus', Path(__file__).parents[1] / 'check-cpus.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class CpuIsolationTests(unittest.TestCase):
    def setUp(self):
        self.profile = dict(online='0-3', housekeeping='0,2', isolated='1,3',
                            realtime_cpu=3, supported_cpus='0x9', allowed_group=4242)
        self.state = dict(
            online={0, 1, 2, 3}, siblings={0: {0, 2}, 1: {1, 3}, 2: {0, 2}, 3: {1, 3}},
            isolated={1, 3}, nohz_full={1, 3}, manager_affinity={0, 2}, runner_affinity={0, 2},
            irq_affinity=5, supported_cpus=9, allowed_group=4242,
            cmdline='root=/dev/vda1 console=ttyS0 nowatchdog irqaffinity=0,2 '
                    'isolcpus=managed_irq,domain,1,3 nohz_full=1,3 rcu_nocbs=1,3 '
                    'xenomai.supported_cpus=0x9 xenomai.allowed_group=4242')

    def test_measured_ec2_topology(self):
        check.validate(self.profile, self.state)

    def test_fresh_vm_without_smt(self):
        self.state['siblings'] = {cpu: {cpu} for cpu in range(4)}
        check.validate(self.profile, self.state)

    def test_rejects_housekeeping_on_rt_sibling(self):
        self.state['siblings'] = {0: {0, 1}, 1: {0, 1}, 2: {2, 3}, 3: {2, 3}}
        with self.assertRaisesRegex(AssertionError, 'shares a core'):
            check.validate(self.profile, self.state)

    def test_rejects_missing_boot_settings_and_runtime_drift(self):
        for key, value in (
            ('online', {0, 1}), ('isolated', {3}), ('nohz_full', set()),
            ('manager_affinity', {0, 1, 2, 3}), ('runner_affinity', {0, 1, 2, 3}),
            ('irq_affinity', 15), ('supported_cpus', 15), ('allowed_group', 1001),
            ('cmdline', self.state['cmdline'].replace(' rcu_nocbs=1,3', '')),
        ):
            with self.subTest(key=key):
                state = copy.deepcopy(self.state)
                state[key] = value
                with self.assertRaises(AssertionError):
                    check.validate(self.profile, state)


if __name__ == '__main__':
    unittest.main()
