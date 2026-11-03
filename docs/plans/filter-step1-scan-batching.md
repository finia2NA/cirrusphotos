# Step 1: Batched filter scan and cache-only filter availability

Goal: make "results from everywhere" in the session metadata filter take a few dozen network requests instead of ~1,000, and make the filter usable from cached data before the server is reachable. No storage/schema changes in this step (GRDB and the facets table are later steps).

Read `docs/PROJECT.md` and `docs/ARCHITECTURE.md` (the "Metadata filtering" paragraph) first. Follow `AGENTS.md`/`CLAUDE.md` rules. Do not commit.

## Background (current behavior, verified in source)

- `LibraryFilterController.scan()` (`Sources/PhotoCache/LibraryFilterController.swift`, ~line 366) takes `pending.prefix(2)`, awaits a cached read and then an uncached read, then takes the next 2. `refillContinuousScan()` keeps at most 8 sections queued+active.
- Each section read calls `repository.page(...)`. Network page loads go through `loadMetadataPage` → `flushMetadataPages` → `MetadataReadPlanner.plan` (`Sources/PhotoCache/CachedPhotosRepository+MetadataPages.swift`). The planner merges up to 1,000 items / 32 days per request, but only merges demands that are pending at flush time. With 2 sections in flight, each request covers ~2 days.
- `TimelineSectionCacheLoader` (the "Load All Timeline Sections" warmer, `Sources/PhotoCache/TimelineSectionCacheLoader.swift`) already does this correctly: groups of 64 (`pending.prefix(64)`), wrapped in `repository.beginMetadataPageDemandBatch(sections, collection:)` / `endMetadataPageDemandBatch(id)`. Announced demands hold the flush (`scheduleMetadataPageFlush`) until every announced page has registered, so the planner can build full batches. Use its `read(_:)` (~line 179) as the reference pattern.
- `receiveScanEmission` publishes after every page emission; each publish rebuilds the registration over all records (`makeRegistration`) and the app re-installs it on the main actor (`LibraryFilterModel.install` → `repository.replaceLibraryFilterSnapshot` → `LibraryModel.registerSessionCollection`).
- `discoverCachedPages()` reads cached pages in batches of `cacheReadBatchSize = 16` and publishes after each batch.
- `LibraryFilterModel.configure(library:source:)` (`Sources/SynoTimelineApp/LibraryFilterModel.swift`) creates the controller only when `library.timelineVerified(for: source)` is true, so the filter is unavailable (button disabled via `isReady`) until the source timeline has been validated by the server. When the snapshot fingerprint changes, `configure` calls `clear()`, which discards the user's committed filter.
- `AppShellView` already calls `libraryFilter.configure(...)` on `sourceCollection`, `sourceSnapshotRevision` and `sourceTimelineVerified` changes (~lines 184–192).

## Changes

### A. Batch the continuous filter scan (`LibraryFilterController.swift`)

1. Add constants next to `cacheReadBatchSize`:
   - `private static let scanGroupSize = 64` (matches `TimelineSectionCacheLoader` and the 64-page cap in `beginMetadataPageDemandBatch`).
   - `private static let demandLimit = 8` (keep the current user-scroll bound; replaces the literal `8` in `demandVisibleResultSections` and `loadInitialBatch`).
2. `refillContinuousScan()`: change capacity from `8 - pending.count - activeIndices.count` to `Self.scanGroupSize - pending.count - activeIndices.count`.
3. `scan()`: replace `pending.prefix(2)` with `pending.prefix(Self.scanGroupSize)`. Read the whole group in **one** call, so cached-policy and uncached-policy reads are announced and in flight together (no sequential `await` of the cached then uncached subsets).
4. Change `read(indices:useCachedPages:allowNetwork:)` to take `[QueuedRead]` (each read carries its own `useCachedPages`), like the warmer. When `allowNetwork` is true, wrap the task group in:
   ```swift
   let batch = await repository.beginMetadataPageDemandBatch(reads.map { sourceSnapshot.sections[$0.index] }, collection: sourceCollection)
   ... task group ...
   await repository.endMetadataPageDemandBatch(batch)
   ```
   Do not announce demand for cache-only reads (`allowNetwork: false`), since those never register network demand, and an announced demand that never registers would hold the flush until `endMetadataPageDemandBatch`. Note that `page()` already calls `finishExpectedMetadataDemand` in its `defer`, so cached-and-verified pages release their announcement.
   Update `discoverCachedPages` and `receiveCachedPages` callers to build `QueuedRead`s with `useCachedPages: true`.
5. User-scroll demand priority: in `enqueue`, when called from `demandVisibleResultSections`, insert the new reads at the **front** of `pending` (preserving their order) instead of appending, so a visible demand is in the next group. Add a parameter `front: Bool = false` to `enqueue`; only `demandVisibleResultSections` passes `true`. `loadInitialBatch` and `refillContinuousScan` append.
6. Coalesce publishes during the scan:
   - In `receiveScanEmission`, call `replace(...)` but do **not** call `publish()`; instead set a `private var scanDirty = false` flag to true when `replace` returns true.
   - In `scan()`, after a group's results are applied (the existing per-result loop), call `publish()` once if anything changed in that group (from `scanDirty` or the loop's `changed`), then reset `scanDirty`. Keep the existing failure-state handling per result.
   - Rationale: one registration rebuild + one main-actor install per 64-day group instead of per page.
7. Raise `cacheReadBatchSize` from 16 to 64 (fewer rebuild/publish rounds during cached discovery; reads remain serialized by the store actor).

Failure semantics change (accept, document): pages merged into one network request now fail together if that request fails, matching the warmer. Failed sections remain retryable via `retryFailed()`.

### B. Network permission inside the controller

1. Add `private var networkAllowed: Bool` to `LibraryFilterController`, initialized from a new init parameter `networkAllowed: Bool = true` (default keeps existing tests valid).
2. Add `public func setNetworkAllowed(_ allowed: Bool)`. When it changes from false to true: if `continuousScan` is true call `refillContinuousScan()`; otherwise if `pending` is non-empty call `startSchedulerIfNeeded()`.
3. `enqueue(...)`: still record pending reads, but `startSchedulerIfNeeded()` must not start the network scan while `!networkAllowed` (guard in `startSchedulerIfNeeded`: `guard networkAllowed, scheduler == nil, !pending.isEmpty`). Cached discovery (`discoverCachedPages`, `receiveCachedPages`) is unaffected; it never uses the network.
4. `makeProgress`: no new fields required. `state` should stay `.idle` when the scan is waiting for network.

### C. Make the filter available from the cached timeline (`LibraryFilterModel.swift`)

1. In `configure(library:source:)`, remove `library.timelineVerified(for: source)` from the guard; require only `source`, `library.snapshot(for: source)` and `library.repository`.
2. Compute `let verified = library.timelineVerified(for: source)`. Before the fingerprint early return (`guard fingerprint != next || metadataRevision != ... else { return }`), forward the current value: `if let controller { Task { await controller.setNetworkAllowed(verified) } }`. Track the last forwarded value in a `private var networkAllowed: Bool?` to avoid redundant tasks.
3. When creating a new controller pass `networkAllowed: verified`.
4. Preserve the user's filter across a same-source snapshot rebuild (cached snapshot → verified snapshot with a different fingerprint is now the common path):
   - Split `clear()` into: `private func detachActiveFilter()` (unregisters the active collection from repository and `LibraryModel`, resets `activeCollection`, `installedRegistration`, `installingRegistration`, `lastEdgeDemand`, `applyToken`, `needsInitialBatch`, and calls `unregisterFilter()` on the current controller) and the public `clear()` which calls `detachActiveFilter()` and then resets `committed`, `draft`, all text fields, units and `validationErrors`.
   - In the fingerprint-rebuild branch (source unchanged, metadata revision unchanged), call `detachActiveFilter()` instead of `clear()`. After creating and observing the new controller, if `committed` is not empty, re-run the apply flow with `committed` (factor the `Task { controller.apply ... install ... receive ... }` body out of `apply()` into `private func start(_ filter: LibraryFilter, on controller: LibraryFilterController)` and call it from both places).
   - Source changes and metadata resets keep today's full `clear()`.
5. `LibraryFilterView` needs no change: `isReady` becomes true once a cached snapshot exists. Leave the "(metadata loading)" help text for the no-snapshot case.

### D. Docs

- `docs/ARCHITECTURE.md`, metadata filtering paragraph: replace "One gesture generation admits at most eight new source sections…" / "the queue performs at most two cached-first page reads concurrently" wording with: user-scroll demands admit at most eight sections at the front of the queue; the continuous scan announces groups of up to 64 sections to the metadata read planner (like the timeline warmer) so network reads merge into full batches; publications are coalesced per group; the controller indexes the cached source timeline before validation and starts network scanning only once the source timeline is verified.
- `docs/PROJECT.md`, Library/Favorites/albums filter bullet: state the filter is available from a cached collection before the server connects; background expansion starts once the collection is validated.

## Tests (`Tests/PhotoCacheTests/LibraryFilterControllerTests.swift`)

Run with `swift test --filter LibraryFilterControllerTests` and then the full `swift test`. Build with `swift build`.

- `testClearingFilterStopsContinuousScheduling`: currently asserts exactly 2 requests. With batching the first group of 12 sections may merge into one or two requests. Update to assert that the request count after `unregisterFilter()` plus the sleep equals the count observed right after the stop (no further requests), not a literal 2.
- `testContinuousScanPassesBatchBoundaryAndSkipsFailures`: persistent failure of offset 0 now fails the whole merged batch. Rework the fixture so the test still proves (a) the scan passes the old 8-section boundary and (b) failures don't stall the scan: e.g. use more sections than one 32-day batch (≥ 40) with the failure in the first batch, and assert `verified > 8`, `failed >= 1`, `verified + failed == total`, and `maximumConcurrentReads() <= 2` (physical slots unchanged). Keep the `callCount(offset: 0) == 1` assertion only if it still holds (no automatic retry).
- New `testContinuousScanMergesDaysIntoFewRequests`: 40 one-item sections, no failures; after the scan completes assert `transport.requestCount()` is well below 40 (e.g. `<= 4`).
- New `testNetworkScanWaitsForNetworkPermission`: create the controller with `networkAllowed: false`, `apply`, `indexCachedPages()`, `startContinuousScan()`, sleep briefly, assert `requestCount() == 0`; then `setNetworkAllowed(true)` and wait until progress shows all sections verified.
- `testDirectionalDemandIsBoundedAndUsesVisibleSourceAnchor` must keep passing unchanged (demand bound stays 8).
- Check `ScannerTransport` in the test support for how it counts requests vs. sections; if `requestCount()` counts batch requests, the above works as written; if it counts per section, add a batch-request counter.

The app-side change (C) has no existing unit tests; no new UI tests are required. Verify it compiles and reason through: cached snapshot → controller created with `networkAllowed: false` → verified snapshot, same fingerprint → `setNetworkAllowed(true)`; different fingerprint → new controller, committed filter re-applied.

## Done when

- `swift build` and `swift test` pass (report any pre-existing failures separately, with output).
- Docs updated as above.
- A short summary lists changed files and any deviations from this plan with reasons.
