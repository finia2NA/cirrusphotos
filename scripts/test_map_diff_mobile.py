#!/usr/bin/env python3
"""Third unattended experiment: captured Android Diff v7 list, edits and bulk coverage."""
from __future__ import annotations

import argparse
import gzip
import json
import math
from pathlib import Path
import signal
import time
import uuid

import test_map_diff as common
import test_map_diff_focused as focused

FIELDS = ['description', 'exif', 'resolution', 'orientation', 'address', 'gps',
          'geocoding_id', 'thumbnail', 'tag', 'video_meta', 'mobile_cache_mtime',
          'folder', 'rating', 'motion_photo', 'thumb_version', 'duplicate_hash', 'favorite']


class MobileClient(focused.FocusedClient):
    def __init__(self, credentials, log, verify_tls=False, directory=None):
        super().__init__(credentials, log, verify_tls)
        self.directory = directory

    def version(self):
        return common.cursor(self.read('SYNO.Foto.Browse.Diff', 'get_version', 7))

    def diff(self, start):
        data = self.read('SYNO.Foto.Browse.Diff', 'list', 7, **start,
                         geocoding_accept_language='enu', additional=json.dumps(FIELDS))
        size = self.last_bytes
        # Preserve even rejected/partial responses before interpreting them. This
        # endpoint returns metadata only; credentials/headers are never recorded.
        evidence = None
        if self.directory is not None:
            destination = self.directory / 'mobile-responses' / (uuid.uuid4().hex + '.json.gz')
            destination.parent.mkdir(exist_ok=True)
            temporary = destination.with_suffix('.tmp')
            with gzip.open(temporary, 'wt') as stream:
                json.dump({'request_cursor': start, 'response': data}, stream)
            temporary.replace(destination)
            evidence = str(destination.relative_to(self.directory))
        self.log('mobile_diff_response', response_bytes=size, has_next=data.get('has_next'),
                 evidence=evidence, cursor_ref=common.digest({k: data.get(k) for k in ('diff_version', 'version_time')})[:12])
        if 'has_next' not in data:
            raise common.ExperimentError('Mobile Diff omitted required completeness fields.')
        common.diff_groups(data)
        return data, size

    def optional_lookup(self, ids):
        rows = []
        for offset in range(0, len(ids), 100):
            rows.extend(super().optional_lookup(ids[offset:offset + 100]))
        return rows

    def scan(self, limit=1000, overlap=False, folder_id=None):
        if folder_id is not None:
            return super().scan(limit=limit, overlap=overlap, folder_id=folder_id)
        # Candidate keyset walk under test, independently checked against the
        # owned-file inventory and folder offset walks. No guessed Diff cursor.
        boundary = -1
        rows = []
        for page_number in range(2048):
            data = self.read('SYNO.Foto.Browse.Item', 'list_all', 7,
                             id_before=boundary, limit=limit,
                             geocoding_accept_language='enu', additional=json.dumps(FIELDS))
            page = data.get('list')
            if not isinstance(page, list) or not all(isinstance(r, dict) and common.integer(r.get('id')) for r in page):
                raise common.ExperimentError('Malformed mobile inventory page.')
            ids = [r['id'] for r in page]
            if len(page) > limit or any(i <= 0 for i in ids) or any(a <= b for a, b in zip(ids, ids[1:])) or (ids and boundary != -1 and ids[0] >= boundary):
                raise common.ExperimentError('Mobile inventory did not advance in strict descending ID order.')
            rows.extend(page)
            self.log('mobile_inventory_page', page=page_number, page_size=limit,
                     returned_items=len(page), accumulated_items=len(rows))
            if len(page) < limit:
                self.log('mobile_inventory_completed', inventory=common.inventory_summary(rows))
                return rows
            boundary = ids[-1]
        raise common.ExperimentError('Mobile inventory reached its page cap; completeness unproven.')


class MobileRunner(focused.FocusedRunner):
    runner_id = 'mobile-map-diff-v7-list-v1'
    diff_api_version = 7
    strict_results = True

    def __init__(self, args, client_factory=None):
        factory = client_factory or (lambda credentials, log, tls: MobileClient(
            credentials, log, tls, directory=self.directory))
        super().__init__(args, factory)
        settings = self.state.setdefault('mobile_settings', {
            'bulk_count': args.bulk_count, 'seconds_per_photo': args.seconds_per_photo})
        for key, value in settings.items():
            setattr(args, key, value)
        self.save()

    def protocol_preflight(self):
        start = self.client.version()
        response, size = self.client.diff(start)
        self.log('mobile_protocol_ready', interval=common.diff_summary(response), response_bytes=size,
                 note='Read-only current-cursor shape check; coverage remains under test.')

    def run(self):
        self.log('mobile_configuration', protocol_version=7, method='list', bulk_count=self.args.bulk_count,
                 seconds_per_photo=self.args.seconds_per_photo, source_digest=common.digest(Path(__file__).read_text()))
        return super().run()

    def result(self, name, status, **details):
        super().result(name, status, **details)
        report = json.loads((self.directory / 'report.json').read_text())
        report.update(protocol={'api': 'SYNO.Foto.Browse.Diff', 'version': 7, 'method': 'list',
                                'additional': FIELDS, 'continuation': 'unproven; reject has_next=true'},
                      mobile_settings=self.state.get('mobile_settings', {}),
                      planned_photos=12 + self.args.bulk_count)
        common.atomic_json(self.directory / 'report.json', report)

    def wait_for_absence(self, name, prefixes, count):
        original = self.args.index_timeout_seconds
        self.args.index_timeout_seconds = max(original, self.args.bulk_count * self.args.seconds_per_photo)
        try:
            return super().wait_for_absence(name, prefixes, count)
        finally:
            self.args.index_timeout_seconds = original

    def bulk_observation(self, stage):
        start = stage['written']
        index_deadline = start + max(self.args.index_timeout_seconds, stage['count'] * self.args.seconds_per_photo)
        settle_deadline = None
        stable_since = None
        signature = None
        while True:
            deadline = settle_deadline or index_deadline
            try:
                rows = self.client.scan()
                ready = self.matches(rows)
                prefix = 'synotest-' + self.state['owner'][:12] + '-'
                for row in rows:
                    if row.get('filename', '').startswith(prefix):
                        known = self.state['known_ids'].setdefault(row['filename'], [])
                        if row['id'] not in known: known.append(row['id'])
                current = common.inventory_summary(rows)['content_digest']
            except common.ExperimentError as error:
                self.log('bulk_inventory_retry', reason=str(error))
                stage['sampling_interrupted'] = True
                stable_since = None
                if time.time() >= deadline:
                    raise
                time.sleep(self.args.poll_seconds)
                continue
            # A partial/rejected feed must not prevent tracking authoritative
            # indexing, recording its final inventory, or later cleanup.
            delta = None
            try:
                delta, size = self.client.diff(stage['cursor'])
            except common.ExperimentError as error:
                self.log('bulk_diff_unavailable', reason=str(error))
                stage['feed_unavailable_observed'] = True
            now = time.time()
            if delta is not None:
                modified, deleted = common.diff_groups(delta)
                prefix = 'synotest-' + self.state['owner'][:12] + '-'
                before_ids = {r['id'] for r in stage['before'] if r.get('filename', '').startswith(prefix)}
                visible_new = {r['id'] for r in rows if r.get('filename') in self.state['files']} - before_ids
                missing = visible_new - set(modified)
                if ready and stage['name'].endswith('delete'):
                    absent_candidates = before_ids - set(deleted)
                    if absent_candidates:
                        still_visible = {r['id'] for r in self.client.optional_lookup(sorted(absent_candidates))}
                        missing |= absent_candidates - still_visible
                if missing and not stage.get('first_gap_evidence'):
                    stage['first_gap_evidence'] = self.evidence(stage, 'first-corroborated-gap',
                        inventory=rows, interval=delta, missing_ids=sorted(missing))
                self.log('mobile_bulk_coverage', corroborated_missing_events=len(missing),
                         first_gap_evidence=stage.get('first_gap_evidence'))
            if not ready or current != signature:
                stable_since = None
            signature = current
            if ready:
                settle_deadline = settle_deadline or now + self.args.settle_timeout_seconds
                stable_since = stable_since if stable_since is not None else now
            evidence = self.evidence(stage, 'latest', inventory=rows, interval=delta,
                                     ready=ready, owned_files=len(self.state['files']))
            self.log('mobile_bulk_observation', inventory=common.inventory_summary(rows),
                     readiness=self.readiness(rows), ready=ready,
                     stable_seconds=round(now - stable_since, 1) if stable_since is not None else 0,
                     required_stable_seconds=self.args.quiet_seconds,
                     remaining_seconds=round(max(0, (settle_deadline or index_deadline) - now), 1),
                     interval=common.diff_summary(delta) if delta else None, evidence=evidence)
            self.save()
            if ready and now - stable_since >= self.args.quiet_seconds:
                return rows
            if now >= (settle_deadline or index_deadline):
                raise common.ExperimentError('Bulk metadata did not reach stable expected state within its indexing/settling budget.')
            time.sleep(self.args.poll_seconds)

    def bulk_mutation(self, name, delete=False):
        stage = self.state['stages'].get(name)
        if stage is None:
            before = self.scan_with_retry(time.time() + self.args.index_timeout_seconds, 'bulk-baseline')
            start = self.client.version()
            quiet, _ = self.client.diff(start)
            if not common.empty_diff(quiet):
                raise common.ExperimentError('Bulk baseline was not quiet.')
            stage = {'name': name, 'cursor': start, 'before': before,
                     'phase': 'mutating', 'count': self.args.bulk_count}
            self.state['stages'][name] = stage
            self.save()
            if delete:
                indices = [i for i in range(3000000, 3000000 + self.args.bulk_count)
                           if self.filename(i) in self.state['files']]
                self.remove(indices)
            else:
                for i in range(self.args.bulk_count):
                    self.put(3000000 + i, [12.25, 34.5])
                    if (i + 1) % 100 == 0:
                        self.log('mobile_bulk_copy', copied=i + 1, total=self.args.bulk_count)
            stage.update(phase='observing', written=time.time())
            self.save()
            self.log('mobile_bulk_copy_complete', affected_files=stage['count'],
                     indexing_budget_seconds=max(self.args.index_timeout_seconds,
                                                 stage['count'] * self.args.seconds_per_photo))
        elif stage['phase'] == 'mutating':
            raise common.ExperimentError('Bulk write was interrupted; cleanup is still attempted. Start a fresh run for clean evidence.')
        else:
            stage['resumed'] = True
        after = self.bulk_observation(stage)
        stage['ready'] = True
        # Final comparison is bound to manifest-owned identities, not holes in
        # unrelated offset scans. Folder enumeration independently checks addition.
        prefix = 'synotest-' + self.state['owner'][:12] + '-'
        owned_before = {r['id']: r for r in stage['before'] if r.get('filename', '').startswith(prefix)}
        owned_after = {r['id']: r for r in after if r.get('filename') in self.state['files']}
        expected = set(owned_before) if delete else set(owned_after)
        independent = []
        if delete:
            independent = self.client.optional_lookup(sorted(expected))
            inventory_ok = not independent and not any(r.get('filename', '').startswith(prefix) for r in after)
        else:
            for folder in {r['folder_id'] for r in owned_after.values()}:
                independent.extend(self.client.scan(limit=137, folder_id=folder))
            inventory_ok = {r['id'] for r in independent if r.get('filename') in self.state['files']} == expected and len(expected) == self.args.bulk_count
        interval, size = self.client.diff(stage['cursor'])
        replay, replay_size = self.client.diff(stage['cursor'])
        fence, _ = self.client.diff(common.cursor(replay))
        modified, deleted = common.diff_groups(replay)
        reported = set(deleted if delete else modified)
        checks = {'owned_inventory_corroborated': inventory_ok, 'full_batch_observed': len(expected) == self.args.bulk_count,
                  'no_corroborated_visibility_gap': not stage.get('first_gap_evidence'), 'expected_events_reported': expected <= reported,
                  'replay_identical': interval == replay, 'fence_empty': common.empty_diff(fence),
                  'no_duplicate_events': len(modified) == len(set(modified)) and len(deleted) == len(set(deleted)),
                  'no_conflicts': not (set(modified) & set(deleted)),
                  'no_unhandled_changes': not common.diff_activity(replay),
                  'continuous_observation': not (stage.get('sampling_interrupted') or stage.get('resumed') or stage.get('feed_unavailable_observed'))}
        evidence = self.evidence(stage, 'comparison', before=stage['before'], after=after,
                                 independent=independent, interval=interval, replay=replay, fence=fence,
                                 expected_ids=sorted(expected), checks=checks)
        failed = [key for key, value in checks.items() if not value]
        status = 'fail' if any(k != 'continuous_observation' for k in failed) else ('inconclusive' if failed else 'pass')
        self.result(name, status, checks=checks, expected_event_count=len(expected),
                    missing_event_count=len(expected - reported), interval=common.diff_summary(interval),
                    max_diff_bytes=max(size, replay_size), exceeded_four_mib=max(size, replay_size) > 4 * 1024 * 1024,
                    explanation='All bulk checks passed.' if not failed else 'Unmet checks: ' + ', '.join(failed), evidence=evidence)
        stage.update(done=True, phase='done')
        self.save()

    def after_cases(self):
        if not self.args.bulk_count:
            return
        self.attempt('mobile-pre-bulk-cleanup', lambda: self.cleanup_current('mobile-pre-bulk-cleanup'))
        self.attempt('mobile-bulk-add', lambda: self.bulk_mutation('mobile-bulk-add'), requires=('mobile-pre-bulk-cleanup',))
        # Deletion/cleanup remain useful even if the addition feed was incomplete.
        self.attempt('mobile-bulk-delete', lambda: self.bulk_mutation('mobile-bulk-delete', delete=True), requires=('mobile-pre-bulk-cleanup',))
        self.attempt('mobile-bulk-cleanup', lambda: self.cleanup_current('mobile-bulk-cleanup'))


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bulk-count', type=int, default=5000)
    parser.add_argument('--seconds-per-photo', type=float, default=2)
    args = focused.arguments(argv, parser=parser)
    if not 0 <= args.bulk_count <= 20000 or (args.bulk_count and args.bulk_count <= 1000):
        parser.error('bulk-count must be 0 (focused only) or 1001–20000')
    if not math.isfinite(args.seconds_per_photo) or args.seconds_per_photo <= 0:
        parser.error('seconds-per-photo must be finite and positive')
    return args


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, common.interrupt)
    raise SystemExit(focused.main(runner_class=MobileRunner, argument_parser=arguments))
