# Official Android Map/Diff capture — 2026-10-26

The official Synology Photos Android app uses an item change feed that our earlier experiments did not test. A controlled addition appeared in **Diff v7 `list`**, while both v1 and v7 `get` returned no modified items from the same cursor. The Android Places map displayed the fixture using the captured update.

## Setup and capture

- Official vendor APK: Synology Photos 2.4.0 (644), package `com.synology.projectkailash`; APK signature verified as Synology.
- Disposable Pixel 8 / Android 14 Google APIs emulator, ADB serial `emulator-5556`; existing user AVD unchanged.
- Test Personal Space, with the existing mounted filesystem test area. One new owned, small JPEG with synthetic GPS was added, then removed. No Photos mutation endpoint or service reset was used by the probe.
- HTTPS interception worked using a CA trusted inside this emulator. Host trust/proxy settings were unchanged. The local capture proxy accepts the NAS upstream certificate without ordinary validation; this is scoped test tooling, not an application change.
- Credentials/session tokens are redacted before saving request/response JSON. Headers and binary media bodies are omitted. No raw HAR/flow recording was enabled. Photo IDs, opaque cursors, and metadata still make the ignored capture evidence private.

The initial mobile cache bootstrap requested Item v7 `list_all` with `id_before=-1`, `limit=1000` and GPS/thumbnail fields. The initial library contained one item, so pagination is unproven. Subsequent mobile updates used Diff v7 `list`, alongside v7 `get` and `list_user_event`. The exact fields and response shapes are documented in [the API notes](../SYNOLOGY_PHOTOS_API.md#official-android-request-contract-2026-10-26).

## Controlled observations

Authoritative Item `list_all` exposed the added photo and its GPS. The comparison waited for 90 seconds of unchanged target metadata. V7 `list` returned it once, replay returned the same record, and the returned-cursor fence was empty. The captured Android refresh independently returned the fixture and its Places map showed the thumbnail pin.

A separate matrix used the same account, saved cursor, language and `additional=["gps","thumbnail"]`:

| Version | Method | Addition result |
| --- | --- | --- |
| 1 | `get` | Success; zero modifications |
| 1 | `list` | Error 103 |
| 7 | `get` | Success; zero modifications |
| 7 | `list` | One modification with GPS/thumbnail; `has_next=false` |

After unlinking only the journaled fixture, authoritative absence remained stable for 90 seconds. Both v1 `get` and v7 `list` returned its deletion. V7 replay matched, and the returned-cursor fence was empty. The owned file is absent and the final library inventory contains the original single item.

The initial force-stop/reopen check encountered emulator UI/screenshot stalls. Restarting the disposable emulator with software rendering restored the signed-in Photos screen. The subsequent captured startup (JSONL records 70–88) used Diff v7 `list` and did not repeat Item `list_all`; its interval was empty after the previous update had consumed the deletion. This supports cache reuse in this tiny library, but is not a large-library startup timing measurement. `restored-emulator.png` records the restored UI.

## Implication and remaining work

Use the observed **v7 `list` contract** as the starting point for further item-cache experiments. Switching the version number on `get` is insufficient. The old v1 tests remain evidence about that request, not evidence that the mobile item feed fails identically.

This single-photo test does not establish edit/GPS-removal coverage, multi-page `list_all` completeness, Diff continuation (`has_next`), the meaning of `merge`/`move`/`similar`, interaction with `list_user_event`, access changes, reset behavior, or large-interval coverage. Production Map validation is unchanged. Revise the focused runner around this contract before another bulk run; retain direct metadata corroboration, stable indexing waits, replay/fence evidence and scoped cleanup.

Private evidence: `docs/captures/android-photos-session-2026-10-26/` contains sanitized mobile `requests.jsonl`, the method matrix, baseline/comparison/replay/fence files for addition and deletion, console logs, `summary.json`, and the map screenshot. The first JSONL record is a Mac connectivity probe, not Android traffic. Temporary tooling and separate proxy dependencies are in ignored `.cache/android-photos-capture/`.

## Bounded follow-up after the third run

The disposable Android app was reopened with its retained cache/cursor. Its v7
`list` response (private JSONL record 139) contained **5,012 deletion IDs**, zero
modifications and `has_next=false`. No continuation request was needed. A separate
read-only probe matched the captured response, verified that the tombstones were
exactly the 5,012 known IDs from the third-runner journal, found no duplicates,
replayed identically, and obtained an empty final fence. The inventory contained
only the original photo. No new NAS photo mutations or batch uploads were made.
Private checks are in `followup-verification.json` and `followup-events.jsonl`.

This establishes a large terminal deletion response, **not** continuation of the
2,000-modification partial responses. Rather than create another bulk experiment,
the first implementation will repair only bounded terminal intervals and rebuild
for `has_next=true` or more than 2,000 changed IDs. Modification pagination remains
unimplemented and is not needed for that fallback. Investigation stops here at
the user's requested reasonable-confidence threshold; see the revised Map plan.
