"""Focused runner verification: local fixtures and a simulated NAS/clock only."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import test_map_diff as common
import test_map_diff_focused as focused


class Clock:
    def __init__(self): self.current = 1000.0
    def time(self): return self.current
    def sleep(self, seconds): self.current += seconds


class SimulatedNAS:
    requests = bytes = 0
    sid = 'simulated'
    def __init__(self, runner):
        self.runner = runner
        self.rows = {}
        self.specs = {}
        self.events = []
        self.sequence = 1
        self.transient_scans = 0
    def authenticate(self): pass
    def logout(self): self.sid = None
    def sync(self):
        files = self.runner.state['files']
        for name in set(self.rows) - set(files):
            self.events.append(('delete', self.rows[name]['id'], None))
            del self.rows[name]
            self.specs.pop(name, None)
        for name, spec in files.items():
            if self.specs.get(name) == spec: continue
            item_id = self.rows[name]['id'] if name in self.rows else self.sequence
            self.sequence += 1
            stamp = focused.dt.datetime.fromisoformat(spec['capture_time'])
            gps = spec['gps']
            self.rows[name] = {'id': item_id, 'filename': name, 'folder_id': 77, 'time': int(stamp.timestamp()),
                'additional': {'gps': None if gps is None else {'latitude': gps[0], 'longitude': gps[1]},
                               'thumbnail': {'unit_id': item_id + 100, 'cache_key': str(self.sequence)}}}
            self.specs[name] = copy.deepcopy(spec)
            self.events.append(('modify', item_id, stamp.year))
    def version(self):
        self.sync()
        return {'diff_version': len(self.events), 'version_time': 1}
    def scan(self, **kwargs):
        self.sync()
        if self.transient_scans:
            self.transient_scans -= 1
            raise common.ExperimentError('Duplicate IDs in a positional scan.')
        return copy.deepcopy(list(self.rows.values()))
    def optional_lookup(self, ids):
        self.sync()
        return copy.deepcopy([row for row in self.rows.values() if row['id'] in ids])
    def diff(self, cursor):
        self.sync()
        latest = {item_id: (operation, year) for operation, item_id, year in self.events[cursor['diff_version']:]}
        # Deliberately simulate a date-dependent contract, to test that the report
        # detects differences without asserting that the real NAS has this rule.
        value = {'diff_version': len(self.events), 'version_time': 1,
                 'item': {'modify': [{'id': key} for key, (op, year) in latest.items() if op == 'modify' and year != 2020],
                          'delete': [key for key, (op, _) in latest.items() if op == 'delete']},
                 'album': {'modify': [], 'delete': []}}
        return value, len(json.dumps(value))


class FocusedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.mount = root / 'Photos'
        self.captures = root / 'captures'
        self.mount.mkdir(); self.captures.mkdir()
        for name, value in [('MOUNT', self.mount), ('CAPTURES', self.captures)]:
            patcher = patch.object(common, name, value)
            patcher.start(); self.addCleanup(patcher.stop)
        patcher = patch.object(Path, 'is_mount', return_value=True)
        patcher.start(); self.addCleanup(patcher.stop)
        self.runner = focused.FocusedRunner(focused.arguments([]))
        self.runner.prepare_root()
        self.clock = Clock()
        for name, value in [('time', self.clock.time), ('monotonic', self.clock.time), ('sleep', self.clock.sleep)]:
            patcher = patch.object(common.time, name, value)
            patcher.start(); self.addCleanup(patcher.stop)
        redirect = contextlib.redirect_stdout(io.StringIO())
        redirect.__enter__(); self.addCleanup(redirect.__exit__, None, None, None)

    def test_fixture_cohorts_preserve_pixels_and_encode_distinct_dates(self):
        first = self.runner.directory / 'historical.jpg'
        second = self.runner.directory / 'current.jpg'
        historical = focused.dt.datetime(2020, 1, 1, 12, tzinfo=focused.dt.timezone.utc)
        current = focused.dt.datetime(2026, 10, 26, 12, tzinfo=focused.dt.timezone.utc)
        common.fixture(first, 17, capture_time=historical)
        common.fixture(second, 17, capture_time=current)
        with Image.open(first) as image:
            pixels = image.tobytes()
            self.assertEqual(image.getexif().get_ifd(34665)[36867], '2020:01:01 12:00:00')
        with Image.open(second) as image:
            self.assertEqual(pixels, image.tobytes())
            self.assertEqual(image.getexif().get_ifd(34665)[36867], '2026:10:26 12:00:00')

    def test_transient_duplicate_scan_retries_without_abandoning_stage(self):
        nas = SimulatedNAS(self.runner)
        nas.transient_scans = 2
        self.runner.client = nas
        self.assertEqual(self.runner.scan_with_retry(self.clock.current + 100, 'test'), [])
        self.assertEqual(self.clock.current, 1030)

    def test_direct_lookup_prevents_a_listing_hole_becoming_a_deletion(self):
        spec = {'capture_time': '2020-01-01T12:00:00+00:00', 'gps': None, 'variant': 0}
        self.runner.put_photo(1, spec)
        nas = SimulatedNAS(self.runner)
        self.runner.client = nas
        observed = self.runner.target(1, self.clock.current + 100)
        item_id = observed['item']['id']
        with patch.object(nas, 'scan', return_value=[]):
            observed = self.runner.target(1, self.clock.current + 100)
        self.assertFalse(observed['consistent'])
        self.assertEqual(observed['lookup'][0]['id'], item_id)
        self.assertTrue(observed['file_exists'])

    def test_omitted_known_id_is_not_alone_a_deletion_verdict(self):
        client = focused.FocusedClient({'USER': 'test', 'PW': 'never-sent'}, lambda *args, **kwargs: None)
        with patch.object(client, 'read', return_value={'list': []}):
            self.assertEqual(client.optional_lookup([1]), [])
        with patch.object(client, 'read', return_value={'list': [{'id': 2}]}):
            with self.assertRaises(common.ExperimentError): client.optional_lookup([1])

    def test_late_metadata_revision_gets_full_quiet_window_after_indexing(self):
        spec = {'capture_time': '2020-01-01T12:00:00+00:00', 'gps': None, 'variant': 0}
        stage = {'name': 'late', 'cursor': {'diff_version': 0, 'version_time': 1}, 'written': 1000, 'before_item': None}
        nas = SimulatedNAS(self.runner)
        self.runner.client = nas
        def target(*args):
            elapsed = self.clock.current - 1000
            ready = elapsed >= 590
            item = None if not ready else {'id': 1, 'time': 1577880000, 'additional': {'thumbnail': {'unit_id': 10, 'cache_key': 'late' if elapsed >= 660 else 'early'}}}
            return {'item': item, 'consistent': ready, 'listed': [item] if item else [],
                    'lookup': [item] if item else [], 'folder': [item] if item else [], 'file_exists': True, 'known_ids': [1]}
        with patch.object(self.runner, 'target', side_effect=target):
            self.runner.observe_stage(stage, 1, spec)
        self.assertEqual(self.clock.current, 1750)

    def test_no_gap_claim_from_uncorroborated_deletion(self):
        spec = {'capture_time': '2020-01-01T12:00:00+00:00', 'gps': None, 'variant': 0}
        item = {'id': 1, 'time': 1577880000, 'additional': {}}
        stage = {'name': 'hole', 'cursor': {'diff_version': 0, 'version_time': 1}, 'written': 1000, 'before_item': item}
        self.runner.args.index_timeout_seconds = 30
        self.runner.client = SimulatedNAS(self.runner)
        snapshot = {'item': item, 'consistent': False, 'listed': [], 'lookup': [item], 'folder': [],
                    'file_exists': False, 'known_ids': [1]}
        with patch.object(self.runner, 'target', return_value=snapshot):
            with self.assertRaises(common.ExperimentError): self.runner.observe_stage(stage, 1, spec, delete=True)
        self.assertNotIn('first_gap_evidence', stage)

    def test_full_matrix_reports_date_difference_and_cleans_all_fixtures(self):
        nas = SimulatedNAS(self.runner)
        self.runner.client_factory = lambda *args: nas
        self.runner.args.quiet_seconds = 1
        self.runner.args.poll_seconds = 1
        self.runner.args.index_timeout_seconds = 10
        self.runner.args.settle_timeout_seconds = 10
        with patch.object(common, 'load_env', return_value={'USER': 'phototest', 'PW': 'synthetic'}):
            self.runner.run()
        self.assertFalse(self.runner.state['files'])
        summary = json.loads((self.runner.directory / 'cohort-summary.json').read_text())['cohorts']
        self.assertEqual(summary['historical']['add']['missing_events'], 6)
        self.assertEqual(summary['current']['add']['missing_events'], 0)
        self.assertEqual(summary['current']['delete']['missing_events'], 0)
        self.assertTrue(self.runner.state['stages']['final-cleanup']['ready'])
        self.assertTrue(self.runner.state['stages']['current-pixels-edit']['ready'])

    def test_resume_preserves_case_recipe_and_rejects_bulk_checkpoint(self):
        self.runner.state['focused_cases'] = {'current-addition': {'capture_time': '2026-10-26T12:00:00+00:00', 'gps': None, 'variant': 0}}
        self.runner.save()
        resumed = focused.FocusedRunner(focused.arguments(['--resume', str(self.runner.directory)]))
        self.assertEqual(resumed.state['focused_cases'], self.runner.state['focused_cases'])
        self.runner.state.pop('runner')
        self.runner.save()
        with self.assertRaises(common.SafetyError):
            focused.FocusedRunner(focused.arguments(['--resume', str(self.runner.directory)]))

    def test_index_timeout_is_recorded_and_next_independent_case_can_run(self):
        called = []
        self.runner.attempt('timed-out', lambda: (_ for _ in ()).throw(common.ExperimentError('Expected target did not appear.')))
        self.runner.attempt('next-case', lambda: called.append(True))
        self.assertEqual(called, [True])
        self.assertEqual(self.runner.state['stages']['timed-out']['phase'], 'failed')

    def test_cleanup_retries_and_corroborates_known_ids(self):
        nas = SimulatedNAS(self.runner)
        self.runner.client = nas
        nas.transient_scans = 1
        self.runner.wait_for_absence('cleanup', ['unowned-prefix'], 0)
        self.assertTrue(self.runner.state['stages']['cleanup']['ready'])
        self.assertEqual(self.clock.current, 1105)


if __name__ == '__main__': unittest.main()
