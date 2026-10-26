# Third Map/Diff runner: captured mobile protocol

Run on the Mac; Android and the interception proxy are not needed:

```sh
make test-map-diff-3
```

Preview the workload without credentials, NAS access, or filesystem mutations:

```sh
make test-map-diff-3 MAP_DIFF_3_ARGS='--dry-run'
```

The Make target uses `.venv`, installs the existing pinned Pillow requirement if needed, checks dependencies, and exercises JPEG/EXIF/GPS encoding before starting. There are **no new pip dependencies**. A read-only current-cursor v7 response-shape check runs before fixture tests; successful JSON alone is not a coverage claim.

## Tests and timing

`scripts/test_map_diff_mobile.py` repeats the second runner's 12 isolated fixtures: historical/current-date addition/deletion, GPS gain/change/removal, capture-time changes, and pixel replacement. Each edit gets a fresh file. It uses the captured **Diff v7 `get_version` / `list`** requests and the captured `additional` fields, rather than v1 `get`.

It then copies **5,000 small geotagged JPEGs with equal capture timestamps**, waits for expected indexed metadata, compares the original-cursor interval/replay/returned-cursor fence, and deletes that batch. The global inventory uses Item v7 `list_all`; an independent folder offset walk corroborates the owned additions, and direct-ID reads corroborate deletion. The candidate inventory walk advances `id_before` to the previous page's final ID, requiring strict descending IDs, exclusive boundaries and a terminal short page. Its completeness is **under test**, not assumed from the initial one-page mobile capture.

All files in a batch are copied before indexing waits begin. There are no per-photo sleeps. Defaults:

- Poll every 15 seconds and require **90 seconds** of unchanged expected state.
- Focused stages allow 10 minutes for indexing, then a separate 10-minute settling window once the desired state first appears.
- Bulk stages and cleanup allow at least **2 × photo count seconds** for indexing: 10,000 seconds (2h 47m) for a 5,000-photo batch, plus the settling window. They finish earlier once readiness and stability are demonstrated. This allowance is a timeout budget, not a mandatory sleep.

Expect the focused matrix to take roughly an hour or longer, plus bulk copying/indexing/deletion. Allow several hours or overnight; failures/timeouts can extend it. `caffeinate` keeps the Mac awake. An ordinary failed case does not stop independent cases or cleanup. Lost mount or ownership violations stop unsafe writes.

Focused-only or a smaller pagination batch:

```sh
make test-map-diff-3 MAP_DIFF_3_ARGS='--bulk-count 0'
make test-map-diff-3 MAP_DIFF_3_ARGS='--bulk-count 1200'
```

Nonzero batch sizes must be 1,001–20,000. `--seconds-per-photo`, `--index-timeout-seconds`, `--settle-timeout-seconds`, `--poll-seconds`, and `--quiet-seconds` adjust observation bounds. Defaults are suitable for an unattended run.

## Partial intervals and interpretation

V7 responses retain their actual `item.modify/delete/merge/move`, `similar`, and `has_next` fields. No album group is fabricated. Unknown shapes fail closed; merge/move/similar activity prevents an unqualified coverage pass.

If `has_next=true`, the compressed response is saved **before rejection** and the interval is marked incomplete. The script does not guess Diff continuation parameters or advance a partial interval's cursor. Bulk inventory observation can still finish and record expected metadata; deletion and cleanup still run. A partial-interval outcome is inconclusive, never success. Further protocol work may be required after that run.

Reports distinguish eventual coverage from an observed metadata/feed gap. Repeated sampling interruptions prevent an unqualified continuous-observation pass. Owned identities and direct reads constrain deletion claims; unrelated scan omissions are not automatically treated as deletion events. No results enable production Diff validation. Permissions, service resets, long retention, API photo writes, and the separate `list_user_event` feed's semantics remain outside this script.

## Logs, cleanup, and recovery

The run prints its private directory under:

`<repo>/docs/captures/map-diff-run-<timestamp>-<id>/`

- `events.jsonl` mirrors detailed terminal events: request timings/bytes/errors, copy progress, inventory/page counts, readiness, stability, retries, feed coverage, and outcomes.
- `report.json` contains named checks, failure/inconclusive reasons, expected/missing event counts, replay/fence summaries, response sizes, protocol/configuration, and evidence links.
- `cohort-summary.json` summarizes focused historical/current-date coverage.
- `mobile-responses/*.json.gz` preserves exact item-feed response data and request cursors, including incomplete/rejected shapes. `evidence/` contains baseline, observed and independent inventories, comparison/replay/fence data, and first-gap evidence.
- `state.json` and `ownership.jsonl` retain checkpoint/fixture ownership. Authentication material is excluded; private metadata and opaque cursors still require keeping run directories private/ignored.

Only the configured `phototest` account and the known mount are accepted. The existing shared runner lock prevents concurrent experiments. Fresh runs clean earlier journal-owned fixtures and wait for indexed absence. Only recorded generated files under `Photos/syno-diff-tests/<run-id>` are removed; unrelated photos and files are preserved. Each case and the full run attempt cleanup.

Resume only a **third-runner** checkpoint:

```sh
make test-map-diff-3 MAP_DIFF_3_ARGS='--resume docs/captures/map-diff-run-<run-id>'
make test-map-diff-3 MAP_DIFF_3_ARGS='--resume docs/captures/map-diff-run-<run-id> --cleanup'
```

The runner rejects checkpoints from the first/second runners. Saved settings govern a resumed run. An interrupted mutation is not replayed as clean evidence: cleanup remains available, or a fresh run cleans owned leftovers and starts new measurements. A resumed observation cannot claim uninterrupted monitoring.

Exit status is 0 for all passing checks, 1 for failed checks, and 2 for inconclusive/skipped checks or setup errors (130 for interruption). Results and cleanup are written before the final status. Inspect `report.json` even if the command exits nonzero.

Offline verification (no NAS access):

```sh
make test-map-diff-3-script
```
