"""Counterexamples for strict acceptance; synthetic records are checker tests only."""
import copy
import unittest
from check_overlap50_strict import evaluate, BUDGET


def fixture():
    events = [dict(type='run', scope='SOC', window_length=1024, hop=512,
                   channels=12, clock_hz=40000000, sample_period_cycles=1024,
                   audio_verified=True, timing=dict(source_hash_match=True,
                       clock_hz=40000000, report='synthetic-checker-fixture', wns_ns=0, whs_ns=0))]
    for i in range(256):
        ready = 1048576 + i * BUDGET
        events.append(dict(type='window', window_id=i+1, first_sample=i*512,
                           ready_cycle=ready, result_cycle=ready+400000,
                           geometry_mode='TEST_GEOMETRY_ONLY', fft_fwd=12,
                           gcc_pairs=66, ifft=66, srp=1, srp_grid=1024,
                           window_golden_match=True, pair_computation_verified=True,
                           srp_golden_match=True))
    events.append(dict(type='coverage', first_sample=0, sample_count=1024+255*512,
                       raw_block_loss=0, window_skip=0, audio_drops=0))
    return events


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.events = fixture()

    def reject(self, reason):
        report = evaluate(self.events)
        self.assertEqual(report['status'], 'FAIL')
        self.assertIn(reason, report['failures'])

    def test_complete_fixture(self):
        result = evaluate(self.events)
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['algorithm_counts']['gcc_pairs'], 16896)
        self.assertFalse(result['physical_accuracy_validated'])

    def test_missing_last_window(self):
        self.events.pop(-2)
        self.reject('MISSING_DUPLICATE_OR_REORDERED_WINDOWS')

    def test_missing_first_backlog(self):
        self.events.pop(1)
        self.reject('MISSING_DUPLICATE_OR_REORDERED_WINDOWS')
        self.assertEqual(evaluate(self.events)['max_backlog'], 2)

    def test_duplicate(self):
        self.events[4] = copy.deepcopy(self.events[3])
        self.reject('MISSING_DUPLICATE_OR_REORDERED_WINDOWS')

    def test_old_result(self):
        self.events[1]['result_cycle'] = self.events[2]['result_cycle']
        self.reject('RESULT_ORDER')

    def test_disabled_geometry(self):
        self.events[1]['geometry_mode'] = 'DISABLED'
        self.reject('FULL_CHAIN_NOT_EXECUTED')

    def test_reduced_work(self):
        for field in ('fft_fwd', 'gcc_pairs', 'ifft', 'srp', 'srp_grid'):
            with self.subTest(field=field):
                self.events = fixture()
                self.events[1][field] = 0
                self.reject('FULL_CHAIN_NOT_EXECUTED')

    def test_unverified_numeric(self):
        self.events[1]['pair_computation_verified'] = False
        self.reject('NUMERIC_PAIR_COMPUTATION_VERIFIED')

    def test_losses(self):
        for field in ('raw_block_loss', 'window_skip', 'audio_drops'):
            with self.subTest(field=field):
                self.events = fixture()
                self.events[-1][field] = 1
                self.reject(field.upper())

    def test_module_no_audio_or_timing(self):
        self.events[0].update(scope='MODULE', audio_verified=False, timing={})
        self.events[-1]['audio_drops'] = None
        for reason in ('SOC_NOT_EXECUTED', 'AUDIO_NOT_VERIFIED',
                       'CURRENT_40MHZ_IMPLEMENTATION_NOT_VERIFIED', 'UNMEASURED_AUDIO_DROPS'):
            self.reject(reason)

    def test_wrong_cadence(self):
        self.events[2]['ready_cycle'] += 1
        self.reject('READY_CADENCE')

    def test_latency_with_good_throughput(self):
        for window in self.events[1:-1]:
            window['result_cycle'] = window['ready_cycle'] + BUDGET + 1
        self.reject('LATENCY_FAIL')
        self.assertTrue(evaluate(self.events)['throughput_pass_latency_fail'])

    def test_result_gap(self):
        self.events[128]['result_cycle'] += 100
        self.reject('THROUGHPUT_FAIL')

    def test_invalid_timestamp(self):
        self.events[1]['result_cycle'] = -1
        with self.assertRaises(ValueError):
            evaluate(self.events)

    def test_nonfinite_or_stale_timing(self):
        for changes in (dict(wns_ns=float('nan')), dict(whs_ns=-0.01), dict(source_hash_match=False)):
            self.events = fixture()
            self.events[0]['timing'].update(changes)
            self.reject('CURRENT_40MHZ_IMPLEMENTATION_NOT_VERIFIED')

    def test_zero_coverage(self):
        self.events = [self.events[0], dict(self.events[-1], sample_count=512)]
        self.reject('NO_COMPLETE_WINDOWS')

    def test_unconfirmed_geometry(self):
        self.events[1]['geometry_mode'] = 'CONFIRMED_PRODUCTION'
        self.reject('UNCONFIRMED_PRODUCTION_GEOMETRY')


if __name__ == '__main__':
    unittest.main()
