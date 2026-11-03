"""Offline protocol/continuation and owned bulk workflow checks for runner three."""
import copy
import gzip
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import test_map_diff as common
import test_map_diff_mobile as mobile
import test_map_diff_focused_runner as harness_module


def delta(ids=(), deleted=(), **extra):
    return {'diff_version': 1, 'version_time': 1, 'has_next': False,
            'item': {'modify': [{'id': i} for i in ids], 'delete': list(deleted), 'merge': [], 'move': []},
            'similar': [], **extra}


class ProtocolTests(unittest.TestCase):
    def client(self):
        return mobile.MobileClient({'NAS_URL': 'https://nas.example.invalid'}, lambda *a, **k: None)

    def test_actual_v7_request_and_no_fabricated_album(self):
        c = self.client()
        c.last_bytes = 10
        with patch.object(c, 'read', return_value=delta([4])) as read:
            result, _ = c.diff({'diff_version': 0, 'version_time': 1})
        self.assertEqual(read.call_args.args, ('SYNO.Foto.Browse.Diff', 'list', 7))
        self.assertEqual(json.loads(read.call_args.kwargs['additional']), mobile.FIELDS)
        self.assertNotIn('album', result)
        self.assertEqual(common.diff_groups(result), ([4], []))

    def test_partial_interval_saved_before_rejection(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            c = self.client(); c.directory = Path(root); c.last_bytes = 50
            with patch.object(c, 'read', return_value=delta([4], has_next=True)):
                with self.assertRaisesRegex(common.ExperimentError, 'continuation'):
                    c.diff({'diff_version': 0, 'version_time': 1})
            files = list(Path(root).glob('mobile-responses/*.json.gz'))
            self.assertEqual(len(files), 1)
            with gzip.open(files[0], 'rt') as f:
                self.assertIs(json.load(f)['response']['has_next'], True)

    def test_completeness_and_unknown_shapes_fail_closed(self):
        for bad in (delta(has_next='false'), delta(unrecognized=[]), {'diff_version': 1, 'version_time': 1}):
            with self.subTest(bad=bad), self.assertRaises(common.ExperimentError):
                c = self.client(); c.last_bytes = 0
                with patch.object(c, 'read', return_value=bad): c.diff({'diff_version': 0, 'version_time': 1})

    def test_merge_move_similar_are_activity(self):
        d = delta()
        for key in ('merge', 'move'):
            d['item'][key] = [12]
        d['similar'] = [{}]
        self.assertFalse(common.empty_diff(d))
        self.assertEqual(common.diff_activity(d), {'merge': 1, 'move': 1, 'similar': 1})

    def test_keyset_walk_excludes_boundary_and_rejects_repetition(self):
        c = self.client()
        with patch.object(c, 'read', side_effect=[{'list': [{'id': 8}, {'id': 5}]}, {'list': [{'id': 2}]}]) as read:
            self.assertEqual([r['id'] for r in c.scan(limit=2)], [8, 5, 2])
            self.assertEqual(read.call_args.kwargs['id_before'], 5)
        with patch.object(c, 'read', side_effect=[{'list': [{'id': 8}, {'id': 5}]}, {'list': [{'id': 5}]}]):
            with self.assertRaises(common.ExperimentError): c.scan(limit=2)

    def test_photo_write_endpoint_is_blocked(self):
        c = self.client()
        with self.assertRaisesRegex(common.ExperimentError, 'Blocked'):
            c.read('SYNO.Foto.Browse.Item', 'set', 7, id='[1]')

    def test_lookup_is_batched(self):
        c = self.client()
        with patch.object(mobile.focused.FocusedClient, 'optional_lookup', side_effect=lambda ids: [{'id': i} for i in ids]) as lookup:
            self.assertEqual(len(c.optional_lookup(list(range(250)))), 250)
            self.assertEqual([len(x.args[0]) for x in lookup.call_args_list], [100, 100, 50])


class MobileNAS(harness_module.SimulatedNAS):
    def sync(self):
        for spec in self.runner.state['files'].values():
            spec.setdefault('capture_time', f"2020-01-{spec.get('day', 1):02d}T12:00:00+00:00")
        super().sync()

    def diff(self, cursor):
        self.sync()
        latest = {i: op for op, i, _ in self.events[cursor['diff_version']:]}
        d = delta([i for i, op in latest.items() if op == 'modify'], [i for i, op in latest.items() if op == 'delete'])
        d['diff_version'] = len(self.events)
        return d, len(json.dumps(d))


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        # Reuse only the existing temporary mount/clock harness, not its v1 tests.
        harness = harness_module.FocusedTests()
        harness.setUp()
        self.addCleanup(harness.doCleanups)
        self.clock = harness.clock
        args = mobile.arguments(['--bulk-count', '0'])
        args.bulk_count = 3  # Small offline equivalent of a live >1000-item batch.
        self.runner = mobile.MobileRunner(args)
        self.runner.prepare_root()
        self.runner.client = MobileNAS(self.runner)
        self.runner.state['stages']['startup-cleanup'] = {'ready': True, 'done': True}

    def test_focused_gps_case_uses_v7_shape_and_cleans_up(self):
        self.runner.run_case('current', 'gps-gain', 17)
        rows = self.runner.state['results']
        self.assertTrue(all(r['status'] == 'pass' for r in rows), rows)
        self.assertFalse(self.runner.state['files'])

    def test_bulk_copy_then_wait_add_delete_replay_and_cleanup(self):
        writes = []
        original = self.runner.put
        def put(*args):
            writes.append(self.clock.time())
            return original(*args)
        with patch.object(self.runner, 'put', side_effect=put):
            self.runner.after_cases()
        results = {r['test']: r for r in self.runner.state['results']}
        self.assertEqual(len(set(writes)), 1)  # No per-photo sleeps.
        for name in ('mobile-bulk-add', 'mobile-bulk-delete', 'mobile-bulk-cleanup'):
            self.assertEqual(results[name]['status'], 'pass', results[name])
        self.assertEqual(results['mobile-bulk-add']['expected_event_count'], 3)
        self.assertFalse(self.runner.state['files'])

    def test_incomplete_feed_does_not_stop_bulk_delete_and_cleanup(self):
        original = self.runner.client.diff
        def diff(cursor):
            if self.runner.state.get('active') == 'mobile-bulk-add' and self.runner.state['files']:
                raise common.ExperimentError('Incomplete mobile interval.')
            return original(cursor)
        self.runner.args.index_timeout_seconds = 20
        self.runner.args.settle_timeout_seconds = 100
        with patch.object(self.runner.client, 'diff', side_effect=diff):
            self.runner.after_cases()
        results = {r['test']: r for r in self.runner.state['results']}
        self.assertEqual(results['mobile-bulk-add']['status'], 'inconclusive')
        self.assertIn('mobile-bulk-delete', results)
        self.assertFalse(self.runner.state['files'])
        self.assertEqual(results['mobile-bulk-cleanup']['status'], 'pass')

    def test_resume_preserves_bulk_settings(self):
        args = mobile.arguments(['--bulk-count', '1200', '--seconds-per-photo', '4'])
        args.resume = self.runner.directory
        resumed = mobile.MobileRunner(args)
        self.assertEqual(resumed.args.bulk_count, 3)
        self.assertEqual(resumed.args.seconds_per_photo, 2)

    def test_other_runner_checkpoint_is_rejected(self):
        args = mobile.arguments(['--bulk-count', '0'])
        args.resume = self.runner.directory
        state = copy.deepcopy(self.runner.state)
        state['runner'] = 'focused-map-diff-v2'
        common.atomic_json(self.runner.state_path, state)
        with self.assertRaises(common.SafetyError): mobile.MobileRunner(args)
