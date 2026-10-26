#!/usr/bin/env python3
"""Second Map/Diff experiment: historical versus current dates, small isolated cases.

Reuses the first runner's authenticated read transport, owned-file journals and
private evidence format. No NAS photo mutation APIs, bulk data or service resets.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import traceback

import test_map_diff as common

RUNNER = 'focused-map-diff-v2'
CASES = ('addition', 'gps-gain', 'gps-change', 'gps-removal', 'capture-time', 'pixels')


class FocusedClient(common.Client):
    def optional_lookup(self, ids):
        if not ids:
            return []
        data = self.read('SYNO.Foto.Browse.Item', 'get', 7,
                         id=json.dumps(ids), additional=common.FIELDS)
        rows = data.get('list')
        if not isinstance(rows, list) or not all(isinstance(row, dict) and common.integer(row.get('id')) for row in rows):
            raise common.ExperimentError('Malformed direct lookup.')
        observed = [row['id'] for row in rows]
        if len(observed) != len(set(observed)) or not set(observed) <= set(ids):
            raise common.ExperimentError('Direct lookup returned duplicate or unexpected IDs.')
        # An omitted ID is an observation, not a deletion verdict. The coordinator
        # also requires an owned unlink plus corroborating listing absence.
        return rows


class FocusedRunner(common.Runner):
    runner_id = RUNNER
    diff_api_version = 1

    def __init__(self, args, client_factory=FocusedClient):
        super().__init__(args, client_factory)
        if args.resume and self.state.get('runner') != self.runner_id:
            raise common.SafetyError('Use a new focused run; this checkpoint belongs to a different runner.')
        if args.resume:
            for name, value in self.state['focused_settings'].items():
                setattr(args, name, value)
        self.state['runner'] = self.runner_id
        self.state['focused_settings'] = {key: getattr(args, key) for key in
            ('index_timeout_seconds', 'settle_timeout_seconds', 'quiet_seconds', 'poll_seconds')}
        self.state.setdefault('known_ids', {})
        self.save()
        self.cleanup_inventory = []

    def observe_writes(self):
        # Cases have one small synchronous write. Observations belong to the
        # focused coordinator, not the bulk runner's inferred inventory deltas.
        pass

    def result(self, name, status, **details):
        super().result(name, status, **details)
        report_path = self.directory / 'report.json'
        report = json.loads(report_path.read_text())
        report.update(runner=self.runner_id, settings=self.state['focused_settings'],
                      focused_settings=self.state['focused_settings'], planned_photos=12)
        common.atomic_json(report_path, report)

    def put_photo(self, index, spec):
        self.check_mount()
        filename = self.filename(index)
        destination = self.root / filename
        if destination.is_symlink() or (destination.exists() and filename not in self.state['files']):
            raise common.SafetyError('Refusing to overwrite an unowned focused fixture.')
        capture = dt.datetime.fromisoformat(spec['capture_time'])
        record = {**spec, 'index': index, 'day': capture.day}
        self.own('put', filename, record)
        self.state['files'][filename] = record
        local = self.directory / 'focused-fixture.tmp.jpg'
        # Same pixels and encoding in both date cohorts; only EXIF dates differ.
        common.fixture(local, 17, gps=spec['gps'], variant=spec['variant'], capture_time=capture)
        with local.open('rb') as source, destination.open('wb') as target:
            target.write(source.read())
            target.flush()
            os.fsync(target.fileno())
        local.unlink()
        self.save()

    def scan_with_retry(self, deadline, purpose):
        retries = 0
        while True:
            try:
                return self.client.scan()
            except common.ExperimentError as error:
                retries += 1
                self.log('observation_retry', purpose=purpose, attempt=retries, reason=str(error),
                         remaining_seconds=round(max(0, deadline - time.time()), 1))
                if time.time() >= deadline:
                    raise common.ExperimentError('No consistent inventory within the observation budget.') from None
                time.sleep(min(self.args.poll_seconds, max(0.1, deadline - time.time())))

    def target(self, index, deadline):
        filename = self.filename(index)
        rows = self.scan_with_retry(deadline, 'discover-or-corroborate-target')
        listed = [row for row in rows if row.get('filename') == filename]
        if len(listed) > 1:
            raise common.ExperimentError('Multiple item identities share the focused fixture filename.')
        ids = set(self.state['known_ids'].get(filename, []))
        ids.update(row['id'] for row in listed)
        self.state['known_ids'][filename] = sorted(ids)
        looked_up = self.client.optional_lookup(sorted(ids))
        folder_rows = []
        if listed:
            folder = listed[0].get('folder_id')
            if not common.integer(folder):
                raise common.ExperimentError('Focused item has no folder ID for independent enumeration.')
            folder_rows = self.scan_folder(folder, deadline)
        folder_matches = [row for row in folder_rows if row.get('filename') == filename]
        by_id = {row['id']: row for row in looked_up}
        item = by_id.get(listed[0]['id']) if listed else (looked_up[0] if len(looked_up) == 1 else None)
        consistent = (not listed and not looked_up) or (
            len(listed) == 1 and len(looked_up) == 1 and len(folder_matches) == 1
            and common.projection(listed[0]) == common.projection(looked_up[0])
            and common.projection(folder_matches[0]) == common.projection(looked_up[0]))
        return {'item': item, 'listed': listed, 'lookup': looked_up, 'folder': folder_matches,
                'consistent': bool(consistent), 'inventory': common.inventory_summary(rows),
                'file_exists': (self.root / filename).exists(), 'known_ids': sorted(ids)}

    def scan_folder(self, folder, deadline):
        while True:
            try:
                return self.client.scan(limit=137, folder_id=folder)
            except common.ExperimentError as error:
                self.log('observation_retry', purpose='independent-folder-enumeration', reason=str(error))
                if time.time() >= deadline:
                    raise
                time.sleep(min(self.args.poll_seconds, max(0.1, deadline - time.time())))

    @staticmethod
    def expected(item, spec):
        if item is None:
            return False
        expected_time = int(dt.datetime.fromisoformat(spec['capture_time']).timestamp())
        if item.get('time') != expected_time:
            return False
        gps = item.get('additional', {}).get('gps')
        if spec['gps'] is None:
            return gps is None
        return isinstance(gps, dict) and all(isinstance(gps.get(key), (float, int)) and abs(gps[key] - value) <= 0.00001
            for key, value in zip(('latitude', 'longitude'), spec['gps']))

    def observe_stage(self, stage, index, spec, delete=False, pixels=False):
        index_deadline = stage['written'] + self.args.index_timeout_seconds
        settle_deadline = None
        stable_since = None
        signature = None
        previous = stage.get('before_item')
        first_gap = stage.get('first_gap_evidence')
        while True:
            deadline = settle_deadline or index_deadline
            try:
                observed = self.target(index, deadline)
                delta, size = self.client.diff(stage['cursor'])
            except common.ExperimentError as error:
                self.log('observation_retry', purpose='target-and-diff', reason=str(error), stage=stage['name'])
                stage['sampling_interrupted'] = True
                stable_since = None
                if time.time() >= deadline:
                    raise common.ExperimentError('Target or Diff could not be read within its bounded observation window.') from None
                time.sleep(min(self.args.poll_seconds, max(0.1, deadline - time.time())))
                continue
            now = time.time()
            item = observed['item']
            modifies, deletes = common.diff_groups(delta)
            if delete:
                ready = not observed['file_exists'] and not observed['listed'] and not observed['lookup']
            else:
                ready = observed['file_exists'] and self.expected(item, spec) and observed['consistent']
                if pixels and previous and item:
                    ready = ready and common.projection(previous)['thumbnail'] != common.projection(item)['thumbnail']
            # Only the controlled item can establish a visibility gap. Arbitrary
            # omissions from a whole-library walk never become tombstones here.
            changed = bool(item and (previous is None or common.projection(item) != common.projection(previous)))
            missing = bool(changed and item['id'] not in modifies) if not delete else bool(
                ready and previous and previous['id'] not in deletes)
            if missing and first_gap is None:
                first_gap = self.evidence(stage, 'first-direct-read-gap', observed=observed, interval=delta)
                stage['first_gap_evidence'] = first_gap
            if item:
                stage.setdefault('first_direct_visible_seconds', now - stage['written'])
            if ready:
                stage.setdefault('first_expected_state_seconds', now - stage['written'])
                if settle_deadline is None:
                    # A late thumbnail revision gets a full bounded settling window,
                    # rather than losing 90-second quiet time to the indexing budget.
                    settle_deadline = now + self.args.settle_timeout_seconds
            if modifies or deletes:
                stage.setdefault('first_feed_activity_seconds', now - stage['written'])
            current = common.digest([common.projection(item) if item else None,
                observed['consistent'], sorted(modifies), sorted(deletes),
                common.diff_activity(delta)])
            if not ready or current != signature:
                stable_since = None
            signature = current
            if ready and stable_since is None:
                stable_since = now
            elapsed_stable = now - stable_since if stable_since is not None else 0
            evidence = self.evidence(stage, 'latest', observed=observed, interval=delta,
                                     expected=spec, ready=ready, deletion=delete)
            stage['last_observation_evidence'] = evidence
            stage['last_observation'] = {'ready': ready, 'consistent': observed['consistent'],
                'file_exists': observed['file_exists'], 'listing_count': len(observed['listed']),
                'direct_lookup_count': len(observed['lookup']), 'folder_count': len(observed['folder']),
                'stable_seconds': round(elapsed_stable, 1), 'diff': common.diff_summary(delta)}
            self.log('focused_observation', stage=stage['name'], **stage['last_observation'],
                elapsed_seconds=round(now - stage['written'], 1), required_stable_seconds=self.args.quiet_seconds,
                remaining_seconds=round(max(0, (settle_deadline or index_deadline) - now), 1),
                target_ref=self.reference(item['id']) if item else None,
                corroborated_missing_event=missing, diff_bytes=size, evidence=evidence)
            self.save()
            if ready and elapsed_stable >= self.args.quiet_seconds:
                return observed, delta, size
            if now >= (settle_deadline or index_deadline):
                raise common.ExperimentError('Expected target state or the required quiet window was not established before its deadline.')
            time.sleep(min(self.args.poll_seconds, max(0.1, (settle_deadline or index_deadline) - time.time())))

    def mutation(self, name, index, spec, delete=False, pixels=False):
        stage = self.state['stages'].get(name)
        if stage and stage.get('done'):
            return
        if stage is None:
            start = self.client.version()
            before = self.target(index, time.time() + self.args.index_timeout_seconds)
            quiet, _ = self.client.diff(start)
            if delete and (before['item'] is None or not before['consistent']):
                raise common.ExperimentError('Deletion test needs a corroborated live target; cleanup will still remove the owned file.')
            if not common.empty_diff(quiet):
                raise common.ExperimentError('Changes occurred during baseline capture; this isolated case is inconclusive.')
            if name.startswith('current-') and name.endswith('-add'):
                # EXIF has whole-second precision. Capture current fixture time
                # after baseline acquisition, rather than minutes before its cursor.
                time.sleep(1.1)
                spec['capture_time'] = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
            stage = {'name': name, 'index': index, 'cursor': start,
                     'before_item': before['item'], 'phase': 'mutating', 'started': time.time()}
            self.state['stages'][name] = stage
            self.state['active'] = name
            self.evidence(stage, 'baseline', observed=before, cursor=start, expected=spec)
            self.log('focused_stage_started', stage=name, deletion=delete, pixel_replacement=pixels,
                     expected_capture_time=spec['capture_time'], expected_gps_present=spec['gps'] is not None,
                     index_timeout_seconds=self.args.index_timeout_seconds,
                     settle_timeout_seconds=self.args.settle_timeout_seconds)
            self.save()
            if delete:
                if self.filename(index) in self.state['files']:
                    self.remove([index])
            else:
                self.put_photo(index, spec)
            stage.update(written=time.time(), phase='observing')
            self.save()
        elif stage['phase'] == 'mutating':
            raise common.ExperimentError('Mutation was interrupted; start a fresh focused run to clean up and recreate its baseline.')
        else:
            stage['resumed'] = True
        observed, interval, size = self.observe_stage(stage, index, spec, delete, pixels)
        stage['ready'] = True
        replay, replay_size = self.client.diff(stage['cursor'])
        fence, _ = self.client.diff(common.cursor(replay))
        # Re-read the exact target after the fence; save it and require the state
        # used for the comparison still holds.
        final = self.target(index, time.time() + self.args.index_timeout_seconds)
        item = observed['item']
        before = stage['before_item']
        modifies, deletes = common.diff_groups(replay)
        expected_ids = {before['id']} if delete and before else ({item['id']} if item else set())
        reported = set(deletes if delete else modifies)
        unchanged = ((item is None and final['item'] is None) or
                     (item and final['item'] and common.projection(item) == common.projection(final['item'])))
        final_ready = (not final['file_exists'] and not final['listed'] and not final['lookup']) if delete else (final['file_exists'] and self.expected(final['item'], spec))
        checks = {'expected_events_reported': expected_ids <= reported,
                  'expected_state_persists': bool(final_ready),
                  'replay_identical': interval == replay, 'final_fence_empty': common.empty_diff(fence),
                  'target_still_consistent': bool(unchanged and final['consistent']),
                  'no_duplicate_events': len(modifies) == len(set(modifies)) and len(deletes) == len(set(deletes)),
                  'no_unhandled_changes': not common.diff_activity(replay),
                  'no_conflicting_events': not (set(modifies) & set(deletes)),
                  'no_direct_visibility_gap': stage.get('first_gap_evidence') is None,
                  'continuous_observation': not (stage.get('sampling_interrupted') or stage.get('resumed'))}
        failures = [key for key, value in checks.items() if not value]
        evidence = self.evidence(stage, 'comparison', before=common.projection(before) if before else None,
            observed=observed, final=final, interval=interval, replay=replay, fence=fence, expected_ids=sorted(expected_ids), checks=checks)
        status = 'fail' if any(key != 'continuous_observation' for key in failures) else ('inconclusive' if failures else 'pass')
        self.result(name, status, explanation='All focused checks passed.' if not failures else 'Unmet checks: ' + ', '.join(failures),
            checks=checks, expected_event_count=len(expected_ids), missing_event_count=len(expected_ids - reported),
            interval=common.diff_summary(interval), replay=common.diff_summary(replay), fence=common.diff_summary(fence),
            max_diff_bytes=max(size, replay_size), same_item_id=bool(before and item and before['id'] == item['id']),
            observed_identity_replacement=bool(before and item and before['id'] != item['id']),
            expected_capture_time=spec['capture_time'], first_expected_state_seconds=stage.get('first_expected_state_seconds'),
            first_feed_activity_seconds=stage.get('first_feed_activity_seconds'),
            write_seconds=round(stage['written'] - stage['started'], 3),
            observation_seconds=round(time.time() - stage['written'], 3), evidence=evidence)
        stage.update(done=True, phase='done')
        self.save()

    def wait_for_absence(self, name, prefixes, count):
        stage = self.state['stages'].setdefault(name, {'name': name})
        self.state['active'] = name
        stage.update(phase='waiting-for-deletion')
        start = time.time()
        deadline = start + self.args.index_timeout_seconds
        settle_deadline = None
        stable_since = None
        signature = None
        known = {row['id'] for row in self.cleanup_inventory
                 if any(row.get('filename', '').startswith(prefix) for prefix in prefixes)}
        for filename, ids in self.state['known_ids'].items():
            if any(filename.startswith(prefix) for prefix in prefixes):
                known.update(ids)
        while True:
            limit = settle_deadline or deadline
            try:
                rows = self.scan_with_retry(limit, 'cleanup-listing')
                direct = self.client.optional_lookup(sorted(known))
            except common.ExperimentError as error:
                self.log('cleanup_observation_retry', reason=str(error), stage=name)
                stable_since = None
                if time.time() >= limit:
                    raise
                time.sleep(min(self.args.poll_seconds, max(0.1, limit - time.time())))
                continue
            remaining = [row for row in rows if any(row.get('filename', '').startswith(prefix) for prefix in prefixes)]
            now = time.time()
            ready = not remaining and not direct
            current = common.inventory_summary(rows)['content_digest']
            if not ready or signature != current:
                stable_since = None
            signature = current
            if ready:
                if settle_deadline is None:
                    settle_deadline = now + self.args.settle_timeout_seconds
                if stable_since is None:
                    stable_since = now
            evidence = self.evidence(stage, 'cleanup-latest', inventory=[common.projection(row) for row in rows],
                                     direct_lookup=[common.projection(row) for row in direct], known_ids=sorted(known))
            self.log('focused_cleanup', stage=name, remaining_list_items=len(remaining),
                     remaining_direct_items=len(direct), known_id_count=len(known),
                     stable_seconds=round(now - stable_since, 1) if stable_since is not None else 0, evidence=evidence)
            self.save()
            if ready and now - stable_since >= self.args.quiet_seconds:
                stage.update(done=True, ready=True, phase='done')
                self.result(name, 'pass', explanation='Owned files absent from listings and known-ID lookups for the quiet window.',
                            removed_files=count, known_id_count=len(known), evidence=evidence)
                return
            if now >= (settle_deadline or deadline):
                raise common.ExperimentError('Focused cleanup could not establish stable corroborated absence.')
            time.sleep(min(self.args.poll_seconds, max(0.1, (settle_deadline or deadline) - time.time())))

    def run_case(self, cohort, case, index):
        label = f'{cohort}-{case}'
        stamp = dt.datetime(2020, 1, 1, 12, tzinfo=dt.timezone.utc) if cohort == 'historical' else dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        recipes = self.state.setdefault('focused_cases', {})
        initial = recipes.setdefault(label, {'capture_time': stamp.isoformat(),
                   'gps': [12.25, 34.5] if case in ('gps-change', 'gps-removal') else None, 'variant': 0})
        self.save()
        addition = label + '-add'
        self.attempt(addition, lambda: self.mutation(addition, index, initial), requires=('startup-cleanup',))
        desired = dict(initial)
        if case != 'addition':
            if case == 'gps-gain': desired['gps'] = [12.25, 34.5]
            if case == 'gps-change': desired['gps'] = [-12.5, 35.25]
            if case == 'gps-removal': desired['gps'] = None
            if case == 'capture-time': desired['capture_time'] = (dt.datetime.fromisoformat(initial['capture_time']) + dt.timedelta(days=1)).isoformat()
            if case == 'pixels': desired['variant'] = 1
            self.attempt(label + '-edit', lambda: self.mutation(label + '-edit', index, desired, pixels=case == 'pixels'),
                         requires=(addition,))
        self.attempt(label + '-delete', lambda: self.mutation(label + '-delete', index, desired, delete=True),
                     requires=(addition,))
        # Even a failed/unobserved addition must be physically removed before the
        # next independent case. This cleanup does not depend on Diff behavior.
        self.attempt(label + '-cleanup', lambda: self.cleanup_current(label + '-cleanup', [index]))

    def cohort_summary(self):
        summary = {}
        for cohort in ('historical', 'current'):
            results = [row for row in self.state['results'] if row['test'].startswith(cohort + '-')]
            summary[cohort] = {operation: {
                'comparisons': sum(row['test'].endswith('-' + operation) and 'expected_event_count' in row for row in results),
                'passed': sum(row['status'] == 'pass' for row in results if row['test'].endswith('-' + operation)),
                'failed': sum(row['status'] == 'fail' for row in results if row['test'].endswith('-' + operation)),
                'direct_visibility_gap_cases': sum(row.get('checks', {}).get('no_direct_visibility_gap') is False for row in results if row['test'].endswith('-' + operation)),
                'expected_events': sum(row.get('expected_event_count', 0) for row in results if row['test'].endswith('-' + operation)),
                'missing_events': sum(row.get('missing_event_count', 0) for row in results if row['test'].endswith('-' + operation)),
                'inconclusive_or_skipped': sum(row['status'] in ('inconclusive', 'skipped') for row in results if row['test'].endswith('-' + operation))}
                for operation in ('add', 'edit', 'delete')}
        common.atomic_json(self.directory / 'cohort-summary.json', {
            'cohorts': summary, 'interpretation': 'Compare coverage only for corroborated completed stages; these observations do not prove a universal date filter.'})
        self.log('cohort_summary', cohorts=summary)

    def protocol_preflight(self):
        pass

    def after_cases(self):
        pass

    def run(self):
        credentials = common.load_env(common.PROJECT / '.env')
        if credentials['USER'] != 'phototest':
            raise common.SafetyError('Focused experiments require the configured phototest account.')
        self.prepare_root()
        self.client = self.client_factory(credentials, self.log, self.args.verify_tls)
        try:
            self.client.authenticate()
            self.cleanup_inventory = self.scan_with_retry(time.time() + self.args.index_timeout_seconds, 'startup-inventory')
            if self.args.cleanup:
                self.cleanup_current('explicit-cleanup')
                return
            self.protocol_preflight()
            self.log('focused_started', runner=self.runner_id, settings=self.state['focused_settings'],
                     cases=list(CASES), cohorts=['historical', 'current'], diff_api_version=self.diff_api_version)
            if not self.args.resume:
                self.attempt('startup-cleanup', self.cleanup_previous_runs)
            for cohort_index, cohort in enumerate(('historical', 'current')):
                for case_index, case in enumerate(CASES):
                    self.run_case(cohort, case, 2000000 + cohort_index * 100 + case_index)
            self.after_cases()
            self.attempt('final-cleanup', lambda: self.cleanup_current('final-cleanup'))
            self.cohort_summary()
            outcomes = {status: sum(row['status'] == status for row in self.state['results'])
                        for status in ('pass', 'fail', 'inconclusive', 'skipped')}
            self.log('focused_finished', outcomes=outcomes, requests=self.client.requests, response_bytes=self.client.bytes)
        finally:
            if self.client.sid:
                with contextlib.suppress(Exception): self.client.logout()


def arguments(argv=None, *, parser=None):
    parser = parser or argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume', type=Path)
    parser.add_argument('--cleanup', action='store_true')
    parser.add_argument('--poll-seconds', type=float, default=15)
    parser.add_argument('--quiet-seconds', type=float, default=90)
    parser.add_argument('--index-timeout-seconds', type=float, default=600)
    parser.add_argument('--settle-timeout-seconds', type=float, default=600)
    parser.add_argument('--verify-tls', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parsed = parser.parse_args(argv)
    timings = (parsed.poll_seconds, parsed.quiet_seconds, parsed.index_timeout_seconds, parsed.settle_timeout_seconds)
    if not all(math.isfinite(value) for value in timings) or min(timings) <= 0 or parsed.settle_timeout_seconds < parsed.quiet_seconds:
        parser.error('Positive timings are required; settling allowance must cover the quiet window.')
    if parsed.cleanup and not parsed.resume: parser.error('--cleanup requires --resume')
    # Reuse the shared ownership/checkpoint model; no bulk stages are executed.
    values = vars(common.arguments([]))
    values.update(vars(parsed))
    return argparse.Namespace(**values)


def main(argv=None, *, runner_class=FocusedRunner, argument_parser=arguments):
    os.umask(0o077)
    args = argument_parser(argv)
    if args.dry_run:
        print(json.dumps({'runner': runner_class.runner_id, 'bulk_count': getattr(args, 'bulk_count', 0), 'diff_api_version': runner_class.diff_api_version, 'cohorts': ['January 2020', 'current UTC capture wall time'],
            'cases': list(CASES), 'total_generated_photos': len(CASES) * 2 + getattr(args, 'bulk_count', 0),
            'maximum_live_photos': max(1, getattr(args, 'bulk_count', 0)),
            'bulk_index_timeout_seconds': max(args.index_timeout_seconds, getattr(args, 'bulk_count', 0) * args.seconds_per_photo),
            'quiet_seconds': args.quiet_seconds, 'index_timeout_seconds': args.index_timeout_seconds,
            'settle_timeout_seconds': args.settle_timeout_seconds, 'output_parent': str(common.CAPTURES)}, indent=2))
        return 0
    instance = None
    awake = None
    try:
        environment = common.check_environment()
        with (common.CAPTURES / '.map-diff-run.lock').open('a') as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: raise common.SafetyError('Another Map/Diff runner is active.') from None
            instance = runner_class(args)
            instance.log('environment_ready', **{k: value for k, value in environment.items() if k != 'event'},
                         focused_source_digest=common.digest(Path(__file__).read_text()))
            print('Run output: ' + str(instance.directory), flush=True)
            if sys.platform == 'darwin': awake = subprocess.Popen(['/usr/bin/caffeinate', '-i', '-w', str(os.getpid())])
            instance.run()
            if args.cleanup: return 0 if instance.state['stages'].get('explicit-cleanup', {}).get('ready') else 2
            if not instance.state['stages'].get('startup-cleanup', {}).get('ready'): return 2
            if any(row['status'] == 'fail' for row in instance.state['results']): return 1
            if getattr(instance, 'strict_results', False) and any(row['status'] in ('inconclusive', 'skipped') for row in instance.state['results']): return 2
            return 0
    except (KeyboardInterrupt, Exception) as error:
        reason = str(error) if isinstance(error, common.ExperimentError) else 'Focused runner stopped; private exception details suppressed.'
        if instance:
            instance.result(instance.state.get('active') or 'runner', 'inconclusive', reason=reason,
                exception_type=type(error).__name__, stack=[{'file': Path(frame.filename).name, 'function': frame.name, 'line': frame.lineno}
                                                           for frame in traceback.extract_tb(error.__traceback__)])
        else: print(reason, file=sys.stderr)
        return 130 if isinstance(error, KeyboardInterrupt) else 2
    finally:
        if awake:
            awake.terminate()
            awake.wait()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, common.interrupt)
    raise SystemExit(main())
