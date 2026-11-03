"""Offline tests. No credentials, NAS access, or long sleeps."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import test_map_diff as runner


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.mount = self.directory / 'mount' / 'Photos'
        self.mount.mkdir(parents=True)
        self.captures = self.directory / 'captures'
        self.captures.mkdir()
        for name, value in [('MOUNT', self.mount), ('CAPTURES', self.captures)]:
            patcher = patch.object(runner, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.args = runner.arguments([])
        self.run = runner.Runner(self.args)
        self.mounted = patch.object(Path, 'is_mount', return_value=True)
        self.mounted.start()
        self.addCleanup(self.mounted.stop)
        self.run.prepare_root()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def test_environment_preflight_exercises_pinned_pillow_and_jpeg_exif(self):
        environment = runner.check_environment()
        self.assertTrue(environment['jpeg_exif_gps_round_trip'])
        self.assertEqual(environment['pillow'], '12.3.0')

    def test_environment_preflight_fails_before_nas_access_when_pillow_missing(self):
        with patch.object(runner.importlib.metadata, 'version', side_effect=runner.importlib.metadata.PackageNotFoundError), \
                patch.object(runner, 'load_env') as credentials, patch.object(runner.Runner, 'prepare_root') as mount:
            with self.assertRaises(runner.ExperimentError):
                runner.check_environment()
        credentials.assert_not_called()
        mount.assert_not_called()

    def test_generated_exif_has_equal_time_gps_and_unique_pixels(self):
        first = self.directory / 'first.jpg'
        second = self.directory / 'second.jpg'
        runner.fixture(first, 1, [12.25, -34.5])
        runner.fixture(second, 2, [12.25, -34.5])
        with Image.open(first) as image:
            self.assertEqual(image.getexif().get_ifd(34665)[36867], '2020:01:01 12:00:00')
            gps = image.getexif().get_ifd(34853)
            self.assertEqual(gps[1], 'N')
            self.assertEqual(gps[3], 'W')
            pixels = image.tobytes()
        with Image.open(second) as image:
            self.assertNotEqual(pixels, image.tobytes())
        runner.fixture(second, 1, None, day=2)
        with Image.open(second) as image:
            self.assertFalse(image.getexif().get_ifd(34853))
            self.assertEqual(image.getexif().get_ifd(34665)[36867], '2020:01:02 12:00:00')

    def test_journal_recovers_unsaved_manifest_and_cleanup_preserves_other_files(self):
        self.run.put(1)
        unrelated = self.run.root / 'existing.jpg'
        unrelated.write_bytes(b'existing user data')
        args = runner.arguments(['--resume', str(self.run.directory)])
        resumed = runner.Runner(args)
        self.assertIn(self.run.filename(1), resumed.state['files'])
        resumed.remove([1])
        self.assertTrue(unrelated.exists())
        self.assertFalse((resumed.root / resumed.filename(1)).exists())
        with self.assertRaises(runner.ExperimentError):
            resumed.remove([2])

    def test_symlink_and_disconnected_mount_refused(self):
        outside = self.directory / 'untouched.jpg'
        outside.write_bytes(b'untouched')
        target = self.run.root / self.run.filename(1)
        target.symlink_to(outside)
        with self.assertRaises(runner.ExperimentError):
            self.run.put(1)
        self.assertEqual(outside.read_bytes(), b'untouched')
        with patch.object(Path, 'is_mount', return_value=False):
            with self.assertRaises(runner.ExperimentError):
                self.run.put(2)
        self.assertFalse((self.run.root / self.run.filename(2)).exists())

    def test_no_mutating_nas_api_is_admitted(self):
        client = runner.Client({'NAS_URL': 'https://nas.example.invalid', 'USER': 'test', 'PW': 'never-sent'}, lambda *_, **__: None)
        with self.assertRaises(runner.ExperimentError):
            client.call('/webapi/entry.cgi', {'api': 'SYNO.Foto.Browse.Item', 'method': 'delete'})

    def test_missing_diff_arrays_are_not_empty_success(self):
        with self.assertRaises(runner.ExperimentError):
            runner.empty_diff({'diff_version': 1, 'version_time': 2, 'item': {'modify': [], 'delete': []}})

    def test_feed_visibility_gap_is_retained_after_later_convergence(self):
        stage = {'name': 'test', 'started': 0, 'before': []}
        item = {'id': 1, 'time': 10, 'additional': {}}
        delta = self.delta()
        self.run.observe(stage, [item], delta, 100)
        self.assertTrue(stage['observed_feed_gap'])
        delta['item']['modify'] = [{'id': 1}]
        self.run.observe(stage, [item], delta, 100)
        self.assertTrue(stage['observed_feed_gap'])

    def test_complete_batch_advances_after_90_seconds_before_per_photo_timeout(self):
        class Clock:
            current = 1000
            def time(self): return self.current
            def sleep(self, seconds): self.current += seconds
        clock = Clock()
        stage = {'name': 'test', 'started': 0, 'written': 1000, 'count': 10000, 'before': []}
        class Client:
            def scan(self): return []
            def diff(self, _): return RunnerTests.delta(), 100
        stage['cursor'] = {'diff_version': 1, 'version_time': 2}
        self.run.client = Client()
        with patch.object(runner.time, 'time', clock.time), patch.object(runner.time, 'sleep', clock.sleep):
            self.run.settle(stage)
        self.assertEqual(clock.current, 1090)

    def test_quiet_window_starts_only_when_expected_content_is_ready(self):
        class Clock:
            current = 1000
            def time(self): return self.current
            def sleep(self, seconds): self.current += seconds
        clock = Clock()
        class Client:
            def scan(self): return []
            def diff(self, _): return RunnerTests.delta(), 100
        self.run.client = Client()
        stage = {'name': 'late', 'started': 0, 'written': 1000, 'count': 100,
                 'before': [], 'cursor': {'diff_version': 1, 'version_time': 2}}
        with patch.object(runner.time, 'time', clock.time), patch.object(runner.time, 'sleep', clock.sleep), \
                patch.object(self.run, 'matches', side_effect=lambda rows: clock.current >= 1060):
            self.run.settle(stage)
        self.assertEqual(clock.current, 1150)

    def test_absent_files_timeout_instead_of_reporting_success(self):
        self.run.state['files']['missing.jpg'] = {'index': 1, 'gps': None, 'day': 1, 'variant': 0}
        class Client:
            def scan(self): return []
            def diff(self, _): return RunnerTests.delta(), 100
        self.run.client = Client()
        stage = {'name': 'missing', 'started': 0, 'written': 0, 'count': 1,
                 'before': [], 'cursor': {'diff_version': 1, 'version_time': 2}}
        with patch.object(runner.time, 'time', return_value=10000):
            with self.assertRaises(runner.ExperimentError):
                self.run.settle(stage)

    def test_report_contains_counts_without_cursors_ids_or_filenames(self):
        class Client:
            def diff(self, cursor): return RunnerTests.delta(), 100
        self.run.client = Client()
        stage = {'name': 'test', 'started': 0, 'before': [],
                 'cursor': {'diff_version': 987654321, 'version_time': 123456789}}
        self.run.evaluate(stage, [], self.delta(), 100)
        report = (self.run.directory / 'report.json').read_text()
        self.assertNotIn('987654321', report)
        self.assertNotIn('123456789', report)
        self.assertEqual(json.loads(report)['results'][0]['status'], 'pass')

    def test_failed_comparison_explains_mismatches_and_retains_full_evidence(self):
        class Client:
            def diff(self, cursor): return RunnerTests.delta(), 100
        self.run.client = Client()
        old = {'id': 81234567, 'time': 10, 'additional': {}}
        new = {'id': 81234567, 'time': 20, 'additional': {}}
        stage = {'name': 'missing-event', 'started': 0, 'before': [old],
                 'cursor': {'diff_version': 1, 'version_time': 2}}
        self.run.evaluate(stage, [new], self.delta(), 100)
        report = json.loads((self.run.directory / 'report.json').read_text())['results'][0]
        self.assertEqual(report['status'], 'fail')
        self.assertFalse(report['checks']['expected_modifications_reported'])
        self.assertEqual(report['changed_fields']['capture_time'], 1)
        self.assertIn('expected_modifications_reported', report['explanation'])
        self.assertNotIn('81234567', json.dumps(report))
        with runner.gzip.open(self.run.directory / report['evidence'], 'rt') as stream:
            evidence = json.load(stream)
        self.assertEqual(evidence['missing_modified'], [81234567])
        self.assertEqual(evidence['after'][0]['time'], 20)
        self.assertIn('fence', evidence)

    def test_evidence_never_saves_unrecognized_response_or_auth_fields(self):
        delta = self.delta()
        delta['sid'] = 'private-session'
        delta['synotoken'] = 'private-token'
        delta['item']['modify'] = [{'id': 1, 'filename': 'private-filename', 'passwd': 'private-password'}]
        path = self.run.evidence({'name': 'safe'}, 'response', interval=delta)
        with runner.gzip.open(self.run.directory / path, 'rt') as stream:
            saved = stream.read()
        for value in ('private-session', 'private-token', 'private-filename', 'private-password'):
            self.assertNotIn(value, saved)
        self.assertEqual(json.loads(saved)['interval']['item']['modify'], [{'id': 1}])

    def test_request_telemetry_excludes_authentication_material(self):
        events = []
        client = runner.Client({'NAS_URL': 'https://nas.example.invalid', 'USER': 'synthetic-user', 'PW': 'private-password'},
                               lambda event, **fields: events.append({'event': event, **fields}))
        payload = {'success': True, 'data': {'sid': 'private-session', 'synotoken': 'private-token'}}
        with patch.object(client.opener, 'open', return_value=io.BytesIO(json.dumps(payload).encode())):
            client.call('/webapi/entry.cgi', {'api': 'SYNO.API.Auth', 'method': 'login', 'version': '6',
                        'account': 'synthetic-user', 'passwd': 'private-password', 'otp_code': 'private-otp'})
        output = json.dumps(events)
        for value in ('synthetic-user', 'private-password', 'private-session', 'private-token', 'private-otp'):
            self.assertNotIn(value, output)
        self.assertEqual(events[0]['api'], 'SYNO.API.Auth')
        self.assertGreater(events[0]['response_bytes'], 0)
        self.assertIn('elapsed_seconds', events[0])

    def test_resume_cannot_escape_capture_root(self):
        with self.assertRaises(runner.ExperimentError):
            runner.Runner(runner.arguments(['--resume', str(self.directory / 'unrelated')]))

    def test_slow_observation_still_leaves_time_for_batch_writes(self):
        class Clock:
            current = 100
            def monotonic(self): return self.current
        clock = Clock()
        class Client:
            scans = 0
            def scan(self):
                self.scans += 1
                clock.current += 100
                return []
            def diff(self, start): return RunnerTests.delta(), 100
        self.run.client = Client()
        self.run.state['active'] = 'writing'
        self.run.state['stages']['writing'] = {'name': 'writing', 'phase': 'mutating', 'started': 0, 'before': [],
                                               'cursor': {'diff_version': 1, 'version_time': 2}}
        with patch.object(runner.time, 'monotonic', clock.monotonic):
            self.run.observe_writes()
            self.run.observe_writes()
        self.assertEqual(self.run.client.scans, 1)

    def test_overlapping_scan_uses_two_sessions_and_terminal_short_page(self):
        client = runner.Client({'NAS_URL': 'https://nas.example.invalid', 'USER': 'test', 'PW': 'never-sent'}, lambda *_, **__: None)
        client.page = lambda offset, limit, folder_id: [{'id': i} for i in range(offset, min(offset + limit, 1201))]
        class Partner:
            requests = bytes = 0
            def __init__(self, *args): pass
            def authenticate(self): pass
            def logout(self): pass
            def page(self, offset, limit, folder_id): return client.page(offset, limit, folder_id)
        with patch.object(runner, 'Client', Partner):
            rows = client.scan(overlap=True)
        self.assertEqual([r['id'] for r in rows], list(range(1201)))

    def test_lookup_omission_cannot_become_a_tombstone(self):
        client = runner.Client({'NAS_URL': 'https://nas.example.invalid', 'USER': 'test', 'PW': 'never-sent'}, lambda *_, **__: None)
        with patch.object(client, 'read', return_value={'list': [{'id': 1}]}):
            with self.assertRaises(runner.ExperimentError):
                client.lookup([1, 2])

    def test_new_run_cleans_old_journal_files_but_preserves_reports_and_unowned_files(self):
        self.run.put(7)
        owned = self.run.root / self.run.filename(7)
        unowned = self.run.root / 'user-photo.jpg'
        unowned.write_bytes(b'preserve')
        report = self.run.directory / 'report.json'
        report.write_text('{"previous": true}')
        fresh = runner.Runner(runner.arguments([]))
        fresh.prepare_root()
        class Clock:
            current = 1000
            def time(self): return self.current
            def sleep(self, seconds): self.current += seconds
        clock = Clock()
        class Client:
            def scan(self): return []
        fresh.client = Client()
        with patch.object(runner.time, 'time', clock.time), patch.object(runner.time, 'sleep', clock.sleep):
            fresh.cleanup_previous_runs()
        self.assertFalse(owned.exists())
        self.assertTrue(unowned.exists())
        self.assertEqual(report.read_text(), '{"previous": true}')
        self.assertTrue(fresh.state['stages']['startup-cleanup']['ready'])
        self.assertEqual(clock.current, 1090)
        restored = runner.Runner(runner.arguments(['--resume', str(self.run.directory)]))
        self.assertFalse(restored.state['files'])

    def test_cleanup_waits_for_already_unlinked_file_to_disappear_from_api(self):
        self.run.put(0)
        self.run.remove([0])
        self.assertFalse(self.run.state['files'])
        class Clock:
            current = 1000
            def time(self): return self.current
            def sleep(self, seconds): self.current += seconds
        clock = Clock()
        name = self.run.filename(0)
        class Client:
            def scan(self): return [{'id': 1, 'filename': name, 'time': 1, 'additional': {}}]
        self.run.client = Client()
        with patch.object(runner.time, 'time', clock.time), patch.object(runner.time, 'sleep', clock.sleep):
            with self.assertRaises(runner.ExperimentError):
                self.run.cleanup_current('seed-cleanup', [0])
        self.assertEqual(self.run.state['stages']['seed-cleanup']['last_observation']['remaining_generated_items'], 1)

    def test_safety_failure_is_not_swallowed_as_an_ordinary_test_failure(self):
        with self.assertRaises(runner.SafetyError):
            self.run.attempt('unsafe', lambda: (_ for _ in ()).throw(runner.SafetyError('Test safety stop.')))

    def test_failed_dependency_is_skipped_but_unrelated_test_runs(self):
        self.run.attempt('failed-fixture', lambda: (_ for _ in ()).throw(runner.ExperimentError('Fixture timeout.')))
        invoked = []
        self.run.attempt('dependent', lambda: invoked.append('dependent'), requires=('failed-fixture',))
        self.run.attempt('independent', lambda: invoked.append('independent'))
        self.assertEqual(invoked, ['independent'])
        self.assertEqual(self.run.state['stages']['dependent']['phase'], 'skipped')

    def test_complete_run_with_simulated_nas_and_clock(self):
        self.exercise_complete_run()

    def test_gps_timeout_does_not_stop_independent_overnight_tests(self):
        self.exercise_complete_run(sticky_gps=True)
        self.assertEqual(self.run.state['stages']['gps-removal']['phase'], 'failed')
        self.assertFalse(self.run.state['stages']['gps-removal']['ready'])
        self.assertTrue(self.run.state['stages']['capture-time-change']['ready'])
        self.assertTrue(self.run.state['stages']['large-add-2501']['ready'])
        self.assertGreater(self.run.state['stages']['large-add-2501']['bytes'], 4 * 1024 * 1024)
        skipped = [r for r in self.run.state['results'] if r['test'] == 'gps-removal-identity']
        self.assertEqual(skipped[0]['status'], 'skipped')

    def exercise_complete_run(self, sticky_gps=False):
        run = self.run
        run.args.large_max = run.args.large_start = 2501
        run.args.cursor_age_seconds = 120
        run.args.seconds_per_photo = 0.001
        run.args.poll_seconds = 60
        class Clock:
            current = 1000.0
            def time(self): return self.current
            def sleep(self, seconds): self.current += seconds
        clock = Clock()
        events = []
        revisions = {}
        class Client:
            sid = 'synthetic-session'
            requests = bytes = 0
            def __init__(self, *args): pass
            def authenticate(self): pass
            def logout(self): self.sid = None
            def read(self, *args, **kwargs):
                return {'SYNO.Foto.Browse.Diff': {'minVersion': 1, 'maxVersion': 7}}
            def version(self): return {'diff_version': len(events), 'version_time': 2}
            def scan(self, limit=1000, overlap=False, folder_id=None, hook=None):
                if hook: hook()
                result = []
                for name, spec in run.state['files'].items():
                    gps = spec['gps']
                    if sticky_gps and run.state.get('active') == 'gps-removal' and spec['index'] == 0 and gps is None:
                        gps = [12.25, 34.5]
                    result.append({'id': spec['index'] + 1, 'filename': name, 'folder_id': 1,
                        'time': int(runner.dt.datetime(2020, 1, spec['day'], 12, tzinfo=runner.dt.timezone.utc).timestamp()),
                        'additional': {'gps': None if gps is None else {'latitude': gps[0], 'longitude': gps[1]},
                                       'thumbnail': {'unit_id': spec['index'] + 1000000, 'cache_key': str(revisions[name])}}})
                return sorted(result, key=lambda r: (-r['time'], r['id']))
            def lookup(self, ids): return [r for r in self.scan() if r['id'] in ids]
            def diff(self, start):
                changed = events[start['diff_version']:]
                latest = {item: action for action, item in changed}
                data = {'diff_version': len(events), 'version_time': 2,
                        'item': {'modify': [{'id': i} for i, op in latest.items() if op == 'put'],
                                 'delete': [i for i, op in latest.items() if op == 'remove']},
                        'album': {'modify': [], 'delete': []}}
                return data, 5 * 1024 * 1024 if len(latest) > 2000 else 100
        def put(index, gps=None, day=1, variant=0):
            name = run.filename(index)
            run.state['files'][name] = {'index': index, 'gps': gps, 'day': day, 'variant': variant}
            revisions[name] = revisions.get(name, 0) + 1
            events.append(('put', index + 1))
            run.observe_writes()
        def remove(indices):
            for index in indices:
                del run.state['files'][run.filename(index)]
                events.append(('remove', index + 1))
                run.observe_writes()
        run.client_factory = Client
        with patch.object(runner, 'load_env', return_value={'USER': 'phototest', 'PW': 'synthetic'}), \
                patch.object(run, 'put', put), patch.object(run, 'remove', remove), \
                patch.object(runner.time, 'time', clock.time), patch.object(runner.time, 'monotonic', clock.time), \
                patch.object(runner.time, 'sleep', clock.sleep):
            run.run()
        self.assertFalse(run.state['files'])
        self.assertTrue(run.state['stages']['final-cleanup']['done'])
        self.assertTrue(run.state['stages']['cursor-aging']['done'])
        self.assertTrue(run.state['stages']['pagination']['done'])
        self.assertFalse([r for r in run.state['results'] if r['status'] == 'fail'])

    @staticmethod
    def delta():
        return {'diff_version': 1, 'version_time': 2,
                'item': {'modify': [], 'delete': []}, 'album': {'modify': [], 'delete': []}}


if __name__ == '__main__':
    unittest.main()
