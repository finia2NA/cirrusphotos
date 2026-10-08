# Diff-based cache validation

Status: implementation plan, not implemented. Reviewed against the code on 2026-10-08. The available evidence is sufficient to implement the guarded map delta path under the explicit GPS-coverage assumption below. This document changes no current application behavior.

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

## Protocol evidence and accepted assumption

The 2026-10-06 and 2026-10-08 probes establish that `SYNO.Foto.Browse.Diff` is advertised at versions 1–7, `get_version` v1 returns the opaque pair `diff_version`/`version_time`, and `get` returns a deterministic complete-looking interval for an observed two-day-old cursor. That interval contained 67 unique `item.modify` base records and advanced to the current cursor; repeating it returned the same records, and querying the returned cursor was empty. Diff supplied no GPS or thumbnail fields. A v7 item lookup returned all 67 current rows in exact order, and a subsequent quiet-window Diff fence was empty. A mixed lookup silently omitted a nonexistent ID, so lookup omission is not authoritative deletion evidence.

A later controlled sequence proved that an upload appears as one base record in `item.modify` and a deletion appears as one bare integer ID in `item.delete`. The deleted ID was omitted from lookup, while unrelated concurrent modifications remained in both intervals. Each returned cursor produced an empty fence. Full sanitized conclusions and shapes are recorded in `docs/SYNOLOGY_PHOTOS_API.md`.

A controlled external overwrite then added EXIF GPS to an existing disposable PNG. Synology retained the same item ID, returned that ID once under `item.modify` with no deletion, and exposed the new coordinates through authoritative lookup. The overwrite also changed capture time and thumbnail cache key while retaining thumbnail unit ID, so it proves the combined GPS/time/thumbnail-revision reindex path but not an isolated GPS-only edit. An unrelated modification shared the interval, and the returned cursor fenced empty.

Missing cursor fields returned 120; a deliberately mismatched pair and `(0, 0)` returned 700. Error 700 is not yet proven to mean expiry/reset of a once-valid cursor. Preserve both cursor fields exactly as issued; do not derive cursors from dates or order them numerically. The observed interval does not identify which user action created each modify record, so it does not yet prove addition versus metadata-edit coverage.

The vendored `docs/SynologyPhotosAPI/API/SYNO.Foto.lib` advertises Diff but supplies no change semantics. `docs/SynologyPhotosAPI/API/SYNO.Foto/SYNO.Foto.Browse.Item.list.md` describes pagination and optional GPS fields, but establishes no arbitrary-ID batch lookup contract. Do not invent `item_ids`, `getinfo`, continuation fields, or tombstone shapes.

The implementation must encode the observed evidence and explicit policies below; later probes refine them without silently changing the safety behavior:

| Evidence or accepted policy | Implementation consequence |
| --- | --- |
| Actual addition, modification, deletion entries; item ID versus thumbnail unit ID; overlapping modify/delete entries; repeated changes | Define strict decoding and unambiguous final-state normalization. Never assume delete wins without evidence. |
| GPS added/changed/removed, capture time changed, and thumbnail regeneration/replacement | Assume these appear under `item.modify`; always perform authoritative lookup for modified IDs. Document the residual false-empty risk and provide metadata-only invalidation as recovery. |
| Complete interval from an older pair to the returned pair; truncation, continuation, reset, overflow, and large-import behavior | Partial change lists cannot authorize commits. Implement actual bounded pagination only if observed; reject ambiguous/over-limit responses. |
| Read-only lookup of specified item IDs, fields, batch limit, missing/deleted/inaccessible IDs, order, and GPS-absence semantics | Repair needs authoritative metadata or complete feed records. A missing response is not automatically a deletion. |
| A second Diff call after metadata reads detects changes during those reads; indexing delay between item reads and feed visibility | Establish the consistency fence below. If visibility lags without a reliable fence, leave the optimization disabled. |
| Rejection/reset of a previously valid cursor and account isolation | Classify known rejection separately from auth, malformed requests, unsupported API, and transient failure. Unknown errors never become empty deltas. |

Current evidence: addition, deletion, combined GPS gain/capture-time/thumbnail revision, nonempty modify decoding, deterministic replay, an accepted two-day-old cursor, ordered repair lookup, missing-ID ambiguity, bare-integer tombstones, unrelated concurrent entries, and empty consistency fences are observed. An isolated GPS-only change or removal could not be exercised because Synology Photos exposes GPS only as read metadata; its current frontend has no GPS editor and `Browse.Item.set` rejects a `gps` value.

Proceed with the explicit product assumption that a GPS-only edit or reindex appears under `item.modify`, like other item changes. This is an accepted residual freshness risk, not a proven protocol fact. The delta path must look up every modified ID with `gps` and `thumbnail`; it must never infer that the base Diff record itself contains current location data. If the assumption is false, an empty Diff interval can leave a pin stale. The metadata-only invalidation command specified below is the recovery path: it removes the location payload and cursor so the next Map demand performs a fenced full scan, while preserving expensive image bytes.

Repeat/conflict behavior, large-interval completeness, and expiry/reset of a previously valid cursor remain useful follow-up evidence but do not block the guarded first slice. Handle uncertainty conservatively: a duplicate or modify/delete overlap, malformed/unknown shape, oversized interval, missing required cursor, lookup omission without a matching tombstone, or error 700 falls back to one fenced full scan instead of applying a partial delta. Do not classify error 700 as expiry in diagnostics until a previously valid pair is observed failing.

Cursor retention duration is an operational measurement, not a guessed TTL. Safe rejection handling permits implementation without knowing the maximum age. Shared Space and condition-album semantics are not prerequisites for the map slice.

A HAR would still help for capture-time changes and a bulk import: capture the Synology Photos web app in Personal Space from initial load through each action and refresh, including `SYNO.API.Info`, `Browse.Diff.get_version/get`, subsequent item-detail/list requests, and response bodies. Synology Photos 1.9.1-10928 has no GPS editor and rejects `Browse.Item.set` with a `gps` value. To test the accepted GPS assumption later, externally edit EXIF on one disposable JPEG through its underlying file path, allow Synology to reindex it, and compare read-only Diff and item lookups before and after each edit; do not overwrite a non-disposable original. Preserve ordering and paired cursor values in private analysis; commit only sanitized fixtures without cookies, SID, SynoToken, credentials, filenames, or real coordinates. If the web app does not call Diff, the HAR cannot settle its semantics: compare read-only Diff calls around the same actions. Obtain explicit approval before performing any write endpoint probe; this plan authorizes none.

## Payload and persistence contract

Modify `LocationIndexPayload` in `Sources/PhotoCache/LocationIndex.swift` to store one current format containing `schemaVersion`, `[PhotoLocationRecord]`, and an optional `DiffCursor`. A cursor-bearing payload means the complete located subset is valid through that cursor. A cursorless payload is a successful conventional full scan, reusable during this run but requiring a full scan next run.

Remove `sourceTimelineFingerprint` as a freshness authority and remove `scannedItemCount` from durable delta bookkeeping: the located subset cannot distinguish addition of an unlocated item from modification of an existing unlocated item. Scan progress keeps a local count.

Increment the payload version and `CacheKey.locationIndex` version. Reject old/malformed payloads as misses, without conversion or legacy decode branches. This map-only JSON change does not require new SQLite columns or an account-schema bump. If implementation introduces incompatible SQLite shape, increment `DiskCache.schemaVersion` and extend `isCurrentSchema`; existing reset discards the account index and image files. Do not migrate either format or retain compatibility tests.

Encode records and cursor together and replace the single metadata row in one SQLite statement. Never persist a cursor in UserDefaults or a separately updated row. Extend the disk write boundary with a commit result, for example `CacheWriteResult.stored`, `.generationChanged`, and `.notRetained`, distinguishing stale-generation rejection from a result not retained after trimming. Storage failure must leave a coherent old/new row or a miss, never a new cursor with old records. Existing callers may discard the result explicitly.

Add a metadata generation beside the existing whole-cache generation in `Sources/PhotoCache/DiskCache.swift`. Metadata reads may use cached bytes immediately, but every network-backed write of `.timeline`, `.page`, `.albumList`, or `.locationIndex` captures and rechecks `currentMetadataGeneration()`. Full `clear()` advances both generations. The new `clearMetadata()` advances only the metadata generation and deletes those four kinds in one SQLite transaction. It must not delete or rewrite `.thumbnail`, `.previewThumbnail`, or `.fullImage` rows/files, clear image validators, reclassify thumbnail families, or reject image writes that captured the unchanged whole-cache generation. Do not reuse the whole-cache generation for this command merely because it is simpler; doing so would discard in-flight expensive downloads.

A verified network result can remain usable in run-local memory after storage failure, with an aggregate diagnostic; restart retries from the last persisted payload. Keep the `.locationIndex` retention class in `CachePriorityPolicy.swift`. Cursor bytes count in the existing payload budget. No extra protected cache, change journal, per-photo database, or independent budget is needed.

## Interfaces and ownership

Add `Sources/SynologyAPI/DiffModels.swift` for `DiffCursor: Codable, Hashable, Sendable` and the proven response/change types. Decode cursor integers without floating-point conversion. Required arrays/fields must not default to empty; ignore unrelated unknown fields. Keep item IDs distinct from `ThumbnailInfo.unitID`. Validate malformed/duplicate/conflicting entries using the recorded protocol.

Extend the complete contract in `Sources/SynologyAPI/PhotosTransport.swift` and implement in `SynologyClient.swift`:

```swift
func diffVersion() async throws -> DiffCursor
func changes(since cursor: DiffCursor) async throws -> PhotoDiff
func locationItems(ids: [Int64]) async throws -> LocationItemLookup
```

`PhotoDiff` expresses a complete interval and returned cursor; `LocationItemLookup` distinguishes found items from explicitly confirmed absence if supported. Wire shapes and lookup parameters come only from the recorded evidence. The observed feed does not supply GPS or thumbnail fields, so the implementation must retain lookup. Use `PhotosRequestFields.locationScanAdditional` (`gps`, `thumbnail`) and retain `PhotoItem.id/time`. Update test-only defaults in `Tests/PhotoCacheTests/PhotoCacheTestSupport.swift` and `Tests/SynoTimelineAppTests/SynoTimelineAppTestSupport.swift` to throw for unexpected new operations; add no production protocol defaults.

Add `Sources/PhotoCache/CachedPhotosRepository+Diff.swift` for gated transport helpers and `Sources/PhotoCache/LocationIndexDelta.swift` for a pure merge helper. Merge confirmed deletions and authoritative replacements by item ID. A found item without GPS removes its pin; a newly located item creates one. Replace time/thumbnail along with coordinates. Return unique records sorted by capture time descending, then ID ascending as a deterministic tie-breaker. Apply the same order to full scans because clustering depends on input order. Invalid coordinates follow `PhotoItem.coordinate` validation.

Extend actor-owned state in `RepositoryState.swift`, keeping `CachedPhotosRepository` the sole coordinator. Store one map validation job, run-local completed result, failure state, and job identity. Include Diff work in `hasDemand` so `cancelIdleLogin()` does not cancel needed authentication. No new actor, whole-cache observation, or global cursor is required.

## Validation algorithm

`locationIndex()` emits cached records before authentication or network admission, then joins one shared validation job. Memoize successful results for the repository run, including unpersisted results. Later opens do no network validation unless the user retries a failure or clears the cache.

### Cursor-bearing cached payload

1. Capture metadata generation and job identity before the first suspended read. Join the existing verified Personal Library timeline for startup coordination; its count is a progress estimate, not location-freshness proof. Do not block cached paint on that join.
2. Call `changes(since: payload.cursor)` through the metadata gate. A complete empty item delta reuses records and atomically stores the returned cursor. Album-only changes do not affect Map once evidence supports domain separation.
3. For a bounded nonempty item delta, obtain authoritative metadata for every modified/added ID, including IDs absent from the old index. Resolve deletion/conflicts only according to proven semantics. Build a candidate copy; do not publish partial maps or mutate the last good payload.
4. After all lookups, call `changes(since: returnedCursor)` as a consistency fence. Commit only if the fence is complete and contains no item changes, using its returned cursor. If there are more changes, discard the candidate and attempt one full baseline below. Do not claim current metadata belongs to an earlier cursor or enter an unbounded catch-up loop.
5. Before publication and commit, recheck cancellation, metadata generation, and job identity. Publish one complete replacement, preserving the camera. Persist records and cursor together.

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
- Add `CachedPhotosRepository.clearMetadataCache()` as a separate operation. Before `DiskCache.clearMetadata()`, invalidate metadata job identities/epochs and cancel timeline, page, album-list, and location work. Only after the disk transaction succeeds, clear `latestTimelines`, `albumListLatest`, page promotions, map-filter pages/order, completed location result/failure, and cursor-bearing in-memory payloads; preserve authentication, favorite mutation state/overrides, thumbnail/full-image work, all image cache rows, saved destinations, and scroll anchors. Active session map-filter descriptors are derived from invalidated pages and IDs, so unregister them and return their browsers to Map rather than serving stale membership. Publish one `metadataCacheResets() -> AsyncStream<Void>` event after the disk transaction succeeds. `LibraryModel` owns one lifetime listener, clears published snapshots/verifications/errors and loaded album snapshots, then restarts normal demand for the active destination. `MapBrowserModel` responds through the same reset flow by clearing pins and camera-derived filter state; it does not start work unless Map remains active. A failed disk transaction retains the old published state and surfaces an error instead of pretending invalidation succeeded.
- Favorites writes can advance Diff. Never advance Map's cursor in `CachedPhotosRepository+Favorites.swift` or suppress IDs believed to be local writes: they may also have external GPS changes. Repair only coordinate/time/thumbnail fields. Preserve optimistic overrides, rollback, collection epochs, and authoritative Favorites refresh. A concurrent write may conservatively invalidate the fence.
- Memoize failure for implicit repeated demand. Add explicit `locationIndex(retry: true)` from `MapBrowserModel.retry()` to create one fresh map attempt. Sticky authentication still requires `retryAuthentication()`; unsupported capability stays memoized for the run and uses full-scan fallback on explicit retry. No timers, automatic login loops, or periodic rebuilds.

## UX and observability

Update `LocationIndexEvent`, `Sources/SynoTimelineApp/MapBrowserModel.swift`, and `MapBrowserView.swift` to distinguish validation, changed-record repair, and full rebuild. Keep cached pins usable while validating and retain them on failure with Retry. Cold failure is an error, not a successful empty map. Only a successful complete result may clear all pins.

In `Sources/SynoTimelineApp/CacheSettingsView.swift`, add a `Button("Clear Metadata Cache")` beside the existing whole-cache action. Its help text must say that it removes timelines, loaded sections/item pages, album metadata, and the map index while keeping thumbnails, viewer previews, and originals. Wire it through `LibraryModel.clearMetadataCache()` to the repository operation above; refresh usage afterward, but do not call `DecodedImages.shared.clear()`. Disable both cache buttons while either clear is running and show an inline failure state. Keep `Button("Clear Cache")` as the explicit all-data action. The metadata button needs no destructive NAS confirmation because it removes only reproducible local data, but its label and help must make the preserved image behavior discoverable.

Progress uses changed IDs resolved / changed IDs for delta work and scanned items / estimated timeline total for a full scan. Do not substitute located count for library size or mix progress units. No new shortcut is needed. Avoid reapplying identical records in `receive` just to update freshness: `apply` currently reclusters on every completion.

Record aggregate strategy, empty/nonempty delta, fallback reason (rejected/unsupported/oversized/unstable), request counts, scanned count, bytes, elapsed time, cancellation, and persistence failure. Do not log cursors, IDs, filenames, coordinates, tokens, or authenticated URLs. Distinguish network success from persistence success. Compare cached first paint and metadata-gate contention against the baseline; visible scrolling must remain responsive.

## Deferred metadata request suppression

Do not implement timeline/page/album shortcuts with the map slice. Before that next slice, prove favorite changes, normal/condition album membership, covers, counts, ordering, deletion, and permission changes. Empty album changes alone do not prove unchanged album contents after item edits.

The next implementation plan must define resource-specific durable proof, written atomically with each exact resource in `DiskCache`, and a coherent baseline protocol for `registerTimeline`, `registerPage`, and `registerAlbumList`. A global cursor is insufficient; `markValidated` alone establishes no proof. Eviction loses proof, absent proof falls back to network, and a cursor obtained this launch cannot be attached to bytes fetched on an earlier launch.

Start with empty-complete-delta reuse only. Any relevant nonempty delta conservatively revalidates collection resources through existing paths; no cached-ID intersection. Targeted page preservation would require complete old/new dates, membership, sort dependencies, split-day offset effects, and deletion locations, including never-cached items. That index does not exist today. Bound distinct cursor validations and coalesce only identical pairs; do not issue one unbounded feed request per cached page.

Preserve `validationRun(for:)`, mutation epochs, clear generations, cached-first `ResourceEvent`, `allowNetwork: false`, bounded `LibraryPageWindow`, selection invalidation on ordered-ID changes, viewer metadata verification before image downloads, and Favorites frozen-playlist semantics. Session map filters derive from validated personal pages and get no persistent proof. Image HTTP validation stays separate. This slice needs its own concrete storage/concurrency design review; do not implement speculative shortcuts from this section.

## Implementation sequence

1. **Evidence and assumptions.** Retain the sanitized observations in `docs/SYNOLOGY_PHOTOS_API.md` and encode only the observed v1 Diff/base-record, bare-delete-ID, and v7 lookup shapes. Treat GPS coverage as the explicit assumption above, not as fixture-backed behavior. Do not guess cursor expiration, continuation, or unobserved fields; conservative fallback handles them.
2. **Transport and pure repair.** Add models, explicit transport operations, bounded receive handling, and merge helper. Add `Tests/SynologyAPITests/DiffModelsTests.swift` and `Tests/PhotoCacheTests/LocationIndexDeltaTests.swift`. Use wire fixtures and deterministic pure inputs without NAS access.
3. **Persistence, invalidation, and baseline.** Change payload/key, disk commit result, scoped whole-cache/metadata generations, repository reset streams, Settings command, and full-scan fence. Extend `Tests/PhotoCacheTests/LocationIndexTests.swift`, `Tests/PhotoCacheTests/PhotoCacheTests.swift`, and `Tests/SynoTimelineAppTests` Settings/model coverage. Replace tests blessing equal fingerprints with cursor-backed tests. Retain current-format corruption/reset tests, not tests solely for obsolete formats.
4. **Delta path and UX.** Integrate bounded lookup, coalescing, cancellation, retry, progress, and diagnostics. Add `Tests/SynoTimelineAppTests/MapBrowserModelTests.swift` for retained pins, statuses, reset, retry, empty success, and identical-record completion. Preserve map clustering and filtered browsing.
5. **Enable and document.** Run `swift test` and `swift build`, then `bash scripts/run.sh` for UI checks. Compare two unchanged launches, one small user-performed import, a large-delta fixture, offline launch, full clear during validation, and metadata-only invalidation while images are cached and downloading. A later externally performed GPS-only edit can validate the accepted assumption but is not an enablement gate. Server writes need approval. Update root `AGENTS.md`, `docs/ARCHITECTURE.md`, and the status/limitations in `docs/plans/WIP_CACHING_PLAN.md` only when implemented. Record fallback cost and tuned constants. Remove temporary diagnostic enablement switches before completion; retain runtime unsupported/error handling, not a second legacy implementation.

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
- Metadata-only invalidation removes timeline, page, album-list, and location-index rows, rejects late metadata writes, resets active metadata models/map filters, and causes the next relevant demand to fetch a new baseline. Thumbnail, preview, and original rows/files remain byte-identical and immediately reusable; in-flight image writes still commit because their whole-cache generation is unchanged. Full clear continues to remove both metadata and images.

Acceptance: after a trusted baseline, an unchanged run adds one small Diff request on first Map demand; a small delta adds bounded lookups and a consistency fence instead of a positional walk. Existing eager timeline requests and image validation remain. No result is verified because its day counts match, and no advanced cursor survives without its corresponding complete payload. If the accepted GPS assumption proves false in practice, Clear Metadata Cache provides a user-visible way to force a fenced full map rebuild without paying to redownload image data.
