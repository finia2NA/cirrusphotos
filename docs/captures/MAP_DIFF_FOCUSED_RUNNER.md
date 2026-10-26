# Second Map/Diff runner: focused date comparison

Run:

```sh
make test-map-diff-2
```

Preview locally:

```sh
make test-map-diff-2 MAP_DIFF_2_ARGS='--dry-run'
```

This is a separate script, `scripts/test_map_diff_focused.py`. It creates 12
small JPEGs across historical (January 2020) and current-date cohorts. One case
is active at a time. Each cohort tests addition/deletion, GPS gain, GPS change,
GPS removal, capture-time change and pixel replacement. Each edit has its own
fresh fixture, followed by deletion and cleanup; a retained GPS value cannot
contaminate the next case. Identical synthetic pixels and encoding are used for
both cohorts so their initial controlled difference is EXIF date, rather than
image content. Current capture time is chosen after obtaining its baseline
cursor, immediately before copying; EXIF whole-second precision is accounted for.

The goal is to investigate the missing modification events from the first run,
not to establish bulk completeness or enable production Diff. It uses the same
observed v1 Diff cursor/request contract for both cohorts. No guessed parameters
or cursor conversions are introduced. It does not test web upload, permissions,
service restart, large responses, bulk pagination, or long cursor retention.

## Readiness and observations

- Inconsistent/duplicate scans and transient read errors are logged and retried
  within the observation deadline. A bad first scan no longer immediately ends
  an indexing test.
- A target discovered by unique generated filename is corroborated through a
  direct ID lookup and a separately paginated folder listing. Known IDs are
  retained privately, so a later hole in a whole-library listing can be checked
  directly rather than interpreted as deletion.
- Deletion requires the owned file to have been unlinked, its filename to be
  absent from a consistent listing, and its known IDs to be absent from direct
  lookups. Omitted IDs alone are not a deletion verdict or an access claim.
- Only changes to the controlled, directly read target contribute to Diff
  coverage/gap checks. Unrelated missing rows in offset scans are never turned
  into expected deletion events.
- The expected state must remain stable for **90 seconds**. Cursor-only progress
  does not reset the timer; target metadata or change-list changes do. A later
  thumbnail revision resets the quiet timer without throwing away the available
  settling allowance.

The defaults provide **10 minutes to observe expected metadata**, then a separate
**10-minute bounded settling window** starting when the expected state first
appears. This avoids the earlier 180-second cap that cut off late but correct
updates. Retries reset continuous stability; sampling interruptions are recorded
and cannot earn an unqualified continuous-observation pass. A missing change in
an otherwise complete final comparison remains a failure even if an interrupted
sample also occurred.

Independent cases continue after failed checks and timeouts. Cases whose setup
never establishes the required fixture are skipped with a reason. Cleanup is
still attempted. Mount/ownership violations stop unsafe writes. Successful cases
need several 90-second quiet windows each, so the full default matrix can take
roughly an hour or more even with fast indexing; timeouts can make it longer.
This script does not create thousands of photos.

To adjust bounds (the default quiet period is already 90 seconds):

```sh
make test-map-diff-2 MAP_DIFF_2_ARGS='--index-timeout-seconds 900 --settle-timeout-seconds 900'
```

## Environment, files and output

The Make target uses the existing `.venv`, pinned Pillow dependency and JPEG/GPS
preflight. No new pip dependencies are required. The account must be `phototest`,
and `/Volumes/homes/phototest/Photos` must be the expected mounted path. The same
runner lock prevents simultaneous bulk/focused experiments. `caffeinate` keeps
the Mac awake.

The shared ownership journal and marker checks limit filesystem changes to
recorded generated fixtures in `Photos/syno-diff-tests/<run-id>`. Fresh runs
clean previous journal-owned fixtures and verify API disappearance; prior reports
and evidence are retained. Existing photos and unrecorded files are preserved.
No NAS photo mutation endpoints are used. See [shared runner documentation](MAP_DIFF_RUNNER.md)
for the filesystem ownership and privacy rules.

Each run prints its directory under `docs/captures/map-diff-run-<timestamp>/`:

- `events.jsonl`: the detailed terminal stream, including API timing/bytes/errors,
  retries, listing/lookup corroboration, readiness, stable seconds and outcomes.
- `report.json`: named checks and reasons for every pass/fail/inconclusive/skip,
  interval/replay/fence summaries, identity changes, timings and evidence paths.
- `cohort-summary.json`: addition/edit/deletion coverage totals by historical versus
  current date, including incomplete comparisons and visibility-gap counts.
  Differences are observations, not proof of a universal date filter.
- `state.json`, `ownership.jsonl`, `evidence/<stage>/*.json.gz`: private recipes,
  known IDs, exact cursors, metadata projections and replay/comparison evidence.
  Stage recipes preserve capture dates across resume. Authentication material is
  excluded; terminal/report item references are anonymized.

All run directories remain ignored by Git. Production Diff stays disabled.

Resume or clean up a **focused** run (the script refuses bulk-run checkpoints):

```sh
make test-map-diff-2 MAP_DIFF_2_ARGS='--resume docs/captures/map-diff-run-<run-id>'
make test-map-diff-2 MAP_DIFF_2_ARGS='--resume docs/captures/map-diff-run-<run-id> --cleanup'
```

An interrupted mutation is not replayed as clean evidence. Start a fresh run to
clean and recreate it. An interrupted observation is marked as such. Repeated
resume does not invent continuous monitoring for the time the process was absent.

Offline tests, with no credentials or NAS access:

```sh
make test-map-diff-2-script
```
