# Unattended Map/Diff experiments

For the small historical/current-date follow-up, use the [second runner](MAP_DIFF_FOCUSED_RUNNER.md) and `make test-map-diff-2`. This document describes the original bulk suite.

`scripts/test_map_diff.py` generates disposable JPEGs in
`/Volumes/homes/phototest/Photos/syno-diff-tests/<run-id>` and observes Synology's
filesystem indexing through read-only Photos APIs. It requires the existing
`.env` to name `phototest`; no credentials are passed on the command line or
persisted in reports. `OTP` remains optional. Python 3.10+ and **Pillow** are
needed. Pillow is the only pip dependency; all networking, logging, timing and
tests use Python's standard library.

The Make targets create or reuse the repository `.venv` and install the pinned
`scripts/requirements-map-diff.txt` when needed. No shell activation is required.
Before every run, a local preflight checks the installed Pillow version and
actually generates, decodes and checks a JPEG with timestamp and GPS EXIF. The
runner repeats that preflight before authentication or NAS writes and records
the Python/Pillow versions in its log. Setup alone can be run with:

```sh
make map-diff-env
```

A normal invocation starts a **fresh run**. Before creating test photos, it
finds prior local run manifests, verifies their matching ownership markers on
the mount, removes only those recorded JPEGs, and waits until their API entries
have disappeared and the inventory has remained stable for 90 seconds. Previous
reports and evidence are preserved; deletion records are appended to their
ownership journals. It never empties the whole Photos directory or deletes
unrecorded files. Use this normal command to restart after a timed-out test.

Run from the repository:

```sh
make test-map-diff
```

Preview without credentials, NAS requests or mount access (first-time environment
setup may download Pillow; preflight generates a temporary local JPEG):

```sh
make test-map-diff MAP_DIFF_ARGS='--dry-run'
```

The runner keeps the Mac awake using `caffeinate`. The mount and NAS must stay
connected. It never changes permissions, restarts services, or invokes a NAS
photo mutation endpoint. Filesystem changes are confined to its own generated
files. It preserves the existing screenshot and other user files.

## Stages and timing

- Seed creation/deletion; GPS gain, change and removal; capture-time changes;
  same-path pixel replacement, recording whether Synology preserves the item ID.
  Each edit has its own freshly created fixture and cleanup, so retained GPS
  after a removal test does not contaminate later tests.
- 1,200 identical-capture-time photos. Compare the generated manifest with a
  folder-scoped 137-item enumeration, then repeat whole-library scans at 1,000
  and 333 items per page, including the production-style two-request overlap.
- A change between scan pages and a change between two arbitrary-ID lookup
  batches. Record the immediate fence and eventual Diff coverage.
- Retain a cursor across a controlled sentinel addition and a one-hour pause;
  replay it and check the returned cursor. Only that actual age is tested.
- Large additions/deletions at 2,500, 5,000, 10,000 and up to 20,000 items, stopping
  growth once an addition response exceeds 4 MiB. Batch sizes exceed the 2,000-ID
  client policy; response bytes are measured rather than inferred. The probe has
  a separate 64 MiB transport ceiling, so it can examine responses beyond the
  production 4 MiB limit.
- Delete remaining manifest-owned JPEGs and verify their disappearance. Hidden
  ownership markers and Synology/Finder-created files are left alone.

After copying the entire batch, the runner polls until every expected photo is
visible with the expected metadata (or every deleted photo is absent), and both
the inventory and Diff remain unchanged for **90 seconds**. It then advances
immediately; there is no mandatory two-seconds-per-photo sleep.

The indexing timeout is **two seconds per affected photo**, with a 90-second
floor. A final 90-second quiet window may finish after that deadline if the
expected state has already appeared. Missing expected content at the indexing
deadline, or continued changes beyond the final quiet allowance, record an
inconclusive test with its latest evidence. Independent tests continue; stages
that require an unestablished indexed fixture are explicitly marked **skipped**
with their unmet dependencies. Cleanup is still attempted, and later independent
fixture groups start from their own baseline. Polling also samples indexing while files are copied;
that time does not consume the post-copy indexing budget.

There are at most 21,202 live generated files. Runtime depends on actual indexing
speed, file creation and API calls, plus the explicit one-hour cursor-aging pause.
Large batches can still take hours, but fast indexing now advances early.

Options can be passed through `MAP_DIFF_ARGS`, for example:

```sh
make test-map-diff MAP_DIFF_ARGS='--large-max 5000 --cursor-age-seconds 7200'
```

A smaller cap may leave the 4 MiB coverage test inconclusive. The default poll
period is 30 seconds. `--seconds-per-photo`, `--quiet-seconds`, `--poll-seconds`,
`--equal-count`, `--large-start`, `--large-max`, and `--cursor-age-seconds` are
configurable. The test account uses the same Cirrus certificate exception as the
existing login probe; `--verify-tls` requests normal certificate validation.

## Output and recovery

A failed assertion or an indexing timeout does **not** stop the overnight suite.
This includes the previously observed GPS-removal timeout. API/ordinary test
exceptions are recorded at the stage boundary; independent stages continue.
Mount/ownership violations still stop writes. Authentication, missing environment
prerequisites or failure to establish a clean startup baseline can prevent the
suite from proceeding; their outcomes are recorded rather than claiming tests
ran. Startup-baseline failure produces skipped test stages and exit 2.

Each invocation creates `docs/captures/map-diff-run-<UTC-date>-<suffix>/`:

- `events.jsonl`: the same detailed JSON records printed to the terminal. Includes
  stage baselines, mutation/write durations, expected/observed counts, missing or
  incorrect fixture samples, inventory digests, first observed item/feed changes,
  request latency/bytes/API errors, remaining timeout and 90-second stability
  progress. Requests are attributed to the active stage; no request bodies or
  authenticated URLs are logged.
- `report.json`: aggregate pass/fail/inconclusive/skipped results. An observed transient
  authoritative change missing from Diff remains a failure after eventual
  convergence. Unknown response fields and nonempty final fences cannot pass.
  Each comparison includes named checks and explicit unmet-check explanations,
  field-change counts, anonymized item references, before/after inventory
  summaries, original/replayed/final Diff summaries, elapsed/write/indexing times,
  and a relative path to its evidence. Pagination records counts, membership,
  ordering and the first differing ordinal for each scan variant.
- `state.json`: private checkpoints, baseline inventories and exact opaque
  cursors for replay. No passwords, OTPs, cookies, session IDs or tokens.
- `ownership.jsonl`: durable intent journal for generated filenames and metadata.
- `evidence/<stage>/*.json.gz`: private compressed evidence. Baselines, latest
  observed state, the first feed-visibility gap (if any), and final comparison
  snapshots retain projected item IDs/time/GPS/thumbnail metadata and the exact
  cursor/change-ID contract for intervals, replays and fences. Unknown response
  fields are summarized by type; arbitrary response fields and auth envelopes
  are not saved. The latest sample is overwritten to bound storage, while the
  first gap and final comparisons remain available after cleanup.

The run directory is ignored by Git and created with private permissions. Treat
`state.json`, `ownership.jsonl` and `evidence/` as private; do not commit them. Reports do not
print raw item IDs, filenames, coordinates, cursor values, or authenticated URLs.
Item references are stable within a run, so the same case can be followed across
stages without printing raw IDs. Synthetic fixture indices identify missing or
incorrect generated inputs. On failure, the report also carries the last
observation, artifact references, exception class and stack locations (without
local variables or exception text that could contain authenticated URLs).
Sanitize any evidence before promoting it to committed fixtures.

For investigation, start with `report.json`, follow its `evidence` path, then use
`events.jsonl` to reconstruct indexing and feed timing. For example, a missing
modification identifies a failed named check, an anonymized case reference and
full private before/after projections; a successful test retains the same
comparison evidence rather than only its pass label.

Ctrl+C stops the runner and retains the run. Resume an interrupted observation
or cursor-aging wait with:

```sh
make test-map-diff MAP_DIFF_ARGS='--resume docs/captures/map-diff-run-<run-id>'
```

Persisted timing/batch settings take precedence on resume. An interrupted
observation is inconclusive for continuous visibility timing. A crash during a
filesystem mutation cannot be replayed as the same experiment: the interrupted
stage is recorded inconclusive and independent stages may continue after cleanup.
For the earlier GPS-removal run, a fresh run is recommended because it supplies
clean baselines and isolated edit fixtures. Its durable ownership journal also
allows a cleanup-only invocation:

```sh
make test-map-diff MAP_DIFF_ARGS='--resume docs/captures/map-diff-run-<run-id> --cleanup'
```

Cleanup deletes only manifest-owned generated JPEGs, then waits for indexing.
No recursive deletion is performed. Only one runner is admitted at a time.

Exit status: 0 means all scheduled stages completed without a failed result
(inconclusive results can still exist); 1 means completed with failed evidence;
2 means startup could not establish a clean baseline or the run stopped/incomplete;
130 means interrupted. Cleanup-only mode returns 0 on successful cleanup even if
the original report contains failed tests. Read `report.json` rather than
using exit 0 as permission to enable production Diff validation.

## Limits of the evidence

These tests exercise filesystem reindexing, not every web/mobile mutation path.
Polling produces sampled timing bounds, not proof that no shorter feed delay
exists. A scan taken during indexing may be inconsistent; a duplicate/capped or
malformed inventory fails the affected stage instead of inventing completeness.
Same-path overwrites may change identity, capture time or thumbnail revision;
isolated-GPS coverage is inconclusive when those fields also change. Synthetic
filenames are intentionally long to help exercise large responses.

A passing bulk test cannot prove universal absence of silent truncation, and a
quiet fence cannot by itself prove a complete enumeration. The manifest and
folder-scoped comparison provide independent checks for the generated fixture
set. Existing unrelated items are included in before/after inventories, but the
script has no independent filesystem-to-ID inventory for those items. Server
and Photos package builds still need to be recorded with any promoted evidence;
API min/max versions are logged automatically but are not package build IDs.
Permission and cursor-reset/restart gates remain explicitly excluded. Nothing in
this runner enables production Diff or treats the remaining gates as passed.

Offline verification:

```sh
make test-map-diff-script
```

The offline suite uses temporary local directories, synthetic API responses and
a simulated clock. It never opens `.env`, calls the NAS, or sleeps for indexing.
