# Capture findings

What was tested against the Synology Photos service, and what was found. Each file is a sanitized summary of private evidence kept in the ignored `docs/captures/` directory (HAR files, runner output, Android proxy captures). The raw evidence is not synced; no hostnames, credentials, sharing references, item IDs or cursors appear here.

Other documents cite evidence through these files and name raw captures only as "local only".

Current API behavior lives in [`../SYNOLOGY_PHOTOS_API.md`](../SYNOLOGY_PHOTOS_API.md). These files record how that behavior was established and what remains unverified.

| File | Topic |
| --- | --- |
| [map-diff-v1-runs.md](map-diff-v1-runs.md) | Bulk and focused experiments on Diff v1 `get` and filesystem indexing |
| [map-diff-v7-mobile.md](map-diff-v7-mobile.md) | Official Android capture of Diff v7 `list` and the third runner built on it |
| [timeline-paging.md](timeline-paging.md) | Wire topology of timeline sections and the stable day-slot model |
| [video-streaming.md](video-streaming.md) | `Streaming` and `Download` range behavior, plus the Android client's playback requests |
| [album-sharing.md](album-sharing.md) | Album membership, sharing, public links, recipients and Provider access |
| [tags-and-ratings.md](tags-and-ratings.md) | Tag creation and assignment, ratings, and how both reach the cache |

## Runners

The experiments ran against the disposable `phototest` account using journal-scoped cleanup (only generated files recorded in an ownership journal are removed). Run output goes to `docs/captures/map-diff-run-*/`.

| Target | Script | Scope |
| --- | --- | --- |
| `make test-map-diff` | `scripts/test_map_diff.py` | Bulk: single edits, 1,200 equal-time photos, 2,500–20,000 photo batches, one-hour cursor age |
| `make test-map-diff-2` | `scripts/test_map_diff_focused.py` | 12 isolated fixtures across January 2020 and current-date cohorts |
| `make test-map-diff-3` | `scripts/test_map_diff_mobile.py` | The 12 fixtures plus a 5,000-photo batch using the captured v7 requests |

Common rules: a 90-second unchanged window before a state counts as settled, 15–30 second polling, a separate settling deadline, deletion claims only after filesystem unlink plus direct-ID absence, and exit codes 0 (all pass), 1 (failed checks), 2 (inconclusive, skipped or setup error), 130 (interrupted). Permission changes, service resets and long cursor retention were never tested. Offline script tests: `make test-map-diff-script`, `-2-script`, `-3-script`.
