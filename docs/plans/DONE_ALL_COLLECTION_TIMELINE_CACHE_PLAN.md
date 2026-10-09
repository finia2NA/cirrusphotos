# Load All Timeline Sections Across Persistent Collections

## Status

Completed. **Library > Load All Timeline Sections** warms the authoritative metadata pages for the currently browsed persistent collection: Personal Library, Favorites, or an opened Personal Space album.

## Verified current behavior

- Personal Library, Favorites, and albums all resolve to a `TimelineSnapshot` containing `[TimelineSection]`. Every section has the date bounds, offset, and limit needed by the ordinary `CachedPhotosRepository.page(_:collection:useCachedPages:allowNetwork:priority:)` pipeline.
- Favorites uses `Browse.Timeline.get` and `Browse.Item.list` with `favorite_only=true`. Its sections have the same server-provided day pagination and split-day behavior as Personal Library.
- Albums cannot use `Browse.Timeline` because Synology ignores `album_id`. `SynologyClient.albumTimeline(albumID:)` first scans album items in capture-time order, then `DayGroupedTimelineBuilder` creates equivalent day sections and splits a day into sections of at most 1,000 items. Album page requests subsequently use the same date/offset/limit descriptors with `album_id` and capture-time ordering.
- The existing metadata cache already supports all three collection types. `CacheKey.timeline` and `CacheKey.page` include `PhotoCollectionDescriptor.rawValue`, so Personal Library, Favorites, `album:54`, `album:55`, and so on have independent rows. Metadata validation runs, mutation epochs, timeline jobs, and page jobs are also collection-scoped. No cache schema change or migration is required.
- The current **Load All Timeline Sections** workflow is not collection-neutral. `TimelineSectionLoadView` is backed by `LibraryFilterModel`, whose `LibraryFilterController` always reads `.personalLibrary`. That coupling exists because the load-all operation was introduced as part of session-only Personal Library filtering and also feeds the filter's source records and option catalog.

## Intended behavior

The existing **Library > Load All Timeline Sections** menu item remains a single command.

- In unfiltered Personal Library, it loads every Personal Library section.
- In a session-filtered Personal Library view, it still loads the underlying Personal Library sections and continues updating filter coverage and facet options.
- In Favorites, it loads every section from the currently verified Favorites timeline into Favorites-specific page cache entries.
- In an opened normal album, it loads every section from that album's currently verified synthesized timeline into that album's page cache entries.
- In the Albums overview or an unfiltered/filtered Map view, the command is disabled because there is no eligible persistent collection browser to warm.
- The sheet/window identifies the target collection so the user can distinguish **Personal Library**, **Favorites**, and the current album name.
- **Use Cached Pages** defaults off. Off bypasses stored page payloads and fetches/validates every target section. On skips every section with cached page data without validating it and fetches only cache misses.
- Work remains bounded to two concurrent metadata page requests, is cancellable, reports per-section failures, and supports retrying failed sections.
- Changing destinations after opening the load window does not silently retarget an active or prepared operation. Opening the command again captures the then-current eligible collection and snapshot.
- A Favorites timeline revision during a run invalidates the captured geometry. The coordinator cancels that run and requires reopening/restarting against the latest verified snapshot rather than continuing with stale offsets.

Thumbnail bytes are not part of this command. It warms item metadata pages so the browser can construct rows without showing **Loading photos…**; the existing **Download Thumbnails…** command remains responsible for rendition bytes.

## Implementation plan

### 1. Add a collection-neutral bulk page loader in `PhotoCache`

Create `Sources/PhotoCache/TimelineSectionCacheLoader.swift` with an actor dedicated to explicit bulk metadata warming.

The actor should accept:

- `CachedPhotosRepository`
- one authoritative `PhotoCollectionDescriptor`
- the verified `TimelineSnapshot` captured when the operation is prepared

Expose one event stream containing generic loader progress plus page emissions. `TimelineSectionCacheProgress` contains counts, state, and stable failures; `TimelineSectionCacheEmission` identifies the source section, items, and verification state; `TimelineSectionCacheLoaderEvent` carries the latest progress plus an optional emission. Collection labels remain in the app layer.

Implement these operations:

- `loadAll(useCachedPages:)`: enqueue every unverified section using one policy for the run.
- `cancel()`: cancel the scheduler and all current subscribers, stop admitting more work, and retain completed/failed progress for review.
- `retryFailed()`: enqueue only failed sections with their prior cache policy.
- `shutdown()`: cancel work and finish observers when the window/model releases the loader.

The scheduler must admit at most two sections at once and read each through:

```swift
repository.page(
    section,
    collection: collection,
    useCachedPages: useCachedPages,
    allowNetwork: true,
    priority: .prefetch
)
```

Without the cached-page policy, treat a section as complete only after a `verified: true` value. With it, first probe the ordinary repository page pipeline with networking disabled; count any cached emission as skipped and move on, otherwise fetch the section with stored data bypassed. Preserve section identity by index in the captured snapshot so split-day sections remain distinct.

Do not add direct `DiskCache` writes. The ordinary repository page pipeline must continue to own authentication, shared jobs, collection mutation epochs, cache admission, validation runs, optimistic favorite overlays, and SQLite commits.

### 2. Keep Personal Library filtering synchronized

Use exactly one explicit bulk scheduler for Personal Library, Favorites, and normal albums. `TimelineSectionLoadModel` owns a `TimelineSectionCacheLoader` for every invocation and observes its event stream. For Personal Library, every provisional and verified emission is forwarded through `LibraryFilterModel.ingest(sectionIndex:items:verified:)`, which updates the existing `LibraryFilterController` records, facet catalogs, coverage, and active derived results.

Do not retain a separate explicit `LibraryFilterController.loadAll` path or `LibraryFilterModel` bulk load/cancel/retry wrappers. The filter controller keeps its separate network-disabled cache discovery, empty-result initial batch, and bounded scroll edge-demand scheduler. Do not generalize session filters to Favorites or albums.

### 3. Add an app-level load coordinator

Create `Sources/SynoTimelineApp/TimelineSectionLoadModel.swift` as the main-actor coordinator used by the menu command and `TimelineSectionLoadView`.

It should:

- Track the currently browsed eligible source collection separately from the operation captured when the user invokes the command.
- Normalize `.libraryFilter` to `.personalLibrary` and reject `.mapFilter`.
- Accept `.personalLibrary`, `.favorites`, and `.album(id)` only when `LibraryModel` has a snapshot and `timelineVerified(for:)` is true.
- Resolve a display title from `LibraryModel.albumName(for:)`, with a deterministic album fallback if the name is temporarily unavailable.
- On command invocation, capture the collection, current snapshot, and `snapshotRevision(for:)`, then create the same collection-neutral loader used for every target.
- Observe loader events, publish generic progress with the app-owned target label, and forward Personal Library emissions through `LibraryFilterModel.ingest(sectionIndex:items:verified:)`.
- Observe collection snapshot revisions while a run is active. If the captured revision changes, cancel the run and expose a clear stale-timeline message. This matters for Favorites because successful favorite mutations replace its authoritative geometry.
- Expose `canPresent`, target title, progress, `start(useCachedPages:)`, `cancel()`, and `retryFailed()` to SwiftUI.
- Shut down a prior non-running prepared loader before preparing another collection. Do not retarget a running loader merely because sidebar navigation changed.

The coordinator must not own or duplicate cache data; it only routes and presents work.

### 4. Wire the selected collection into the command

Update `Sources/SynoTimelineApp/App.swift` to create one `@StateObject TimelineSectionLoadModel`, pass it to `AppShellView`, `LibraryCommands`, and the load window as an environment object, and keep `LibraryFilterModel` available for the Personal Library integration.

Update `Sources/SynoTimelineApp/AppShellView.swift` to publish its existing `selectedCollection` into the coordinator on appearance and whenever destination, opened album, map filter, timeline verification, or snapshot revision changes. The shell remains the source of truth because it can distinguish an opened album from the Albums overview and does not depend on selection-command focus.

Update `Sources/SynoTimelineApp/LibraryControls.swift`:

- Keep the label **Load All Timeline Sections** and its current menu location.
- Before opening `timeline-section-load`, ask the coordinator to capture the current eligible target.
- Disable the command using `coordinator.canPresent`, rather than Personal Library's `model.snapshot` and `model.timelineVerified` convenience properties.

### 5. Make the load window collection-aware

Update `Sources/SynoTimelineApp/TimelineSectionLoadView.swift` to observe `TimelineSectionLoadModel` rather than assuming `LibraryFilterModel` is the sole backend.

- Show `Load Timeline Sections` plus a concise target line such as **Favorites** or the album name.
- Preserve the progress bar, counts, failure list, **Use Cached Pages** toggle, Start, Cancel, and retry behavior.
- Keep the cache toggle disabled during a run.
- Cancel an active run when the window disappears, matching current behavior.
- Avoid filter-specific copy such as matching item counts when the target is Favorites or an album. Personal Library may continue showing its match count when a filter is active.

### 6. Tests

Add focused tests without relying on live NAS access.

In `Tests/PhotoCacheTests/TimelineSectionCacheLoaderTests.swift`:

- Favorites load-all passes `.favorites` for every page request and reaches verified completion.
- Album load-all passes the exact `.album(id)` descriptor for every generated section, including two sections for a day above 1,000 items.
- The loader admits no more than two concurrent page reads.
- Default load-all bypasses an existing stale cached page and stores the current response.
- **Use Cached Pages** skips both stale and current-run cached pages without a transport request.
- Cancellation stops admitting later sections.
- Failure and retry affect only failed sections and retain the original cache policy.
- Personal Library, Favorites, and two album IDs produce and retain distinct page cache entries for identical section descriptors.

In `Tests/SynoTimelineAppTests/TimelineSectionLoadModelTests.swift`:

- The active Library target normalizes a session library filter to `.personalLibrary`.
- Favorites and an opened album prepare their own collection and display name.
- Albums overview and Map targets cannot present the command.
- Changing sidebar destinations does not retarget a prepared/running operation.
- A snapshot revision change cancels an active Favorites run and reports stale geometry.
- Personal Library still routes emissions through `LibraryFilterModel` so filter coverage/catalog behavior is preserved.

Keep bulk concurrency, cancellation, cache-bypass, and retry coverage in `TimelineSectionCacheLoaderTests`. Keep `LibraryFilterControllerTests` focused on ingestion, catalog replacement, cache discovery, and bounded scroll/initial demand.

### 7. Documentation

After implementation, update:

- `docs/PROJECT.md`: state that **Load All Timeline Sections** warms item metadata for the active Personal Library, Favorites, or opened album; clarify that it does not download thumbnail bytes.
- `docs/ARCHITECTURE.md`: describe the collection-neutral bulk page scheduler, collection-scoped keys, album synthesized sections, and Personal Library filter ingestion.
- Root `AGENTS.md` Project overview: replace the vague cache-warming wording only if a concise description of all-collection metadata warming improves the orientation card.
- Rename this plan to `DONE_ALL_COLLECTION_TIMELINE_CACHE_PLAN.md` and update `docs/plans/README.md` after implementation and verification are complete.

## Verification

Run the targeted unit suites that cover the new loader, app coordinator, existing filter controller, Favorites cache routing, and album cache routing. Then build the macOS executable.

Manual checks:

1. Open Favorites, invoke **Library > Load All Timeline Sections**, leave **Use Cached Pages** off, and finish the run.
2. Move to distant Favorites dates already covered by the run and confirm rows populate from cached metadata without a prolonged **Loading photos…** placeholder. Thumbnail placeholders may still appear until rendition bytes load.
3. Open a normal album and repeat. Include an album with enough same-day items to exercise split sections if one is available.
4. Return to Personal Library with an active metadata filter, run the same command, and confirm filter options/results expand as pages arrive.
5. Start a run, cancel it, and confirm no later sections are admitted; retry failures if present.
6. With **Use Cached Pages** enabled, confirm cached sections are reported as skipped and do not generate page requests, while uncached sections are fetched.

## Constraints and non-goals

- No cache schema migration or compatibility shim.
- No new Favorites-only or album-only menu command.
- No Shared Space or generated albums.
- No Map-filter metadata persistence; Map remains derived from Personal Library data.
- No thumbnail or original-media bulk download in this workflow.
- No attempt to reuse the album timeline's lightweight ID/time scan as full item pages; that scan intentionally omits the additional metadata required by the browser and filters.
