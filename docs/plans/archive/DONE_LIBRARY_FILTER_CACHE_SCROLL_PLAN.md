# Cached and Bidirectional Personal Library Filtering

Status: Completed on 2026-10-09.

## Goal

Make the Personal Library filter operate over every current-timeline item page already present in the metadata cache, regardless of where that page sits in the timeline. As the user browses filtered results, demand nearby Personal Library source pages in both the newer and older directions, using the same cached-first repository path and bounded page-window principles as the unfiltered browser.

This corrects the current mismatch where the camera/lens/extension catalog is built from every observed source page, but the result snapshot is built only from the contiguous loaded prefix beginning at the newest section. A value such as `DSC-HX60` can therefore be offered even though its already-known source section is excluded from the result collection.

## Intended behavior

- Once the validated Personal Library timeline is available, inspect all of its section keys for cached item pages. Do not enumerate arbitrary or obsolete SQLite rows: only pages addressable through the current `TimelineSnapshot` are eligible.
- Cache discovery is read-only and must never start authentication or network work. A cache miss remains an unknown source section.
- Camera, lens, extension, numeric metadata, media type, and filtered results all use the same set of compact source records. If a page contributes a facet option, its matching items are eligible for the filtered timeline immediately.
- Cached records may be provisional. A later current-run page response atomically replaces that source section's records, catalog contribution, and filter membership. A verified record must never be overwritten by a late provisional cache emission.
- Source-page eviction from the unfiltered browser's eight-page `LibraryPageWindow` does not remove its compact filter records. The filter index remains session-only and contains scalar records rather than `[PhotoItem]` payloads.
- Results may come from noncontiguous source sections. Build them in canonical source order: source section index ascending, then source page offset ascending. Do not require a newest-to-oldest contiguous coverage prefix.
- A day split across multiple source sections may initially be partial. When another cached or fetched section contributes to that day, rebuild that one logical day while preserving the visible item anchor and selection by item ID. This is preferable to hiding an otherwise selectable cached result.
- When filtered rows are visible, translate their synthetic section indices back to Personal Library source-section references. Validate the visible source sections first, then load a bounded neighborhood in the user's scroll direction. Scrolling upward while at or near the top loads newer source sections from the visible source range; scrolling downward while at or near the bottom loads older source sections.
- Use the browser's existing windowing notion of proximity rather than adding ordinary directional buttons. Treat approximately two viewport heights from either edge as near that edge, matching the current near-tail behavior.
- One user edge demand may admit at most eight source sections and at most two page requests concurrently. A viewport rebuild or progress publication must not repeatedly admit more work without another user scroll attempt. If a batch adds no result, another upward/downward scroll gesture at the same edge may request the next bounded batch.
- The only exceptional control is the existing empty-result action: when there are no filtered rows, there is no scrollable viewport or current source anchor from which to infer direction. It starts the next bounded batch from the newest unverified section.
- **Load All Timeline Sections** remains the only operation that intentionally targets every unverified source page over the network. Its **Use Cached Pages** toggle and default-off behavior remain unchanged.
- Applying, clearing, and editing criteria remain session-only and Personal Library-only.

## Implementation

### 1. Index all current-timeline cached pages

Modify `Sources/PhotoCache/LibraryFilterController.swift`:

- Add an idempotent `indexCachedPages()` operation and a separately tracked cache-discovery task. `LibraryFilterModel.configure(library:)` starts observation first and then starts this operation as soon as it creates the controller.
- Walk every `sourceSnapshot.sections` index, skipping any section already represented by an equal-or-stronger state. Read with the existing repository API:

  ```swift
  repository.page(
      section,
      collection: .personalLibrary,
      useCachedPages: true,
      allowNetwork: false,
      priority: .prefetch
  )
  ```

  Because `allowNetwork` is false, an absent key completes without a value. There is no need to expose SQLite key enumeration or bypass `CachedPhotosRepository`.
- Keep no more than two cache-page streams active at once. Consume each `[PhotoItem]`, convert it to compact `LibraryFilterRecord` values, and release the full array immediately.
- Track cache discovery independently from network verification. Add fields to `LibraryFilterControllerEvent`/progress sufficient for the UI to distinguish “searching cached pages” from “N sections indexed” and “N sections verified.” Do not call a cache miss processed or failed.
- Make `apply(_:)` wait for the in-flight cache discovery task before returning its initial `LibraryFilterRegistration`. The popover catalog may update incrementally while discovery runs, but pressing Apply must not race ahead of the promised all-cache result set.
- Define replacement precedence in one function used by cache discovery, ordinary-browser `ingest`, and network scanning:
  - current-run verified replaces provisional;
  - provisional never replaces verified;
  - a new verified value may replace an earlier verified value after an authoritative mutation/page refresh;
  - empty pages are represented explicitly so they are known rather than confused with cache misses.
- Cancel cache discovery and discard its result if the Personal Library fingerprint changes, metadata is reset, or the controller is replaced.

`Sources/SynoTimelineApp/LibraryFilterModel.swift` should expose cache-discovery status in `coverageText`, for example “Searching cached pages…” followed by “Options from 37 cached or loaded sections; 12 verified.” Avoid claiming complete library coverage until all sections are verified.

### 2. Build catalog and results from the same records

Refactor `makeCatalog()` and `makeRegistration()` in `Sources/PhotoCache/LibraryFilterController.swift`:

- Introduce one deterministic helper that returns the currently indexed section records in `(sourceSectionIndex, sourcePageOffset)` order. Both catalog aggregation and matching consume this same record set.
- Remove the `states.prefix`/`includedCount` gate from `makeRegistration()`. A section's records are eligible whenever the section has an indexed page, including provisional cached records and retained records whose latest validation attempt failed.
- Deduplicate item IDs defensively while preserving the first canonical source position. Build `DayTimelineEntry` and `LibraryFilterReference` arrays from that same ordered sequence.
- Keep `DayGroupedTimelineBuilder`, but ensure its input is already newest-first. Its output may update an existing day when another source section for that date arrives.
- Preserve selected facet strings in the popover when a verified replacement removes the last catalog occurrence, as `FilterFacetView.visibleValues` currently does. The active criterion may then legitimately produce zero results.
- Continue suppressing repository/browser replacement when descriptor, snapshot, references, and filter are semantically unchanged. Loading a source page that adds no match must not reload filtered previews.

This is the direct regression fix: `DSC-HX60` cannot appear solely because of records that `makeRegistration()` refuses to inspect.

### 3. Replace the one-way target with a demand queue

The current controller stores one scalar `target` and scans indices from zero through that target. Replace it in `Sources/PhotoCache/LibraryFilterController.swift` with a single scheduler and an ordered, deduplicated source-index queue.

Add controller-facing concepts along these lines:

```swift
public enum LibraryFilterScanDirection: Sendable {
    case newer
    case older
}

public func demandVisibleResultSections(
    _ syntheticSectionIndices: [Int],
    direction: LibraryFilterScanDirection
)

public func loadInitialBatch()
```

Exact visibility types may remain internal, but preserve these semantics:

- Resolve visible synthetic sections through the latest registration's `referencesBySection` and collect their distinct Personal Library `sourceSectionIndex` values.
- Enqueue provisional/failed visible source sections first so visible stale results are validated promptly.
- For `.newer`, enqueue decreasing source indices adjacent to the visible source range. For `.older`, enqueue increasing indices. Skip verified, already queued, and active sections.
- Admit no more than eight new indices for one user edge demand. Keep the existing maximum of two concurrent repository page streams and use normal cached-first requests (`useCachedPages: true`, `allowNetwork: true`). Since cache discovery has already run, these calls normally validate provisional pages or fetch cache misses.
- Deduplicate passive viewport updates by `(direction, visible source-section set/range, user-scroll generation)`. A synthetic snapshot rebuild at the same visible anchor must not trigger the next batch automatically. A new scroll-wheel/trackpad attempt in the same direction increments the user-scroll generation, so the user can cross a zero-match range without a button or passive whole-library scan.
- `loadInitialBatch()` exists only for an empty filtered snapshot. It enqueues the next bounded batch from the newest unverified source section because no visible synthetic section can supply an anchor.
- `loadAll(useCachedPages:)` upgrades the same scheduler by enqueueing every nonverified source section with its selected cache policy. Do not create a second scanner. `cancelScan()` cancels active work, clears only pending network requests, retains compact records, and returns the window to Start.
- `retryFailed()` re-enqueues failures without discarding usable provisional records.

The scheduler must publish catalog/progress updates after source-section replacement, but publish a new registration only when the match snapshot or references changed.

### 4. Send bidirectional viewport demand

Modify `Sources/SynoTimelineApp/LibraryBrowserView.swift`:

- Replace the filter-specific `onNearTail` callback with a narrow edge-demand callback that reports the currently visible synthetic section indices, the requested newer/up or older/down direction, and a user-scroll generation.
- Extend `TimelineScrollView.scrollWheel(with:)` with a callback carrying the vertical scroll direction. The coordinator combines that input with its current geometry: upward input emits only while the viewport is within roughly two viewport heights of the top; downward input emits only within roughly two viewport heights of the bottom. This mirrors the current near-tail windowing threshold while supporting both edges.
- Reset edge-demand state when the collection or snapshot fingerprint changes. Programmatic anchor restoration, day-navigator jumps, and snapshot reconciliation do not increment the user-scroll generation and therefore cannot start scans.
- On a short document that is simultaneously near both edges, use the user's actual scroll direction; never enqueue newer and older batches from one gesture. Keep ordinary `LibraryPageWindow.update` behavior untouched for Personal Library, Favorites, albums, and map collections.
- For `.libraryFilter`, forward the viewport demand through `LibraryFilterModel` to `LibraryFilterController.demandVisibleResultSections`. Issue this callback before or alongside the derived page-window update so the controller joins/promotes the same source-page jobs rather than starting unrelated work.
- Continue relying on the browser's item-ID anchor reconciliation when matches are inserted above or below the viewport.

Modify `Sources/SynoTimelineApp/LibraryFilterModel.swift`:

- Replace `loadNextIfNeeded()` and its `lastTailDemandProcessed` guard with `edgeDemand(...)` forwarding. Preserve the user-scroll generation so passive SwiftUI updates cannot replay a demand.
- If the result snapshot is empty, `loadInitialBatch()` defines its older-direction anchor as the newest unverified Personal Library section. Applying a filter invokes one such bounded initial batch automatically, preserving current behavior.

Modify the filtered branch in `Sources/SynoTimelineApp/LibraryBrowserView.swift`:

- Remove the normal **Load More Results**, **Load Newer Results**, and **Load Older Results** controls from a nonempty filtered timeline. Edge scrolling is the continuation mechanism.
- In the zero-result state only, show **Load More Results** when unverified sections remain. It calls `loadInitialBatch()` because an empty synthetic timeline has no edge or visible source range. After a zero-match batch, the action remains available for another bounded batch.
- Do not derive empty-state availability from the global `remaining` count alone; expose whether an initial unverified source section is available.

No new keyboard shortcut is needed. If one is added later, it must also be a named macOS menu command.

### 5. Keep derived-page validation coherent

Retain the defensive ID and predicate checks in `Sources/PhotoCache/LibraryFilterCollection.swift`, but make viewport demand the authoritative path that refreshes compact source records and rebuilds registrations.

- When a visible derived page and the controller request the same Personal Library source section, both must join the repository's existing shared page job.
- A verified replacement that removes or adds matches updates the controller first-class record set and registration. The derived page loader may temporarily omit a stale reference, but the subsequent semantic registration removes that placeholder permanently.
- Do not persist derived pages. Continue bounding `metadata.libraryFilterPages` to eight entries.
- Keep favorite and rotation propagation unchanged; their authoritative Personal Library page updates must still reach the compact filter index through ordinary page observation or existing mutation events.

If testing shows a race where `libraryFilterPage` can validate a source page without the controller observing the shared result, add a repository-owned, session-only source-page observation stream keyed by Personal Library section. Do not add a second cache or let the repository retain the controller. Prefer this stream only if viewport demand ordering cannot guarantee observation.

## Tests

### `Tests/PhotoCacheTests/LibraryFilterControllerTests.swift`

Add regression and scheduler coverage:

1. Seed only a noncontiguous older source page with camera `DSC-HX60`; after cache discovery, assert the catalog contains it and applying that camera produces its item immediately.
2. Seed several current-timeline page keys and leave others absent; assert cache discovery finds all seeded pages and performs zero transport calls.
3. Assert pages belonging to an obsolete/not-current timeline descriptor do not enter the catalog.
4. Deliver a verified page before a delayed provisional cache result and assert the controller does not downgrade records, catalog, or state.
5. Apply a filter across noncontiguous source sections and assert deterministic newest-first item order and correct reference offsets.
6. Load the other half of a split day and assert the existing synthetic day is rebuilt without duplicate IDs.
7. Demand visible results while moving older and newer; assert the correct adjacent source indices are requested, each demand admits at most eight, and concurrent reads never exceed two.
8. Publish progress and rebuild at the same edge after a zero-match batch and assert neither cascades. Send another user scroll generation at that edge and assert the next batch is admitted.
9. Replace a provisional cached camera with verified metadata lacking that camera; assert both catalog and results remove it while the selected string can remain in app presentation state.
10. Preserve the existing load-all tests, including default cache bypass, cancellation, failure retry, and concurrency.

### `Tests/SynoTimelineAppTests/LibraryFilterModelTests.swift`

- Assert Apply waits for cache discovery and installs a registration containing a noncontiguous cached match.
- Assert a loaded section with no added/removed matches does not reinstall the collection or change the browser snapshot revision.
- Assert newer/older edge demands are forwarded once per user scroll generation and another scroll attempt can continue after no matches.
- Assert ordinary nonempty results have no load-more controls and the empty-result fallback action remains available.

### Browser-focused tests

Add or extend browser/coordinator tests for:

- upward-at-top versus downward-at-bottom callbacks using the same edge-proximity threshold as current windowing;
- no demand away from an edge or caused solely by a programmatic snapshot rebuild;
- a short document uses scroll direction and never requests both directions from one gesture;
- preservation of the visible item anchor when a newly discovered match is inserted before it;
- normal unfiltered page demand remaining unchanged.

Run the focused filter/controller/browser tests first, then the complete Swift package test suite and `git diff --check`.

## Documentation updates after implementation

Update current-behavior documentation only when the code is complete:

- `docs/PROJECT.md`: state that Personal Library filtering searches every current-timeline cached item page and expands cached-first in either scroll direction.
- `docs/ARCHITECTURE.md`: replace the contiguous-prefix/tail-only description with all-cache indexing, sparse source coverage, bidirectional viewport demand, and the ordered queue scheduler.
- Rename this file to `DONE_LIBRARY_FILTER_CACHE_SCROLL_PLAN.md` and update `docs/plans/README.md`.

The root `AGENTS.md` overview does not need expansion for this correction; its existing Personal Library filtering summary remains accurate at overview level.

## Acceptance criteria

- Any camera, lens, or extension displayed as found from a cached page can immediately produce all matching records from that page.
- A cached page at any current Personal Library section index participates without first loading every newer section.
- Scrolling filtered results toward newer or older content requests the corresponding adjacent source pages cached-first, with at most two active page reads and eight new source sections per demand.
- A no-match batch does not cause a passive whole-library scan, and another scroll attempt at the same edge continues in that direction. An empty result uses the sole fallback action because it has no scrollable edge.
- Current-run verification replaces stale cached contributions without duplicate items, catalog ghosts, scroll jumps away from the visible item, or unnecessary preview reloads.
- The explicit load-all workflow, cache-policy checkbox, unfiltered browser, viewer, Info panel, selection, Favorites, and rotation behavior remain intact.
