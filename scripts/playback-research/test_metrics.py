"""Protect the seek oracle against false passes from optimistic UI positions."""
import importlib.util
import gzip
import hashlib
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('reliability', Path(__file__).with_name('run.py'))
reliability = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reliability)


def sample(t, position=0, **fields):
    return dict(t=t, position=position, time=position, status=2, buffering=False,
                wants=True, uri='fixture://track/fast-0-local', error='', local=True,
                loaded=[[0, 72]], seekable=[[0, 72]], automatic_waits=True,
                event='sample') | fields


def successful_local_seeks():
    rows = [sample(0, 10)]
    names = ['backward', 'forward_available'] + [f'burst_{i}' for i in range(1, 6)]
    for i, (name, target) in enumerate(zip(names, [3, 40, 8, 4, 9, 6, 5])):
        start = i * 2 + 1
        superseded = 2 <= i < 6
        rows.append(sample(start, 10, event='seek', seek=name, target=target, superseded=superseded))
        rows.append(sample(start + .01, target, event='change', status=0))
        rows.append(sample(start + .1, target + .1))
        if not superseded:
            rows.append(sample(start + .2, target + .2))
            rows.append(sample(start + .9, target + .8))
    return rows


class SeekOracleTests(unittest.TestCase):
    def test_intentional_moves_and_superseded_tasks_pass(self):
        result = reliability.seek_metrics(successful_local_seeks())
        self.assertTrue(result['passed'])
        self.assertAlmostEqual(result['seeks'][0]['latency_seconds'], .2)

    def test_optimistic_position_without_advancing_native_clock_fails(self):
        rows = successful_local_seeks()
        for row in rows:
            if 1 < row['t'] < 3:
                row['time'] = 3
        self.assertFalse(reliability.seek_metrics(rows)['seeks'][0]['passed'])

    def test_stale_position_callback_between_samples_fails(self):
        rows = successful_local_seeks()
        rows.insert(8, sample(3.25, 3, time=40.25, event='change'))
        result = reliability.seek_metrics(rows)
        self.assertFalse(result['passed'])
        self.assertEqual(result['seeks'][1]['position_away_samples'], 1)

    def test_native_playback_elsewhere_fails_even_with_optimistic_ui(self):
        rows = successful_local_seeks()
        rows.insert(2, sample(1.05, 3, time=10.05))
        result = reliability.seek_metrics(rows)
        self.assertFalse(result['passed'])
        self.assertEqual(result['seeks'][0]['audible_away_samples'], 1)

    def test_missing_last_scrub_request_fails(self):
        rows = [r for r in successful_local_seeks() if r['t'] < 13]
        self.assertFalse(reliability.seek_metrics(rows)['passed'])

    def test_disabling_automatic_stall_minimization_fails(self):
        rows = successful_local_seeks()
        rows[-1]['automatic_waits'] = False
        self.assertFalse(reliability.seek_metrics(rows)['passed'])

    def test_recorded_progressive_deadlock_and_fixed_clock_convergence(self):
        root = Path(__file__).resolve().parents[2]
        manifest = json.loads((root / 'scripts/playback-research/metrics.json').read_text())['seek_regression']
        for name, entry in manifest['telemetry'].items():
            with self.subTest(fixture=name):
                content = gzip.decompress((root / entry['path']).read_bytes())
                self.assertEqual(hashlib.sha256(content).hexdigest(), entry['sha256'])
                rows = [json.loads(line) for line in content.splitlines()]
                self.assertEqual(len(rows), entry['samples'])
                result = reliability.seek_metrics(rows)
                self.assertTrue(result['preconditions_met'])
                self.assertEqual(result['passed'], name.startswith('after-') or name.endswith('-local'))
                self.assertEqual(result['seeks'], manifest['measurements'][name]['seeks'])

    def test_transition_gap_uses_native_clock_despite_exposed_tick_phase(self):
        rows = [sample(0, 71.5, time=71.8), sample(.1, 71.5, time=71.9),
                sample(.4, 0, time=.05, uri='next'), sample(.6, .5, time=.25, uri='next')]
        result = reliability.metrics(rows)
        self.assertEqual(result['second_track_gap_seconds'], 0)
        self.assertAlmostEqual(result['native_second_track_gap_seconds'], .15)


if __name__ == '__main__':
    unittest.main()
