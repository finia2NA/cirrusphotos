# Diff v7 `list`: Android capture and third runner (2026-10-26)

## Android capture

Setup: official Synology Photos 2.4.0 on a disposable Android 14 emulator, HTTPS interception through a locally trusted CA, credentials and tokens redacted before saving, no raw HAR. One small geotagged JPEG was added to the test Personal Space and then removed.

- Cache bootstrap: Item v7 `list_all` with `id_before=-1`, `limit=1000`, GPS and thumbnail fields. The test library had one item, so pagination was not exercised.
- Later updates used Diff v7 `list`, alongside v7 `get` and `list_user_event`.

Same account, same saved cursor, `additional=["gps","thumbnail"]`:

| Version | Method | Addition |
| --- | --- | --- |
| 1 | `get` | success, zero modifications |
| 1 | `list` | error 103 |
| 7 | `get` | success, zero modifications |
| 7 | `list` | one modification with GPS and thumbnail, `has_next=false` |

Deletion was returned by v1 `get` and v7 `list`. v7 replay matched and the returned-cursor fence was empty. The Android Places map showed the fixture. A warm restart used Diff v7 `list` and did not repeat `list_all`.

Conclusion: the mobile item feed is v7 `list`; changing the version on `get` is not enough.

## Third runner

Ran 2 h 33 min: 48 pass, 4 inconclusive, 0 fail, 0 skipped (pass count includes cleanup checks).

| Observation | Result |
| --- | --- |
| Historical and current-date additions | 12/12, zero missing events |
| GPS gain/change, capture-time, pixel edits | 8/8, identity preserved, replay and fence checks passed |
| Focused deletions | 12/12, exact tombstones, empty fences |
| GPS removal | Both inconclusive (old coordinates persisted); Diff did report a modification |
| 5,000-photo addition | Inventory eventually correct, but content revisions kept changing, so no 90-second stable window |
| Bulk Diff completeness | Unproven: all 30 observation responses had `has_next=true` with 2,000 modified items (largest 2.5 MB) |
| Bulk deletion | Inconclusive: a nonempty baseline fence blocked the measured test; cleanup still removed all files |

## Bounded follow-up

Reopening the Android app returned all 5,012 known test tombstones in one terminal `list` response (`has_next=false`, zero modifications), matching a read-only replay with an empty fence and no duplicates.

## Decision

Investigation stopped at reasonable confidence. The first product slice repairs only small, complete v7 intervals and falls back to a full scan on `has_next=true`, more than 2,000 changed IDs, or unsupported activity (`merge`, `move`, `similar`). Not verified: modification pagination, `list_user_event` semantics, service reset, access changes, large-interval coverage.
