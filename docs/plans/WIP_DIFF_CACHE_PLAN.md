# Diff-based cache validation

Status: implementation plan, not implemented. Reviewed against the code on 2026-10-08. Complete the protocol evidence gate below before implementing the production delta path. This document changes no current application behavior.

The first slice updates the Personal Library location index. Timeline/page/album request suppression is a separate deferred slice with stricter proof requirements. This addresses the expensive map rescan without introducing a whole-library synchronization engine. No polling, Shared Space support, image-validation changes, or new NAS writes are included.

## Current behavior and corrections

Read [architecture](../ARCHITECTURE.md#locations-and-map), [cache design](WIP_CACHING_PLAN.md), and [recorded API evidence](../SYNOLOGY_PHOTOS_API.md#library-change-feed) together. The cache design document contains historical proposals, including pending albums/maps and GRDB; the source and architecture describe the current SQLite3 implementation and completed album/map features.

- `Sources/PhotoCache/LocationIndex.swift`: `locationIndex()` emits cached records, joins Personal Library timeline validation, and compares `LibraryIndex.fingerprint`. A mismatch runs `runLocationIndexScan`, using 1,000-item positional pages, up to two concurrent requests, and a 2,048-page cap. It persists located records, scanned count, schema version, and source fingerprint. No cursor is stored.
- `Sources/PhotoCache/CachedPhotosRepository+Metadata.swift`: `timeline` and `page` use `validationRun(for:)`, including run ID, collection, and mutation epoch. Exact page keys contain collection, date bounds, offset, limit, and requested additional fields. There is no item-membership index or durable cursor dependency.
- `Sources/PhotoCache/CachedPhotosRepository+Albums.swift` separately validates the album list. Opened album snapshots are synthesized by `SynologyClient.albumTimeline(albumID:)`. These resources retain their current validation paths in the first slice.
- `Sources/PhotoCache/DiskCache.swift` stores metadata JSON in SQLite and images in files. SQLite schema version is currently 1. `put` can silently decline a stale generation, so its return does not prove persistence. `clearCache()` currently cancels the location job and advances disk generation through `store.clear()`.

Do not carry forward these unsafe assumptions:

1. Intersecting changed IDs with IDs already in a cached page cannot validate membership. An insertion, a capture-date change into a range, or a deletion elsewhere in a split day can shift an offset without touching any cached ID. Favorites and album membership have the same problem.
2. Equal day counts or equal fingerprints do not prove unchanged GPS, thumbnails, order, or identity. A same-day delete/add can preserve counts. Changed-day rescanning is not a correctness-preserving fallback for a rejected or incomplete feed.
3. A cursor obtained after a scan cannot simply be attached to it. Changes during positional pagination can skip or duplicate items. The payload must demonstrably cover the cursor's interval.
4. Advancing a global cursor after updating Map leaves unopened albums and undemanded pages behind. Map owns its cursor inside its payload and cannot validate another resource.
5. Diff does not prove image-validator or rendition-key correctness. Keep conditional thumbnail/original validation and manual range-download behavior unchanged.

## Protocol evidence gate

The 2026-10-06 read-only probe established only that `SYNO.Foto.Browse.Diff` is advertised at versions 1–7, `get_version` v1 returns the opaque pair `diff_version`/`version_time`, and `get` with the current pair returns empty item/album modify/delete arrays. Missing cursor fields returned 120; a deliberately mismatched pair returned 700. Error 700 is not yet proven to mean expired cursor. Preserve both fields exactly as issued; do not derive cursors from dates or order them numerically.

The vendored `docs/SynologyPhotosAPI/API/SYNO.Foto.lib` advertises Diff but supplies no change semantics. `docs/SynologyPhotosAPI/API/SYNO.Foto/SYNO.Foto.Browse.Item.list.md` describes pagination and optional GPS fields, but establishes no arbitrary-ID batch lookup contract. Do not invent `item_ids`, `getinfo`, continuation fields, or tombstone shapes.

Before enabling the map delta path, add sanitized fixtures and conclusions to `docs/SYNOLOGY_PHOTOS_API.md` for all of the following:

| Required evidence | Implementation consequence |
| --- | --- |
| Actual addition, modification, deletion entries; item ID versus thumbnail unit ID; overlapping modify/delete entries; repeated changes | Define strict decoding and unambiguous final-state normalization. Never assume delete wins without evidence. |
| GPS added/changed/removed, capture time changed, deletion, thumbnail regeneration/replacement, photo/Live Photo/video representation | The feed must cover every field stored by Map. Missing coverage blocks delta validation, including the empty-delta shortcut. |
| Complete interval from an older pair to the returned pair; truncation, continuation, reset, overflow, and large-import behavior | Partial change lists cannot authorize commits. Implement actual bounded pagination only if observed; reject ambiguous/over-limit responses. |
| Read-only lookup of specified item IDs, fields, batch limit, missing/deleted/inaccessible IDs, order, and GPS-absence semantics | Repair needs authoritative metadata or complete feed records. A missing response is not automatically a deletion. |
| A second Diff call after metadata reads detects changes during those reads; indexing delay between item reads and feed visibility | Establish the consistency fence below. If visibility lags without a reliable fence, leave the optimization disabled. |
| Rejection/reset of a previously valid cursor and account isolation | Classify known rejection separately from auth, malformed requests, unsupported API, and transient failure. Unknown errors never become empty deltas. |

Cursor retention duration is an operational measurement, not a guessed TTL. Safe rejection handling permits implementation without knowing the maximum age. Shared Space and condition-album semantics are not prerequisites for the map slice.

A HAR would materially help: capture the Synology Photos web app in Personal Space from initial load through refresh after a user-performed import of one disposable geotagged photo, GPS change/removal, capture-time change, deletion, and a bulk import. Include `SYNO.API.Info`, `Browse.Diff.get_version/get`, subsequent item-detail/list requests, and response bodies. Preserve ordering and paired cursor values in private analysis; commit only sanitized fixtures without cookies, SID, SynoToken, credentials, filenames, or real coordinates. If the web app does not call Diff, the HAR cannot settle its semantics: compare read-only Diff calls before/after those same user actions. Obtain explicit approval before performing any write endpoint probe; this plan authorizes none.

## Payload and persistence contract

Modify `LocationIndexPayload` in `Sources/PhotoCache/LocationIndex.swift` to store one current format containing `schemaVersion`, `[PhotoLocationRecord]`, and an optional `DiffCursor`. A cursor-bearing payload means the complete located subset is valid through that cursor. A cursorless payload is a successful conventional full scan, reusable during this run but requiring a full scan next run.

Remove `sourceTimelineFingerprint` as a freshness authority and remove `scannedItemCount` from durable delta bookkeeping: the located subset cannot distinguish addition of an unlocated item from modification of an existing unlocated item. Scan progress keeps a local count.

Increment the payload version and `CacheKey.locationIndex` version. Reject old/malformed payloads as misses, without conversion or legacy decode branches. This map-only JSON change does not require new SQLite columns or an account-schema bump. If implementation introduces incompatible SQLite shape, increment `DiskCache.schemaVersion` and extend `isCurrentSchema`; existing reset discards the account index and image files. Do not migrate either format or retain compatibility tests.

Encode records and cursor together and replace the single metadata row in one SQLite statement. Never persist a cursor in UserDefaults or a separately updated row. Extend the disk write boundary with a commit result, for example `CacheWriteResult.stored`, `.generationChanged`, and `.notRetained`, distinguishing stale-generation rejection from a result not retained after trimming. Storage failure must leave a coherent old/new row or a miss, never a new cursor with old records. Existing callers may discard the result explicitly.

A verified network result can remain usable in run-local memory after storage failure, with an aggregate diagnostic; restart retries from the last persisted payload. Keep the `.locationIndex` retention class in `CachePriorityPolicy.swift`. Cursor bytes count in the existing payload budget. No extra protected cache, change journal, per-photo database, or independent budget is needed.

## Interfaces and ownership

Add `Sources/SynologyAPI/DiffModels.swift` for `DiffCursor: Codable, Hashable, Sendable` and the proven response/change types. Decode cursor integers without floating-point conversion. Required arrays/fields must not default to empty; ignore unrelated unknown fields. Keep item IDs distinct from `ThumbnailInfo.unitID`. Validate malformed/duplicate/conflicting entries using the recorded protocol.

Extend the complete contract in `Sources/SynologyAPI/PhotosTransport.swift` and implement in `SynologyClient.swift`:

```swift
func diffVersion() async throws -> DiffCursor
func changes(since cursor: DiffCursor) async throws -> PhotoDiff
func locationItems(ids: [Int64]) async throws -> LocationItemLookup
```

`PhotoDiff` expresses a complete interval and returned cursor; `LocationItemLookup` distinguishes found items from explicitly confirmed absence if supported. Wire shapes and lookup parameters come from the evidence gate. Omit lookup if the proven feed supplies all required authoritative fields. Use `PhotosRequestFields.locationScanAdditional` (`gps`, `thumbnail`) and retain `PhotoItem.id/time`. Update test-only defaults in `Tests/PhotoCacheTests/PhotoCacheTestSupport.swift` and `Tests/SynoTimelineAppTests/SynoTimelineAppTestSupport.swift` to throw for unexpected new operations; add no production protocol defaults.

Add `Sources/PhotoCache/CachedPhotosRepository+Diff.swift` for gated transport helpers and `Sources/PhotoCache/LocationIndexDelta.swift` for a pure merge helper. Merge confirmed deletions and authoritative replacements by item ID. A found item without GPS removes its pin; a newly located item creates one. Replace time/thumbnail along with coordinates. Return unique records sorted by capture time descending, then ID ascending as a deterministic tie-breaker. Apply the same order to full scans because clustering depends on input order. Invalid coordinates follow `PhotoItem.coordinate` validation.

Extend actor-owned state in `RepositoryState.swift`, keeping `CachedPhotosRepository` the sole coordinator. Store one map validation job, run-local completed result, failure state, and job identity. Include Diff work in `hasDemand` so `cancelIdleLogin()` does not cancel needed authentication. No new actor, whole-cache observation, or global cursor is required.

## Validation algorithm

`locationIndex()` emits cached records before authentication or network admission, then joins one shared validation job. Memoize successful results for the repository run, including unpersisted results. Later opens do no network validation unless the user retries a failure or clears the cache.

### Cursor-bearing cached payload

1. Capture cache generation and job identity before the first suspended read. Join the existing verified Personal Library timeline for startup coordination; its count is a progress estimate, not location-freshness proof. Do not block cached paint on that join.
2. Call `changes(since: payload.cursor)` through the metadata gate. A complete empty item delta reuses records and atomically stores the returned cursor. Album-only changes do not affect Map once evidence supports domain separation.
3. For a bounded nonempty item delta, obtain authoritative metadata for every modified/added ID, including IDs absent from the old index. Resolve deletion/conflicts only according to proven semantics. Build a candidate copy; do not publish partial maps or mutate the last good payload.
4. After all lookups, call `changes(since: returnedCursor)` as a consistency fence. Commit only if the fence is complete and contains no item changes, using its returned cursor. If there are more changes, discard the candidate and attempt one full baseline below. Do not claim current metadata belongs to an earlier cursor or enter an unbounded catch-up loop.
5. Before publication and commit, recheck cancellation, generation, and job identity. Publish one complete replacement, preserving the camera. Persist records and cursor together.

An omitted lookup ID without authoritative absence semantics, truncated/ambiguous response, or over-limit delta cannot be partially applied; rebuild the baseline. On timeout, transport failure, or auth failure, retain cached pins and expose failure/retry. Do not turn transient feed failure into an automatic minutes-long scan.

### Full baseline and fallback

With usable Diff, obtain cursor A immediately before scanning. Use the existing 1,000-item walk and metadata gate, retaining located records plus a bounded set of scanned IDs for duplicate detection. Fetch a terminal short/empty page; reaching the cap on a full page fails. Call `changes(since: A)` after scanning. Attach its cursor only if the complete interval has no item changes. Any item change or duplicate indicates an unstable baseline: keep the old payload and report that the library changed during validation, with Retry. Do not rescan repeatedly.

A definitively unsupported feed, known rejected/reset cursor, or over-limit complete delta permits at most one full scan per validation attempt. A rejected cursor may establish a fresh A; unsupported/untrustworthy Diff cannot produce a cursor-bearing baseline. In that case, a successful scan is cursorless and follows the existing static-during-session assumption. If available stable-baseline verification fails, do not downgrade that failure to success by saving a cursorless candidate.

Without a usable cursor, do not reuse across runs merely because day counts/fingerprints match. This deliberately fixes the current map freshness gap at the cost of one scan per run on servers without adequate Diff coverage. Document and measure that fallback cost before enabling the slice. Remove the old fingerprint shortcut when shipping; do not retain it as a compatibility mode.

Full scans do not populate ordinary page-cache keys: positional responses lack `pageAdditional` and are not exact timeline sections. The verified Personal Library timeline remains the browser source for map-filter pages. External changes after run validation remain out of scope; unstable validation fails rather than live-updating an already open filtered collection/viewer.

## Bounds, lifecycle, mutations, and retry

- Route Diff and lookup calls through the existing two-slot metadata `NetworkGate`, at prefetch priority for Map. Acquire/release each request separately; never hold a slot while awaiting child requests needing slots. Preserve cached-read immediacy and visible browsing priority. At most two lookups run concurrently; cancel siblings on every exit.
- Define policy constants beside the Diff helpers: initially 2,000 unique changed IDs, 32 lookup requests, and batch size `min(100, provenServerLimit)`. These are client safety policies, not Synology limits. Reject oversized responses before constructing extra copies/sets. Bound received Diff bytes (initial policy: 4 MiB) in transport; `post` currently buffers responses, so checking only after decode is insufficient. Tune conservative constants from sanitized small/bulk import measurements before enablement.
- Retain only cached located records, one candidate, bounded delta state, and two scan pages. The duplicate-ID set is bounded by the existing scan cap; measure its peak large-library cost. Do not retain all scanned `PhotoItem` values or image bytes. Merge/sort once per candidate.
- Preserve the current location-job lifetime: leaving Map removes the subscriber but allows background completion; another window joins the same job. Clear-cache and repository teardown cancel work. Recheck identity/generation after awaits and before terminal events/writes so late work cannot repopulate disk or resurrect cleared pins.
- In `clearCache()`, invalidate job identity before awaiting disk clear; cancel validation and reset completed result, failure memo, and Diff state. Hold new validation admission until clear completes, and finish old streams without late success. Add `locationIndexResets() -> AsyncStream<Void>` with observer storage in `RepositoryMetadataWork`: finite location-load streams have already finished for some open windows and cannot deliver later reset events. `MapBrowserModel.start` installs one lifetime reset listener before loading; clear broadcasts to it so every model cancels its old subscription, discards pins/thumbnails, and becomes eligible for a fresh demand. Remove observers on termination and cancel the listener with model teardown. Do not represent clear as an empty successful map or automatically start a scan from the notification.
- Favorites writes can advance Diff. Never advance Map's cursor in `CachedPhotosRepository+Favorites.swift` or suppress IDs believed to be local writes: they may also have external GPS changes. Repair only coordinate/time/thumbnail fields. Preserve optimistic overrides, rollback, collection epochs, and authoritative Favorites refresh. A concurrent write may conservatively invalidate the fence.
- Memoize failure for implicit repeated demand. Add explicit `locationIndex(retry: true)` from `MapBrowserModel.retry()` to create one fresh map attempt. Sticky authentication still requires `retryAuthentication()`; unsupported capability stays memoized for the run and uses full-scan fallback on explicit retry. No timers, automatic login loops, or periodic rebuilds.

## UX and observability

Update `LocationIndexEvent`, `Sources/SynoTimelineApp/MapBrowserModel.swift`, and `MapBrowserView.swift` to distinguish validation, changed-record repair, and full rebuild. Keep cached pins usable while validating and retain them on failure with Retry. Cold failure is an error, not a successful empty map. Only a successful complete result may clear all pins.

Progress uses changed IDs resolved / changed IDs for delta work and scanned items / estimated timeline total for a full scan. Do not substitute located count for library size or mix progress units. No new shortcut is needed. Avoid reapplying identical records in `receive` just to update freshness: `apply` currently reclusters on every completion.

Record aggregate strategy, empty/nonempty delta, fallback reason (rejected/unsupported/oversized/unstable), request counts, scanned count, bytes, elapsed time, cancellation, and persistence failure. Do not log cursors, IDs, filenames, coordinates, tokens, or authenticated URLs. Distinguish network success from persistence success. Compare cached first paint and metadata-gate contention against the baseline; visible scrolling must remain responsive.

## Deferred metadata request suppression

Do not implement timeline/page/album shortcuts with the map slice. Before that next slice, prove favorite changes, normal/condition album membership, covers, counts, ordering, deletion, and permission changes. Empty album changes alone do not prove unchanged album contents after item edits.

The next implementation plan must define resource-specific durable proof, written atomically with each exact resource in `DiskCache`, and a coherent baseline protocol for `registerTimeline`, `registerPage`, and `registerAlbumList`. A global cursor is insufficient; `markValidated` alone establishes no proof. Eviction loses proof, absent proof falls back to network, and a cursor obtained this launch cannot be attached to bytes fetched on an earlier launch.

Start with empty-complete-delta reuse only. Any relevant nonempty delta conservatively revalidates collection resources through existing paths; no cached-ID intersection. Targeted page preservation would require complete old/new dates, membership, sort dependencies, split-day offset effects, and deletion locations, including never-cached items. That index does not exist today. Bound distinct cursor validations and coalesce only identical pairs; do not issue one unbounded feed request per cached page.

Preserve `validationRun(for:)`, mutation epochs, clear generations, cached-first `ResourceEvent`, `allowNetwork: false`, bounded `LibraryPageWindow`, selection invalidation on ordered-ID changes, viewer metadata verification before image downloads, and Favorites frozen-playlist semantics. Session map filters derive from validated personal pages and get no persistent proof. Image HTTP validation stays separate. This slice needs its own concrete storage/concurrency design review; do not implement speculative shortcuts from this section.

## Implementation sequence

1. **Evidence only.** Complete map protocol observations, redact fixtures, and document supported API/version and lookup shape in `docs/SYNOLOGY_PHOTOS_API.md`. If coverage/consistency remains uncertain, stop before production integration and name the missing interaction/capture. Do not compensate with guessed parsing or cursor expiration.
2. **Transport and pure repair.** Add models, explicit transport operations, bounded receive handling, and merge helper. Add `Tests/SynologyAPITests/DiffModelsTests.swift` and `Tests/PhotoCacheTests/LocationIndexDeltaTests.swift`. Use wire fixtures and deterministic pure inputs without NAS access.
3. **Persistence and baseline.** Change payload/key, disk commit result, repository state/reset, and full-scan fence. Extend `Tests/PhotoCacheTests/LocationIndexTests.swift` and `Tests/PhotoCacheTests/PhotoCacheTests.swift`. Replace tests blessing equal fingerprints with cursor-backed tests. Retain current-format corruption/reset tests, not tests solely for obsolete formats.
4. **Delta path and UX.** Integrate bounded lookup, coalescing, cancellation, retry, progress, and diagnostics. Add `Tests/SynoTimelineAppTests/MapBrowserModelTests.swift` for retained pins, statuses, reset, retry, empty success, and identical-record completion. Preserve map clustering and filtered browsing.
5. **Enable and document.** Run `swift test` and `swift build`, then `bash scripts/run.sh` for UI checks. Compare two unchanged launches, one small user-performed import, GPS-only edit, large delta, offline launch, and clear during validation. Server writes need approval. Update root `AGENTS.md`, `docs/ARCHITECTURE.md`, and the status/limitations in `docs/plans/WIP_CACHING_PLAN.md` only when implemented. Record fallback cost and tuned constants. Remove temporary diagnostic enablement switches before completion; retain runtime unsupported/error handling, not a second legacy implementation.

## Required validation

Use barrier-controlled fake transports rather than sleeps for races.

- Empty delta reuses cached pins with one feed request and no lookup/scan; album-only changes are equivalent only with evidence. Same-run reopen performs no network.
- Add uncached located/unlocated IDs, GPS gain/loss, time/thumbnail replacement, delete unknown IDs, repeated entries, conflicting modify/delete. Missing lookup responses never become implicit deletions.
- Equal counts with GPS edits and same-day replacement cannot authorize reuse. Changed split-day membership never marks timeline pages verified.
- Change during repair permits one baseline attempt; change during scan fails without overwriting the old payload. Duplicate positional pages and cap termination cannot persist partial data.
- Rejected/malformed/unsupported/oversized responses, missing cursor, and server reset follow explicit failure/fallback paths. Timeout/auth failure do not create scan storms. Retry and sticky login failure are independently asserted.
- Clear at disk read, admission, lookup completion, fence completion, and commit rejects late writes/success. Two subscribers share a job; one leaving does not cancel the other or background completion.
- Favorites success, partial failure, and rollback during validation cannot manually advance cursors or corrupt overrides. Existing selection/viewer/album/map-filter/image suites pass.
- Disk write failure, immediate trimming, corruption, account separation, and interrupted commit leave a coherent payload or a miss. Displayed but unpersisted results are revalidated next run.
- Cold empty library succeeds; cold failure is not empty success; cached offline pins remain; recovery preserves camera. No whole-library image downloads occur.

Acceptance: after a trusted baseline, an unchanged run adds one small Diff request on first Map demand; a small delta adds bounded lookups and a consistency fence instead of a positional walk. Existing eager timeline requests and image validation remain. No result is verified because its day counts match, and no advanced cursor survives without its corresponding complete payload.
