#!/usr/bin/env python3
"""Unattended, filesystem-driven Map/Diff experiments for the phototest account.

No NAS mutation APIs are used. See docs/capturefindings/README.md.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import datetime as dt
import fcntl
import hashlib
import gzip
import json
import math
import importlib.metadata
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import tempfile
import threading
import traceback
import urllib.parse
import urllib.request
import uuid

from test_synology_login import SynologyProbe, generate_totp, load_env

PROJECT = Path(__file__).resolve().parent.parent
MOUNT = Path('/Volumes/homes/phototest/Photos')
CAPTURES = PROJECT / 'docs/captures'
FIELDS = '["gps","thumbnail"]'
SCHEMA = 1


class ExperimentError(Exception):
    """Only fixed, non-sensitive messages may be placed here."""


class SafetyError(ExperimentError):
    """An ownership/mount problem must stop writes, rather than merely fail a test."""


class APIError(ExperimentError):
    def __init__(self, code):
        self.code = code
        super().__init__(f'API rejected a request (code {code}).')


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def cursor(data):
    if not isinstance(data, dict) or not all(integer(data.get(k)) for k in ('diff_version', 'version_time')):
        raise ExperimentError('Missing or malformed Diff cursor.')
    return {k: data[k] for k in ('diff_version', 'version_time')}


def diff_groups(data):
    cursor(data)
    mobile = 'has_next' in data
    groups = {'item': {'modify', 'delete', 'merge', 'move'}} if mobile else {
        'item': {'modify', 'delete'}, 'album': {'modify', 'delete'}}
    for name, keys in groups.items():
        group = data.get(name)
        if not isinstance(group, dict) or set(group) != keys:
            raise ExperimentError('Missing or unknown Diff change category.')
        if not all(isinstance(group[k], list) for k in keys):
            raise ExperimentError('Malformed Diff change arrays.')
    if mobile:
        if type(data['has_next']) is not bool or not isinstance(data.get('similar'), list):
            raise ExperimentError('Malformed mobile Diff completeness fields.')
        if data['has_next']:
            raise ExperimentError('Mobile Diff reports has_next=true; continuation is unproven, so this interval is incomplete.')
        if set(data) != {'diff_version', 'version_time', 'item', 'similar', 'has_next'}:
            raise ExperimentError('Unknown mobile Diff response fields.')
    modifies = data['item']['modify']
    deletes = data['item']['delete']
    if not all(isinstance(row, dict) and integer(row.get('id')) for row in modifies):
        raise ExperimentError('Malformed Diff modification.')
    if not all(integer(row) for row in deletes):
        raise ExperimentError('Malformed Diff deletion.')
    return [row['id'] for row in modifies], deletes


def empty_diff(data):
    modifies, deletes = diff_groups(data)
    return not modifies and not deletes and not diff_activity(data)


def diff_activity(data):
    """Additional observed feed categories; never manufacture album data for v7."""
    if 'has_next' in data:
        counts = {k: len(data['item'][k]) for k in ('merge', 'move')}
        counts['similar'] = len(data['similar'])
    else:
        counts = {'album_modified': len(data['album']['modify']), 'album_deleted': len(data['album']['delete'])}
    return {k: v for k, v in counts.items() if v}


def projection(item):
    additional = item.get('additional', {})
    thumb = additional.get('thumbnail') or {}
    return {'id': item['id'], 'time': item.get('time'), 'gps': additional.get('gps'),
            'thumbnail': {k: thumb.get(k) for k in ('unit_id', 'cache_key')}}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def inventory_summary(rows):
    values = [projection(row) for row in rows]
    return {'items': len(values), 'located': sum(v['gps'] is not None for v in values),
            'with_thumbnail_revision': sum(v['thumbnail']['cache_key'] is not None for v in values),
            'ordered_inventory_digest': digest(values),
            'content_digest': digest(sorted(values, key=lambda v: v['id']))}


def diff_summary(data):
    modifies, deletes = diff_groups(data)
    return {'modified': len(modifies), 'deleted': len(deletes),
            'unique_modified': len(set(modifies)), 'unique_deleted': len(set(deletes)),
            'modify_delete_overlap': len(set(modifies) & set(deletes)),
            'other_activity': diff_activity(data),
            'extra_fields': {k: type(v).__name__ for k, v in data.items()
                             if k not in {'item', 'album', 'diff_version', 'version_time'}},
            'content_digest': digest(data)}


def diff_evidence(data):
    """Keep the observed change contract, never arbitrary response fields or auth data."""
    modifies, deletes = diff_groups(data)
    fields = ('id', 'time', 'indexed_time', 'filesize', 'folder_id', 'owner_user_id', 'type')
    return {**cursor(data),
            'item': {'modify': [{k: row[k] for k in fields if k in row} for row in data['item']['modify']],
                     'delete': deletes},
            'other_activity': diff_activity(data),
            'summary': diff_summary(data)}


def fixture(path, index, gps=None, day=1, variant=0, capture_time=None):
    """Small unique JPEGs; EXIF-only edits leave the encoded pixels unchanged."""
    from PIL import Image, ImageDraw, TiffImagePlugin
    image = Image.new('RGB', (128, 96), ((index * 37 + variant * 97) % 256,
                                         (index * 73) % 256, (index * 109) % 256))
    ImageDraw.Draw(image).text((4, 40), f'TEST {index} v{variant}', fill='white')
    exif = Image.Exif()
    stamp = capture_time.strftime('%Y:%m:%d %H:%M:%S') if capture_time is not None else f'2020:01:{day:02d} 12:00:00'
    exif[306] = stamp
    exif[34665] = {36867: stamp, 36868: stamp}
    if gps is not None:
        rational = TiffImagePlugin.IFDRational
        def dms(number):
            absolute = abs(number)
            degrees = int(absolute)
            minutes = int((absolute - degrees) * 60)
            seconds = round((absolute - degrees - minutes / 60) * 3600, 6)
            return (rational(degrees), rational(minutes), rational(seconds))
        exif[34853] = {0: b'\x02\x03\x00\x00', 1: 'N' if gps[0] >= 0 else 'S',
                       2: dms(gps[0]), 3: 'E' if gps[1] >= 0 else 'W', 4: dms(gps[1])}
    image.save(path, 'JPEG', quality=80, exif=exif)


def check_environment():
    """Exercise every optional image feature before authentication or NAS writes."""
    try:
        required = (PROJECT / 'scripts/requirements-map-diff.txt').read_text().splitlines()
        pillow_requirement = next(line.strip().split('==', 1)[1] for line in required if line.startswith('Pillow=='))
        installed = importlib.metadata.version('Pillow')
        if installed != pillow_requirement:
            raise ValueError('Pillow version mismatch')
        from PIL import Image
        with tempfile.TemporaryDirectory(prefix='syno-map-diff-preflight-') as folder:
            path = Path(folder) / 'fixture.jpg'
            fixture(path, 1, gps=[12.25, -34.5])
            with Image.open(path) as image:
                image.load()
                if image.size != (128, 96) or image.getexif().get_ifd(34665).get(36867) != '2020:01:01 12:00:00':
                    raise ValueError('JPEG/date round trip failed')
                if image.getexif().get_ifd(34853).get(3) != 'W':
                    raise ValueError('GPS round trip failed')
        return {'event': 'environment_ready', 'python': sys.version.split()[0],
                'pillow': installed, 'jpeg_exif_gps_round_trip': True}
    except Exception:
        raise ExperimentError('Python dependency/image preflight failed. Run .venv/bin/python -m pip install -r scripts/requirements-map-diff.txt, then make map-diff-env.') from None


class Client(SynologyProbe):
    def __init__(self, credentials, log, verify_tls=False):
        super().__init__(base_url=credentials["NAS_URL"], verify_tls=verify_tls)
        self.credentials = credentials
        self.log = log
        self.verify_tls = verify_tls
        self.requests = 0
        self.bytes = 0
        self.last_bytes = 0
        self.last_seconds = 0

    def authenticate(self):
        secret = self.credentials.get('OTP', '').strip()
        self.login(self.credentials['USER'], self.credentials['PW'], generate_totp(secret) if secret else None)

    def call(self, path, parameters, *, post=False):
        # These are the only mutations allowed on the wire: session login/logout.
        api, method = parameters.get('api'), parameters.get('method')
        allowed = ((api == 'SYNO.API.Auth' and method in {'login', 'logout'}) or
                   (api == 'SYNO.Foto.Browse.Diff' and method in {'get', 'get_version', 'list', 'list_user_event'}) or
                   (api == 'SYNO.Foto.Browse.Item' and method in {'get', 'list', 'list_all'}) or
                   (api == 'SYNO.API.Info' and method == 'query'))
        if not allowed:
            raise ExperimentError('Blocked an unexpected API method.')
        encoded = urllib.parse.urlencode(parameters).encode()
        request = urllib.request.Request(self.base_url + path, data=encoded, method='POST')
        request.add_header('Accept', 'application/json')
        if self.syno_token:
            request.add_header('X-SYNO-TOKEN', self.syno_token)
        start = time.monotonic()
        telemetry = {'request_ref': uuid.uuid4().hex[:12], 'api': api, 'method': method,
                     'version': parameters.get('version'),
                     'offset': parameters.get('offset'), 'limit': parameters.get('limit')}
        try:
            with self.opener.open(request, timeout=120) as response:
                body = response.read(64 * 1024 * 1024 + 1)
            if len(body) > 64 * 1024 * 1024:
                raise ExperimentError('Probe exceeded its 64 MiB response ceiling.')
            payload = json.loads(body)
        except ExperimentError:
            self.log('request_failed', **telemetry, elapsed_seconds=round(time.monotonic() - start, 3),
                     failure_category='response_ceiling')
            raise
        except Exception as error:
            self.log('request_failed', **telemetry, elapsed_seconds=round(time.monotonic() - start, 3),
                     failure_category=type(error).__name__,
                     http_status=getattr(error, 'code', None) if integer(getattr(error, 'code', None)) else None)
            raise ExperimentError('Network or JSON failure; private request details suppressed.') from None
        self.requests += 1
        self.bytes += len(body)
        self.last_bytes = len(body)
        self.last_seconds = time.monotonic() - start
        if not isinstance(payload, dict):
            self.log('request_failed', **telemetry, failure_category='invalid_envelope')
            raise ExperimentError('Unexpected API response envelope.')
        data = payload.get('data')
        self.log('request_completed', **telemetry, elapsed_seconds=round(self.last_seconds, 3),
                 response_bytes=len(body), success=payload.get('success') is True,
                 api_error_code=payload.get('error', {}).get('code'),
                 returned_items=len(data['list']) if isinstance(data, dict) and isinstance(data.get('list'), list) else None)
        return payload

    def read(self, api, method, version, **parameters):
        for attempt in range(2):
            path = '/webapi/entry.cgi' if api == 'SYNO.API.Info' else '/webapi/entry.cgi/' + api
            payload = self.call(path,
                                {'api': api, 'method': method, 'version': str(version),
                                 '_sid': self.sid, **parameters}, post=True)
            if payload.get('success') is True and isinstance(payload.get('data'), dict):
                return payload['data']
            code = payload.get('error', {}).get('code', -1)
            if code in (106, 107, 119) and attempt == 0:
                self.authenticate()
                continue
            raise APIError(code)
        raise ExperimentError('Authentication retry failed.')

    def version(self):
        return cursor(self.read('SYNO.Foto.Browse.Diff', 'get_version', 1))

    def diff(self, start):
        data = self.read('SYNO.Foto.Browse.Diff', 'get', 1, **start)
        try:
            diff_groups(data)
        except ExperimentError:
            self.log('diff_shape_rejected', top_level_types={k: type(v).__name__ for k, v in data.items()},
                     change_group_types={name: {k: type(v).__name__ for k, v in data[name].items()}
                                         for name in ('item', 'album') if isinstance(data.get(name), dict)})
            raise
        return data, self.last_bytes

    def page(self, offset, limit=1000, folder_id=None):
        args = {'offset': str(offset), 'limit': str(limit), 'additional': FIELDS}
        if folder_id is not None:
            args['folder_id'] = str(folder_id)
        data = self.read('SYNO.Foto.Browse.Item', 'list', 7, **args)
        rows = data.get('list')
        if not isinstance(rows, list) or not all(isinstance(r, dict) and integer(r.get('id')) for r in rows):
            raise ExperimentError('Malformed item list.')
        return rows

    def scan(self, limit=1000, overlap=False, folder_id=None, hook=None):
        rows = []
        # One page from this session and one from a separate read-only session.
        # Each opener remains confined to its own thread.
        with contextlib.ExitStack() as stack:
            executor = stack.enter_context(concurrent.futures.ThreadPoolExecutor(max_workers=1)) if overlap else None
            partner = None
            if overlap:
                partner = Client(self.credentials, self.log, self.verify_tls)
                partner.authenticate()
                stack.callback(partner.logout)
            offset = 0
            for _ in range(math.ceil(100000 / limit)):
                if overlap:
                    pending = executor.submit(partner.page, offset + limit, limit, folder_id)
                current = self.page(offset, limit, folder_id)
                rows.extend(current)
                if hook:
                    hook()
                    hook = None
                if len(current) < limit:
                    if overlap:
                        pending.result()
                    break
                if overlap:
                    following = pending.result()
                    rows.extend(following)
                    if len(following) < limit:
                        break
                    offset += 2 * limit
                else:
                    offset += limit
            else:
                raise ExperimentError('Inventory exceeded the 100,000-item safety cap.')
            if partner:
                self.requests += partner.requests
                self.bytes += partner.bytes
        ids = [r['id'] for r in rows]
        if len(ids) != len(set(ids)):
            self.log('scan_failed', page_size=limit, overlap=overlap, returned_items=len(ids),
                     unique_items=len(set(ids)), duplicate_count=len(ids) - len(set(ids)))
            raise ExperimentError('Duplicate IDs in a positional scan.')
        self.log('scan_completed', page_size=limit, overlap=overlap, folder_scoped=folder_id is not None,
                 inventory=inventory_summary(rows))
        return rows

    def lookup(self, ids):
        rows = []
        for offset in range(0, len(ids), 100):
            batch = ids[offset:offset + 100]
            found = self.read('SYNO.Foto.Browse.Item', 'get', 7,
                              id=json.dumps(batch), additional=FIELDS).get('list')
            if not isinstance(found, list) or not all(isinstance(r, dict) and integer(r.get('id')) for r in found):
                raise ExperimentError('Malformed item lookup.')
            if len(found) != len(batch) or {r['id'] for r in found} != set(batch):
                raise ExperimentError('Lookup omitted, duplicated or added IDs; absence is not proof of deletion.')
            rows.extend(found)
        return rows


class Runner:
    def __init__(self, args, client_factory=Client):
        self.args = args
        self.log_lock = threading.Lock()
        self.directory = args.resume or CAPTURES / ('map-diff-run-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
        self.directory = self.directory.resolve()
        if self.directory.parent != CAPTURES.resolve() or not self.directory.name.startswith('map-diff-run-'):
            raise ExperimentError('Run directory must be directly under docs/captures/map-diff-run-*.')
        self.directory.mkdir(mode=0o700, exist_ok=bool(args.resume))
        self.state_path = self.directory / 'state.json'
        if args.resume:
            self.state = json.loads(self.state_path.read_text())
            if self.state.get('schema') != SCHEMA:
                raise ExperimentError('Unsupported runner state schema.')
            # Persisted timings/bounds define this run, including after restart.
            for key, value in self.state['settings'].items():
                setattr(args, key, value)
        else:
            self.state = {'schema': SCHEMA, 'run_id': self.directory.name, 'owner': uuid.uuid4().hex,
                          'settings': {k: getattr(args, k) for k in ('seconds_per_photo', 'poll_seconds', 'quiet_seconds',
                                        'cursor_age_seconds', 'large_start', 'large_max', 'equal_count')},
                          'files': {}, 'stages': {}, 'results': [], 'active': None}
            self.save()
        if self.state['run_id'] != self.directory.name:
            raise ExperimentError('Run identity mismatch.')
        self.root = MOUNT / 'syno-diff-tests' / self.state['run_id']
        self.client_factory = client_factory
        self.client = None
        self.journal = self.directory / 'ownership.jsonl'
        if self.journal.exists():
            self.state['files'] = {}
            for line in self.journal.read_text().splitlines():
                record = json.loads(line)
                if record['operation'] == 'put':
                    self.state['files'][record['name']] = record['spec']
                else:
                    self.state['files'].pop(record['name'], None)
        self.last_write_observation = 0.0

    def save(self):
        atomic_json(self.state_path, self.state)

    def log(self, event, **values):
        values.setdefault('stage', self.state.get('active'))
        entry = {'utc': dt.datetime.now(dt.timezone.utc).isoformat(), 'event': event, **values}
        line = json.dumps(entry, sort_keys=True)
        with self.log_lock:
            with (self.directory / 'events.jsonl').open('a') as stream:
                stream.write(line + '\n')
            print(line, flush=True)

    def reference(self, value):
        return digest([self.state['owner'], value])[:12]

    def evidence(self, stage, label, **values):
        """Private payload evidence, stripped of envelopes, headers and credentials."""
        for key, value in list(values.items()):
            if isinstance(value, dict) and 'item' in value and 'album' in value:
                values[key] = diff_evidence(value)
        folder = self.directory / 'evidence' / stage['name']
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / (label + '.json.gz')
        temporary = path.with_suffix('.tmp')
        with gzip.open(temporary, 'wt', encoding='utf-8') as stream:
            json.dump(values, stream, sort_keys=True)
        os.replace(temporary, path)
        return str(path.relative_to(self.directory))

    def readiness(self, rows):
        by_name = {r.get('filename'): r for r in rows}
        missing = []
        wrong_time = []
        wrong_gps = []
        prefix = 'synotest-' + self.state['owner'][:12] + '-'
        unexpected = [r['id'] for r in rows if r.get('filename', '').startswith(prefix)
                      and r['filename'] not in self.state['files']]
        for name, expected in self.state['files'].items():
            item = by_name.get(name)
            if item is None:
                missing.append(expected['index'])
                continue
            stamp = int(dt.datetime(2020, 1, expected['day'], 12, tzinfo=dt.timezone.utc).timestamp())
            if item.get('time') != stamp:
                wrong_time.append(expected['index'])
            gps = item.get('additional', {}).get('gps')
            target = expected['gps']
            matches = gps is None if target is None else isinstance(gps, dict) and all(
                isinstance(gps.get(k), (float, int)) and abs(gps[k] - v) <= 0.00001
                for k, v in zip(('latitude', 'longitude'), target))
            if not matches:
                wrong_gps.append(expected['index'])
        generated_names = [r.get('filename') for r in rows if r.get('filename') in self.state['files']]
        return {'duplicate_generated_names': len(generated_names) - len(set(generated_names)),
                'expected_generated_files': len(self.state['files']),
                'missing_generated_files': len(missing), 'missing_fixture_samples': missing[:10],
                'time_mismatches': len(wrong_time), 'time_mismatch_fixture_samples': wrong_time[:10],
                'gps_mismatches': len(wrong_gps), 'gps_mismatch_fixture_samples': wrong_gps[:10],
                'deleted_files_still_visible': len(unexpected),
                'deleted_item_ref_samples': [self.reference(i) for i in unexpected[:10]]}

    def result(self, name, status, **details):
        stage = self.state['stages'].get(name, {})
        if status != 'pass':
            details.setdefault('phase', stage.get('phase'))
            details.setdefault('last_observation', stage.get('last_observation'))
            details.setdefault('last_observation_evidence', stage.get('last_observation_evidence'))
            details.setdefault('first_feed_gap_evidence', stage.get('first_feed_gap_evidence'))
        entry = {'test': name, 'status': status, **details}
        self.state['results'].append(entry)
        self.save()
        self.log('result', **entry)
        atomic_json(self.directory / 'report.json', {'run_id': self.state['run_id'],
                    'settings': self.state['settings'], 'results': self.state['results'],
                    'production_diff_enabled': False, 'scope': 'filesystem reindex; no permission/reset probes'})

    def attempt(self, name, action, requires=()):
        """Run independent tests even when another test timed out or failed a check."""
        existing = self.state['stages'].get(name, {})
        if existing.get('done'):
            return existing.get('ready', existing.get('phase') == 'done')
        if name != 'startup-cleanup' and 'cleanup' not in name and 'startup-cleanup' in self.state['stages']:
            requires = (*requires, 'startup-cleanup')
        unavailable = [dependency for dependency in requires
                       if not self.state['stages'].get(dependency, {}).get('ready', False)]
        if unavailable:
            self.state['stages'][name] = {'name': name, 'done': True, 'ready': False, 'phase': 'skipped'}
            self.result(name, 'skipped', reason='Required indexed fixture state was not established.',
                        unavailable_dependencies=unavailable)
            return False
        self.state['active'] = name
        try:
            action()
            stage = self.state['stages'].setdefault(name, {})
            stage.update(done=True, ready=stage.get('ready', True))
            self.save()
            return stage['ready']
        except SafetyError:
            raise
        except Exception as error:
            stage = self.state['stages'].setdefault(name, {'name': name})
            stage.update(done=True, ready=stage.get('ready', False), phase='failed')
            self.result(name, 'inconclusive', reason=str(error) if isinstance(error, ExperimentError)
                        else 'Test raised an exception; private exception text suppressed.',
                        exception_type=type(error).__name__, action='Continue independent tests.',
                        stack=[{'file': Path(frame.filename).name, 'function': frame.name, 'line': frame.lineno}
                               for frame in traceback.extract_tb(error.__traceback__)])
            return stage['ready']
        finally:
            self.state['active'] = None
            self.save()

    def wait_for_absence(self, name, prefixes, count):
        """Cleanup is based on authoritative absence, never on a working Diff feed."""
        stage = self.state['stages'].setdefault(name, {'name': name})
        stage.update(phase='waiting-for-deletion', written=time.time(), count=count)
        deadline = stage['written'] + max(self.args.quiet_seconds, count * self.args.seconds_per_photo)
        final_deadline = deadline + self.args.quiet_seconds
        stable_since = None
        signature = None
        while True:
            rows = self.client.scan()
            remaining = [r for r in rows if any(r.get('filename', '').startswith(prefix) for prefix in prefixes)]
            now = time.time()
            current = inventory_summary(rows)['content_digest']
            if remaining or current != signature:
                stable_since = None
            signature = current
            if not remaining and stable_since is None:
                stable_since = now
            evidence = self.evidence(stage, 'cleanup-observation', inventory=[projection(r) for r in rows],
                                     remaining_ids=[r['id'] for r in remaining])
            stage['last_observation'] = {'remaining_generated_items': len(remaining), 'inventory': inventory_summary(rows)}
            stage['last_observation_evidence'] = evidence
            self.log('cleanup_wait', stage=name, remaining_generated_items=len(remaining),
                     stable_absence_seconds=round(now - stable_since, 1) if stable_since is not None else 0,
                     required_stable_seconds=self.args.quiet_seconds,
                     timeout_remaining_seconds=round(max(0, deadline - now), 1), evidence=evidence)
            self.save()
            if stable_since is not None and now - stable_since >= self.args.quiet_seconds:
                stage.update(done=True, ready=True, phase='done')
                self.result(name, 'pass', explanation='Owned fixtures disappeared from Photos and absence remained stable.',
                            removed_files=count, evidence=evidence, inventory=inventory_summary(rows))
                return
            if now >= final_deadline or (remaining and now >= deadline):
                raise ExperimentError('Cleanup files remain indexed or inventory did not stabilize; dependent tests are skipped.')
            time.sleep(min(self.args.poll_seconds, max(0.1, final_deadline - time.time())))

    def cleanup_current(self, name, indices=None):
        self.state['active'] = name
        self.state['stages'][name] = {'name': name, 'phase': 'cleaning', 'ready': False}
        selected = [v['index'] for v in self.state['files'].values()] if indices is None else [
                    i for i in indices if self.filename(i) in self.state['files']]
        self.log('cleanup_started', stage=name, owned_files=len(selected))
        self.remove(selected)
        # A scoped cleanup waits only for the selected fixture names.
        prefixes = [self.filename(i) for i in indices] if indices is not None else ['synotest-' + self.state['owner'][:12] + '-']
        self.wait_for_absence(name, prefixes, len(selected))

    def cleanup_previous_runs(self):
        self.state['active'] = 'startup-cleanup'
        self.state['stages']['startup-cleanup'] = {'name': 'startup-cleanup', 'phase': 'cleaning', 'ready': False}
        prefixes = []
        removed = 0
        for directory in sorted(CAPTURES.glob('map-diff-run-*')):
            if directory.resolve() == self.directory:
                continue
            if directory.is_symlink() or (directory / 'state.json').is_symlink() or (directory / 'ownership.jsonl').is_symlink():
                raise SafetyError('Previous-run ownership files are symlinks; cleanup stopped.')
            if not (directory / 'state.json').is_file():
                continue
            state = json.loads((directory / 'state.json').read_text())
            owner = state['owner']
            try:
                valid_owner = uuid.UUID(owner).hex == owner
            except (ValueError, TypeError, AttributeError):
                valid_owner = False
            if state['run_id'] != directory.name or not valid_owner:
                raise SafetyError('Previous-run ownership identity is invalid.')
            root = MOUNT / 'syno-diff-tests' / directory.name
            self.check_mount()
            if root.is_symlink():
                raise SafetyError('Previous test directory is a symlink.')
            if root.exists():
                marker = root / '.owner.json'
                if marker.is_symlink() or not marker.is_file() or json.loads(marker.read_text()) != {'owner': owner}:
                    raise SafetyError('Previous test directory ownership marker mismatch.')
            journal = directory / 'ownership.jsonl'
            files = {}
            for line in journal.read_text().splitlines() if journal.exists() else []:
                entry = json.loads(line)
                if entry['operation'] == 'put':
                    files[entry['name']] = entry['spec']
                elif entry['operation'] == 'remove':
                    files.pop(entry['name'], None)
                else:
                    raise SafetyError('Unknown previous ownership journal operation.')
            if not journal.exists() and state.get('files'):
                raise SafetyError('Previous-run ownership journal is missing.')
            for filename, spec in files.items():
                expected = 'synotest-' + owner[:12] + f"-{spec['index']:06d}-" + 'fixture-' * 16 + '.jpg'
                if filename != expected or Path(filename).name != filename:
                    raise SafetyError('Previous-run generated filename does not match its manifest.')
                self.check_mount()
                target = root / filename
                if target.is_symlink():
                    raise SafetyError('Previous generated fixture is a symlink.')
                target.unlink(missing_ok=True)
                with journal.open('a') as stream:
                    stream.write(json.dumps({'operation': 'remove', 'name': filename, 'spec': None}) + '\n')
                    stream.flush()
                    os.fsync(stream.fileno())
                removed += 1
            prefixes.append('synotest-' + owner[:12] + '-')
            self.log('previous_run_cleaned', previous_run=directory.name, manifest_files_removed=len(files))
        if prefixes:
            self.wait_for_absence('startup-cleanup', prefixes, removed)
        else:
            self.state['stages']['startup-cleanup'].update(done=True, ready=True, phase='done')
            self.result('startup-cleanup', 'pass', explanation='No previous generated runs needed cleanup.')
        self.state['active'] = None
        self.save()

    def check_mount(self):
        if not Path('/Volumes/homes').is_mount() or not MOUNT.is_dir() or MOUNT.resolve() != MOUNT:
            raise SafetyError('Expected homes mount is unavailable or redirected.')
        for part in (MOUNT / 'syno-diff-tests', self.root):
            if part.is_symlink():
                raise SafetyError('Test directory is a symlink.')
        if self.root.exists():
            marker = self.root / '.owner.json'
            if marker.is_symlink() or not marker.is_file():
                raise SafetyError('Test directory ownership marker is missing.')
            if json.loads(marker.read_text()) != {'owner': self.state['owner']}:
                raise SafetyError('Test directory ownership marker mismatch.')

    def prepare_root(self):
        self.check_mount()
        if not self.root.exists():
            self.root.parent.mkdir(exist_ok=True)
            self.root.mkdir()
            atomic_json(self.root / '.owner.json', {'owner': self.state['owner']})

    def filename(self, index):
        # Long, unique synthetic names also exercise realistic response sizes.
        return 'synotest-' + self.state['owner'][:12] + f'-{index:06d}-' + 'fixture-' * 16 + '.jpg'

    def own(self, operation, name, spec=None):
        with self.journal.open('a') as stream:
            stream.write(json.dumps({'operation': operation, 'name': name, 'spec': spec}) + '\n')
            stream.flush()
            os.fsync(stream.fileno())

    def observe_writes(self):
        active = self.state.get('active')
        stage = self.state['stages'].get(active)
        if stage and 'cursor' in stage and stage.get('phase') == 'mutating' and time.monotonic() - self.last_write_observation >= self.args.poll_seconds:
            try:
                rows = self.client.scan()
                delta, size = self.client.diff(stage['cursor'])
                self.observe(stage, rows, delta, size, writing=True)
            except ExperimentError as error:
                stage['sampling_interrupted'] = True
                self.log('write_observation_failed', reason=str(error), action='Finish batch, then record test outcome.')
            self.last_write_observation = time.monotonic()

    def put(self, index, gps=None, day=1, variant=0):
        self.check_mount()
        name = self.filename(index)
        target = self.root / name
        if target.is_symlink() or (target.exists() and name not in self.state['files']):
            raise SafetyError('Refusing to replace an unowned file.')
        # Record ownership before the NAS write; interrupted writes remain identifiable.
        spec = {'index': index, 'gps': gps, 'day': day, 'variant': variant}
        self.own('put', name, spec)
        self.state['files'][name] = spec
        local = self.directory / 'fixture.tmp.jpg'
        fixture(local, index, gps, day, variant)
        # Write existing files in place to test same-path/identity-preserving reindex.
        with local.open('rb') as source, target.open('wb') as destination:
            destination.write(source.read())
            destination.flush()
            os.fsync(destination.fileno())
        local.unlink()
        self.observe_writes()

    def remove(self, indices):
        for index in indices:
            self.check_mount()
            name = self.filename(index)
            if name not in self.state['files']:
                raise SafetyError('Refusing to delete an unowned file.')
            target = self.root / name
            if target.is_symlink():
                raise SafetyError('Refusing to delete a symlink.')
            target.unlink(missing_ok=True)
            self.own('remove', name)
            del self.state['files'][name]
            self.observe_writes()

    def matches(self, rows):
        by_name = {}
        for row in rows:
            name = row.get('filename')
            if name in self.state['files']:
                if name in by_name:
                    return False
                by_name[name] = row
        if set(by_name) != set(self.state['files']):
            return False
        # Deleted generated files must also have disappeared from the API.
        prefix = 'synotest-' + self.state['owner'][:12] + '-'
        if any(r.get('filename', '').startswith(prefix) and r['filename'] not in self.state['files'] for r in rows):
            return False
        for name, item in by_name.items():
            expected = self.state['files'][name]
            stamp = int(dt.datetime(2020, 1, expected['day'], 12, tzinfo=dt.timezone.utc).timestamp())
            if item.get('time') != stamp:
                return False
            gps = item.get('additional', {}).get('gps')
            if expected['gps'] is None:
                if gps is not None:
                    return False
            elif not isinstance(gps, dict) or any(abs(gps.get(k, 999) - val) > 0.00001
                         for k, val in zip(('latitude', 'longitude'), expected['gps'])):
                return False
        return True

    def observe(self, stage, rows, delta, size, writing=False):
        now = time.time()
        modifies, deletes = diff_groups(delta)
        before = {r['id']: projection(r) for r in stage['before']}
        after = {r['id']: projection(r) for r in rows}
        changed = {key for key in after if key not in before or after[key] != before[key]}
        removed = set(before) - set(after)
        missing = (changed - set(modifies)) | (removed - set(deletes))
        if missing:
            if not stage.get('observed_feed_gap'):
                stage['first_feed_gap_evidence'] = self.evidence(stage, 'first-feed-gap',
                    inventory=[projection(r) for r in rows], delta=delta,
                    missing_modified=sorted(changed - set(modifies)), missing_deleted=sorted(removed - set(deletes)))
            stage['observed_feed_gap'] = True
        if changed or removed:
            stage.setdefault('first_authoritative_change_seconds', now - stage['started'])
        if modifies or deletes:
            stage.setdefault('first_feed_change_seconds', now - stage['started'])
        self.log('indexing', stage=stage['name'], elapsed_seconds=round(now - stage['started'], 1),
                 writing=writing, inventory_count=len(rows), diff_modified=len(modifies),
                 diff_deleted=len(deletes), diff_bytes=size, observed_missing_event_count=len(missing),
                 expected_files_visible=self.matches(rows), readiness=self.readiness(rows),
                 inventory=inventory_summary(rows), diff=diff_summary(delta),
                 cursor_ref=self.reference(cursor(delta)),
                 missing_event_ref_samples=[self.reference(i) for i in sorted(missing)[:10]])
        stage['last_observation_evidence'] = self.evidence(stage, 'last-observation',
                    inventory=[projection(r) for r in rows], delta=delta)
        stage['last_observation'] = {'elapsed_seconds': now - stage['started'], 'diff_bytes': size,
                                     'inventory': inventory_summary(rows), 'diff': diff_summary(delta),
                                     'readiness': self.readiness(rows)}

    def settle(self, stage):
        # Indexing budget starts after copying; a final quiet window may finish afterward.
        written = stage['written']
        indexing_deadline = written + max(self.args.quiet_seconds, stage['count'] * self.args.seconds_per_photo)
        deadline = indexing_deadline + self.args.quiet_seconds
        last_signature = None
        stable_since = time.time()
        ready_since = None
        while True:
            rows = self.client.scan()
            delta, size = self.client.diff(stage['cursor'])
            now = time.time()
            self.observe(stage, rows, delta, size)
            signature = hashlib.sha256(json.dumps([sorted(rows, key=lambda r: r['id']), delta], sort_keys=True).encode()).hexdigest()
            if signature != last_signature:
                stable_since = now
                last_signature = signature
            ready = self.matches(rows)
            if stage['name'] == 'same-path-replacement':
                old = next((r for r in stage['before'] if r.get('filename') == self.filename(0)), None)
                current = next((r for r in rows if r.get('filename') == self.filename(0)), None)
                ready = ready and bool(old and current and projection(old)['thumbnail'] != projection(current)['thumbnail'])
            ready_since = (now if ready_since is None else ready_since) if ready else None
            self.log('settling', stage=stage['name'], ready=ready,
                     stable_ready_seconds=round(now - max(stable_since, ready_since), 1) if ready else 0,
                     required_stable_seconds=self.args.quiet_seconds,
                     indexing_budget_remaining_seconds=round(max(0, indexing_deadline - now), 1),
                     final_deadline_remaining_seconds=round(max(0, deadline - now), 1))
            self.save()
            if ready and now - max(stable_since, ready_since) >= self.args.quiet_seconds:
                return rows, delta, size
            if now >= deadline or (not ready and now >= indexing_deadline):
                raise ExperimentError('Expected metadata did not converge before the indexing deadline; test recorded and independent tests continue.')
            time.sleep(min(self.args.poll_seconds, max(0.1, deadline - time.time())))

    def evaluate(self, stage, after, delta, size):
        replay, replay_size = self.client.diff(stage['cursor'])
        fence, _ = self.client.diff(cursor(replay))
        before = {r['id']: projection(r) for r in stage['before']}
        current = {r['id']: projection(r) for r in after}
        modifies, deletes = diff_groups(replay)
        expected_modify = {key for key in current if key not in before or current[key] != before[key]}
        expected_delete = set(before) - set(current)
        duplicates = len(modifies) != len(set(modifies)) or len(deletes) != len(set(deletes))
        missing = len(expected_modify - set(modifies)) + len(expected_delete - set(deletes))
        partial_keys = sorted(set(replay) - {'diff_version', 'version_time', 'item', 'album'})
        equivalent = delta == replay
        passed = not missing and not duplicates and not (set(modifies) & set(deletes)) and empty_diff(fence) and equivalent and not partial_keys
        # Never hide even a transient observed visibility gap behind eventual convergence.
        status = 'fail' if not passed or stage.get('observed_feed_gap') else 'pass'
        if (stage.get('resumed') or stage.get('sampling_interrupted')) and status == 'pass':
            status = 'inconclusive'
        missing_modify = expected_modify - set(modifies)
        missing_delete = expected_delete - set(deletes)
        fields = {key: 0 for key in ('capture_time', 'gps', 'thumbnail_unit', 'thumbnail_revision')}
        samples = []
        for key in sorted(set(before) & set(current)):
            old, new = before[key], current[key]
            changed_fields = [label for label, left, right in (
                ('capture_time', old['time'], new['time']), ('gps', old['gps'], new['gps']),
                ('thumbnail_unit', old['thumbnail']['unit_id'], new['thumbnail']['unit_id']),
                ('thumbnail_revision', old['thumbnail']['cache_key'], new['thumbnail']['cache_key'])) if left != right]
            for field in changed_fields:
                fields[field] += 1
            if changed_fields and len(samples) < 10:
                samples.append({'item_ref': self.reference(key), 'changed_fields': changed_fields,
                                'reported_modified': key in modifies})
        assertions = {
            'expected_modifications_reported': not missing_modify,
            'expected_deletions_reported': not missing_delete,
            'no_duplicate_events': not duplicates,
            'no_modify_delete_conflicts': not (set(modifies) & set(deletes)),
            'replay_identical': equivalent, 'final_fence_empty': empty_diff(fence),
            'no_unknown_response_fields': not partial_keys,
            'no_observed_feed_visibility_gap': not stage.get('observed_feed_gap', False),
            'continuous_observation': not (stage.get('resumed', False) or stage.get('sampling_interrupted', False))}
        failures = [name for name, satisfied in assertions.items() if not satisfied]
        evidence = self.evidence(stage, 'comparison',
                    before=list(before.values()), after=list(current.values()),
                    interval=delta, replay=replay, fence=fence,
                    expected_modified=sorted(expected_modify), expected_deleted=sorted(expected_delete),
                    missing_modified=sorted(missing_modify), missing_deleted=sorted(missing_delete),
                    assertions=assertions)
        self.result(stage['name'], status,
                    explanation='All comparison checks passed.' if not failures else 'Unmet checks: ' + ', '.join(failures),
                    checks=assertions, evidence=evidence,
                    baseline=inventory_summary(stage['before']), after=inventory_summary(after),
                    interval=diff_summary(delta), replay=diff_summary(replay), fence=diff_summary(fence),
                    changed_fields=fields, changed_item_samples=samples,
                    missing_modified_ref_samples=[self.reference(i) for i in sorted(missing_modify)[:10]],
                    missing_deleted_ref_samples=[self.reference(i) for i in sorted(missing_delete)[:10]],
                    additional_modified_events=len(set(modifies) - expected_modify),
                    additional_deleted_events=len(set(deletes) - expected_delete),
                    stage_elapsed_seconds=round(time.time() - stage.get('started', time.time()), 3),
                    write_seconds=round(stage['written'] - stage['started'], 3) if 'written' in stage else None,
                    post_write_seconds=round(time.time() - stage['written'], 3) if 'written' in stage else None,
                    expected_modifications=len(expected_modify),
                    expected_deletions=len(expected_delete), missing_events=missing,
                    duplicate_events=duplicates, replay_equal=equivalent, fence_empty=empty_diff(fence),
                    extra_response_fields=partial_keys, max_diff_bytes=max(size, replay_size),
                    feed_visibility_gap_observed=stage.get('observed_feed_gap', False),
                    observation_interrupted=stage.get('resumed', False),
                    first_authoritative_change_seconds=stage.get('first_authoritative_change_seconds'),
                    first_feed_change_seconds=stage.get('first_feed_change_seconds'))
        return max(size, replay_size)

    def mutation(self, name, count, action):
        if name in self.state['stages'] and self.state['stages'][name].get('done'):
            return self.state['stages'][name].get('bytes', 0)
        stage = self.state['stages'].get(name)
        if stage is None:
            start = self.client.version()
            before = self.client.scan()
            quiet, _ = self.client.diff(start)
            if not empty_diff(quiet):
                raise ExperimentError('Baseline changed before mutation; retain run and retry later.')
            stage = {'name': name, 'count': count, 'before': before, 'cursor': start,
                     'started': time.time(), 'phase': 'mutating'}
            self.state['stages'][name] = stage
            self.state['active'] = name
            stage['baseline_evidence'] = self.evidence(stage, 'baseline',
                            inventory=[projection(r) for r in before], cursor=start, quiet_interval=quiet)
            self.log('stage_started', stage=name, affected_files=count,
                     baseline=inventory_summary(before), cursor_ref=self.reference(start),
                     files_before_mutation=len(self.state['files']),
                     indexing_budget_seconds=max(self.args.quiet_seconds, count * self.args.seconds_per_photo),
                     required_stable_seconds=self.args.quiet_seconds, evidence=stage['baseline_evidence'])
            self.save()
            action()
            stage['written'] = time.time()
            stage['phase'] = 'observing'
            self.log('filesystem_mutation_completed', stage=name,
                     write_seconds=round(stage['written'] - stage['started'], 3),
                     expected_generated_files=len(self.state['files']))
            self.save()
        else:
            if stage['phase'] == 'mutating':
                raise ExperimentError('Interrupted filesystem mutation: use --cleanup for this run, then start a new run.')
            stage['resumed'] = True
        after, delta, size = self.settle(stage)
        stage['ready'] = True
        measured = self.evaluate(stage, after, delta, size)
        stage.update(done=True, bytes=measured, phase='done')
        # Keep private before/cursor for reproducible replay; no sessions are stored.
        self.state['active'] = None
        self.save()
        return measured

    def pagination(self):
        if 'pagination' in self.state['stages']:
            return
        self.state['active'] = 'pagination'
        self.log('pagination_started', expected_generated_files=len(self.state['files']))
        start = self.client.version()
        first = self.client.scan()
        known = {r['filename']: r['id'] for r in first if r.get('filename') in self.state['files']}
        if set(known) != set(self.state['files']):
            raise ExperimentError('Generated manifest and initial inventory disagree.')
        folder_ids = {r.get('folder_id') for r in first if r.get('filename') in known}
        independent = []
        for folder_id in folder_ids:
            if not integer(folder_id):
                raise ExperimentError('Folder ID missing for independent enumeration.')
            independent.extend(self.client.scan(limit=137, folder_id=folder_id))
        folder_known = {r['filename']: r['id'] for r in independent if r.get('filename') in known}
        expected_ids = set(known.values())
        checks = []
        evidence_scans = []
        for limit, overlap in [(1000, False), (1000, True), (333, False), (1000, True)]:
            rows = self.client.scan(limit=limit, overlap=overlap)
            actual = [r['id'] for r in rows if r.get('filename') in known]
            evidence_scans.append({'page_size': limit, 'overlap': overlap, 'ordered_ids': actual})
            checks.append({'page_size': limit, 'overlap': overlap,
                           'expected_items': len(expected_ids), 'observed_items': len(actual),
                           'missing_items': len(expected_ids - set(actual)),
                           'unexpected_items': len(set(actual) - expected_ids),
                           'first_differing_ordinal': next((i for i, (a, b) in enumerate(zip(actual, [r['id'] for r in first if r.get('filename') in known])) if a != b), None),
                           'inventory': inventory_summary(rows),
                           'complete': set(actual) == expected_ids,
                           'same_order': actual == [r['id'] for r in first if r.get('filename') in known]})
        fence, _ = self.client.diff(start)
        passed = folder_known == known and all(c['complete'] and c['same_order'] for c in checks) and empty_diff(fence)
        evidence = self.evidence({'name': 'pagination'}, 'comparison',
                     manifest_inventory=known, independent_folder_inventory=folder_known,
                     scans=evidence_scans, fence=fence, saved_cursor=start)
        self.result('equal-timestamp-pagination', 'pass' if passed else 'fail',
                    explanation='All scan variants matched the independent inventory and ordering under a quiet fence.' if passed else
                                'A scan inventory, ordering comparison or final fence differed; inspect scan details and evidence.',
                    evidence=evidence, fence=diff_summary(fence),
                    fixture_count=len(known), independent_folder_inventory_matches=folder_known == known,
                    quiet_fence=empty_diff(fence), scans=checks)
        self.state['stages']['pagination'] = {'done': True}
        self.state['active'] = None
        self.save()

    def edit_identity(self, name):
        stage = self.state['stages'][name]
        old = next((r for r in stage['before'] if r.get('filename') == self.filename(0)), None)
        now = next((r for r in self.client.scan() if r.get('filename') == self.filename(0)), None)
        isolated = bool(old and now and old['id'] == now['id'])
        if name.startswith('gps-') and isolated:
            isolated = old.get('time') == now.get('time') and projection(old)['thumbnail'] == projection(now)['thumbnail']
        self.result(name + '-identity-isolation', 'pass' if isolated else 'inconclusive',
                    same_item_id=bool(old and now and old['id'] == now['id']),
                    capture_time_changed=bool(old and now and old.get('time') != now.get('time')),
                    gps_changed=bool(old and now and projection(old)['gps'] != projection(now)['gps']),
                    thumbnail_unit_changed=bool(old and now and projection(old)['thumbnail']['unit_id'] != projection(now)['thumbnail']['unit_id']),
                    thumbnail_revision_changed=bool(old and now and projection(old)['thumbnail']['cache_key'] != projection(now)['thumbnail']['cache_key']),
                    note='Combined overwrite coverage does not establish isolated GPS-only coverage.' if not isolated else 'Identity constraints satisfied.')

    def edits(self):
        # Each edit starts from a new fixture, so sticky GPS after removal cannot
        # contaminate the time/replacement tests or the large batch experiments.
        previous_cleanup = 'delete-seed'
        for name, initial_gps, gps, day, variant in [
                ('gps-gain', None, [12.25, 34.5], 1, 0),
                ('gps-change', [12.25, 34.5], [-12.5, 35.25], 1, 0),
                ('gps-removal', [12.25, 34.5], None, 1, 0),
                ('capture-time-change', None, None, 2, 0),
                ('same-path-replacement', None, None, 1, 1)]:
            setup = 'setup-' + name
            self.attempt(setup, lambda n=setup, g=initial_gps: self.mutation(n, 1, lambda: self.put(0, g)),
                         requires=(previous_cleanup,))
            self.attempt(name, lambda n=name, g=gps, d=day, v=variant:
                                 self.mutation(n, 1, lambda: self.put(0, g, d, v)), requires=(setup,))
            self.attempt(name + '-identity', lambda n=name: self.edit_identity(n), requires=(name,))
            previous_cleanup = 'cleanup-' + name
            self.attempt(previous_cleanup, lambda n=previous_cleanup: self.cleanup_current(n, [0]))
        return previous_cleanup

    def concurrent_change(self, kind):
        name = 'change-during-' + kind
        index = 900000
        def action():
            pre = self.client.version()
            read_started = time.monotonic()
            if kind == 'scan':
                observed = self.client.scan(hook=lambda: self.put(index, [12.25, 34.5]))
            else:
                rows = self.client.scan()
                owned = [r for r in rows if r.get('filename') in self.state['files']][:200]
                if len(owned) < 200:
                    raise ExperimentError('Lookup concurrency test needs 200 generated items.')
                observed = self.client.lookup([r['id'] for r in owned[:100]])
                spec = self.state['files'][owned[100]['filename']]
                self.put(spec['index'], [13.25, 35.5])
                observed.extend(self.client.lookup([r['id'] for r in owned[100:]]))
            fence, _ = self.client.diff(pre)
            stage = self.state['stages'][name]
            before = {r['id']: projection(r) for r in stage['before']}
            changed = {r['id'] for r in observed if before.get(r['id']) != projection(r)}
            modified, _ = diff_groups(fence)
            missing = changed - set(modified)
            if missing:
                stage['observed_feed_gap'] = True
            evidence = self.evidence(stage, 'concurrent-read', saved_cursor=pre,
                         observed_read=[projection(r) for r in observed], fence=fence,
                         observed_changed_ids=sorted(changed), missing_modified_ids=sorted(missing))
            self.log('immediate_concurrent_fence', kind=kind, empty=empty_diff(fence),
                     read_and_fence_seconds=round(time.monotonic() - read_started, 3),
                     observed_read=inventory_summary(observed), diff=diff_summary(fence),
                     observed_changed_items=len(changed), missing_modified_events=len(missing),
                     missing_item_ref_samples=[self.reference(i) for i in sorted(missing)[:10]], evidence=evidence)
        self.mutation(name, 1, action)

    def age_cursor(self):
        if self.state['stages'].get('cursor-aging', {}).get('done'):
            return
        if 'cursor-aging' not in self.state['stages']:
            self.state['stages']['cursor-aging'] = {'cursor': self.client.version(), 'started': time.time()}
            self.save()
        state = self.state['stages']['cursor-aging']
        self.mutation('cursor-aging-sentinel', 1, lambda: self.put(900002, [12.25, 34.5]))
        remaining = state['started'] + self.args.cursor_age_seconds - time.time()
        self.log('cursor_aging_wait', remaining_seconds=max(0, round(remaining)),
                 requested_age_seconds=self.args.cursor_age_seconds)
        while remaining > 0:
            time.sleep(min(remaining, 60))
            remaining = state['started'] + self.args.cursor_age_seconds - time.time()
        try:
            response, size = self.client.diff(state['cursor'])
            replay, _ = self.client.diff(state['cursor'])
            fence, _ = self.client.diff(cursor(response))
            sentinel = next((r for r in self.client.scan() if r.get('filename') == self.filename(900002)), None)
            modifies, _ = diff_groups(response)
            passed = response == replay and empty_diff(fence) and sentinel and sentinel['id'] in modifies
            evidence = self.evidence({'name': 'cursor-aging'}, 'comparison',
                         saved_cursor=state['cursor'], interval=response, replay=replay, fence=fence,
                         sentinel=projection(sentinel) if sentinel else None)
            self.result('cursor-aging', 'pass' if passed else 'fail',
                        explanation='The retained cursor replayed the sentinel addition with a quiet final fence.' if passed else
                                    'Sentinel coverage, replay equality or the final fence did not match expectations.',
                        replay_equal=response == replay, sentinel_present=sentinel is not None,
                        sentinel_reported=bool(sentinel and sentinel['id'] in modifies),
                        interval=diff_summary(response), fence=diff_summary(fence), evidence=evidence,
                        actual_age_seconds=round(time.time() - state['started']), diff_bytes=size,
                        note='Only the measured retention duration was tested; no reset semantics established.')
        except APIError as error:
            self.result('cursor-aging', 'inconclusive', api_error_code=error.code,
                        note='Rejection observed; expiry versus reset is not established.')
        state['done'] = True
        self.save()

    def run(self):
        credentials = load_env(PROJECT / '.env')
        if credentials['USER'] != 'phototest':
            raise ExperimentError('Only the configured phototest account may run these experiments.')
        self.prepare_root()
        self.client = self.client_factory(credentials, self.log, self.args.verify_tls)
        try:
            self.client.authenticate()
            self.log('started', resumed=bool(self.args.resume), tls_verified=self.args.verify_tls,
                     seconds_per_photo=self.args.seconds_per_photo, large_max=self.args.large_max)
            if self.args.cleanup:
                self.cleanup_current('explicit-cleanup')
                return
            discovery = self.client.read('SYNO.API.Info', 'query', 1, query='SYNO.Foto.Browse.Diff,SYNO.Foto.Browse.Item')
            self.log('capability', api_versions={k: {f: v.get(f) for f in ('minVersion', 'maxVersion')}
                                                for k, v in discovery.items()})
            if not self.args.resume:
                # Do not start tests on a partially cleaned baseline. Previous reports
                # and evidence stay intact; only ownership deletion entries are appended.
                self.attempt('startup-cleanup', self.cleanup_previous_runs)
            else:
                self.state['stages'].setdefault('startup-cleanup', {'done': True, 'ready': True, 'phase': 'done'})
            self.attempt('add-seed', lambda: self.mutation('add-seed', 1, lambda: self.put(0)),
                         requires=('startup-cleanup',))
            self.attempt('delete-seed', lambda: self.mutation('delete-seed', 1,
                         lambda: self.remove([0]) if self.filename(0) in self.state['files'] else None), requires=('add-seed',))
            # Regardless of the deletion test's Diff result, establish actual absence.
            self.attempt('seed-cleanup', lambda: self.cleanup_current('seed-cleanup', [0]))
            self.state['stages']['delete-seed']['ready'] = self.state['stages']['seed-cleanup'].get('ready', False)
            previous_cleanup = self.edits()
            self.attempt('add-equal-timestamps', lambda: self.mutation('add-equal-timestamps', self.args.equal_count,
                          lambda: [self.put(i, [12.25, 34.5]) for i in range(1000, 1000 + self.args.equal_count)]),
                          requires=(previous_cleanup,))
            self.attempt('pagination', self.pagination, requires=('add-equal-timestamps',))
            self.attempt('change-during-scan', lambda: self.concurrent_change('scan'), requires=('add-equal-timestamps',))
            self.attempt('change-during-lookup', lambda: self.concurrent_change('lookup'), requires=('add-equal-timestamps',))
            # Release every earlier fixture before independent cursor/bulk tests,
            # including a partial or timed-out equal-time batch.
            self.attempt('equal-time-cleanup', lambda: self.cleanup_current('equal-time-cleanup'))
            self.attempt('cursor-aging', self.age_cursor, requires=('equal-time-cleanup',))
            self.attempt('cursor-cleanup', lambda: self.cleanup_current('cursor-cleanup'))
            count = self.args.large_start
            largest = 0
            previous_cleanup = 'cursor-cleanup'
            while True:
                addition = f'large-add-{count}'
                deletion = f'large-delete-{count}'
                self.attempt(addition, lambda n=count, label=addition: self.mutation(label, n,
                             lambda: [self.put(100000 + i, [12.25, 34.5]) for i in range(n)]),
                             requires=(previous_cleanup,))
                largest = max(largest, self.state['stages'][addition].get('bytes', 0))
                owned = [100000 + i for i in range(count) if self.filename(100000 + i) in self.state['files']]
                self.attempt(deletion, lambda label=deletion, ids=owned: self.mutation(label, len(ids), lambda: self.remove(ids)))
                previous_cleanup = f'large-cleanup-{count}'
                self.attempt(previous_cleanup, lambda label=previous_cleanup: self.cleanup_current(label))
                if largest > 4 * 1024 * 1024 or count >= self.args.large_max:
                    break
                count = min(count * 2, self.args.large_max)
            self.result('large-interval-size-coverage', 'pass' if largest > 4 * 1024 * 1024 else 'inconclusive',
                        maximum_response_bytes=largest, largest_batch=count,
                        note='Observed coverage is not a universal guarantee against silent server truncation.')
            self.attempt('final-cleanup', lambda: self.cleanup_current('final-cleanup'))
            outcomes = {status: sum(r['status'] == status for r in self.state['results'])
                        for status in ('pass', 'fail', 'inconclusive', 'skipped')}
            self.log('finished', requests=self.client.requests, response_bytes=self.client.bytes, outcomes=outcomes)
        finally:
            if self.client.sid:
                with contextlib.suppress(Exception):
                    self.client.logout()


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume', type=Path, help='Existing docs/captures/map-diff-run-* directory')
    parser.add_argument('--cleanup', action='store_true', help='With --resume: delete only manifest-owned fixtures, then wait for indexing')
    parser.add_argument('--seconds-per-photo', type=float, default=2)
    parser.add_argument('--poll-seconds', type=float, default=30)
    parser.add_argument('--quiet-seconds', type=float, default=90)
    parser.add_argument('--cursor-age-seconds', type=float, default=3600)
    parser.add_argument('--equal-count', type=int, default=1200)
    parser.add_argument('--large-start', type=int, default=2500)
    parser.add_argument('--large-max', type=int, default=20000)
    parser.add_argument('--verify-tls', action='store_true', help='Verify the configured NAS certificate; default follows the existing Cirrus probe')
    parser.add_argument('--check-environment', action='store_true', help='Check pinned Pillow, JPEG encoding/decoding and EXIF/GPS locally; no NAS access')
    parser.add_argument('--dry-run', action='store_true', help='Print workload/timing only; no credentials, network or NAS access')
    args = parser.parse_args(argv)
    if args.cleanup and not args.resume:
        parser.error('--cleanup requires --resume')
    if min(args.seconds_per_photo, args.poll_seconds, args.quiet_seconds) <= 0 or args.cursor_age_seconds < 0:
        parser.error('Timing values must be positive (cursor age may be zero)')
    if args.equal_count <= 1000 or args.equal_count > 10000 or not 2000 < args.large_start <= args.large_max <= 20000:
        parser.error('Require 1000 < equal-count <= 10000 and 2000 < large-start <= large-max <= 20000')
    return args


def main(argv=None):
    os.umask(0o077)
    args = arguments(argv)
    if args.check_environment:
        try:
            print(json.dumps(check_environment(), sort_keys=True), flush=True)
            return 0
        except ExperimentError as error:
            print(str(error), file=sys.stderr)
            return 2
    if args.dry_run:
        counts = []
        count = args.large_start
        while True:
            counts.append(count)
            if count >= args.large_max:
                break
            count = min(count * 2, args.large_max)
        print(json.dumps({'large_batches_until_size_threshold': counts, 'maximum_live_generated_files': args.large_max + args.equal_count + 2,
                          'indexing_timeout_seconds_per_photo': args.seconds_per_photo,
                          'required_stable_seconds': args.quiet_seconds,
                          'fresh_run_cleanup': 'Remove prior manifest-owned fixtures, then verify stable API absence.',
                          'test_failure_policy': 'Record errors; skip unmet dependencies; continue independent tests.',
                          'cursor_aging_seconds': args.cursor_age_seconds,
                          'output_parent': str(CAPTURES), 'mount': str(MOUNT),
                          'excluded': ['permissions', 'service restart/reset']}, indent=2))
        return 0
    runner = None
    awake = None
    try:
        environment = check_environment()
        with (CAPTURES / '.map-diff-run.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ExperimentError('Another Map/Diff runner is already active.') from None
            runner = Runner(args)
            runner.log('environment_ready', **{k: v for k, v in environment.items() if k != 'event'})
            print('Run output: ' + str(runner.directory), flush=True)
            # No user interaction is needed to keep this Mac awake during a long run.
            if sys.platform == 'darwin':
                awake = subprocess.Popen(['/usr/bin/caffeinate', '-i', '-w', str(os.getpid())])
            runner.run()
            if args.cleanup:
                return 0 if runner.state['stages'].get('explicit-cleanup', {}).get('ready', False) else 2
            if not runner.state['stages'].get('startup-cleanup', {}).get('ready', False):
                return 2
            return 1 if any(r['status'] == 'fail' for r in runner.state['results']) else 0
    except (KeyboardInterrupt, Exception) as error:
        # Never print arbitrary exceptions: urllib errors can contain authenticated URLs.
        reason = str(error) if isinstance(error, ExperimentError) else ('Interrupted; fixtures retained.' if isinstance(error, KeyboardInterrupt) else 'Runner failed; private exception details suppressed.')
        if runner:
            runner.result(runner.state.get('active') or 'runner', 'inconclusive', reason=reason,
                          exception_type=type(error).__name__,
                          stack=[{'file': Path(frame.filename).name, 'function': frame.name, 'line': frame.lineno}
                                 for frame in traceback.extract_tb(error.__traceback__)])
        else:
            print(reason, file=sys.stderr)
        return 130 if isinstance(error, KeyboardInterrupt) else 2
    finally:
        if awake:
            awake.terminate()
            awake.wait()


def interrupt(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
