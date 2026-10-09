# Personal Library Filtering

Status: Implemented. Product decisions were confirmed on 2026-10-09.

## Goal

Add client-side filtering to the Personal Library for metadata already returned in item pages:

- Camera (multi-select)
- Lens (multi-select)
- Megapixels (inclusive range)
- File size (inclusive range)
- ISO (inclusive range)
- Focal length in millimetres (inclusive range)
- Aperture/f-number (inclusive range)
- Shutter speed in seconds (inclusive range, accepting fractional entry)
- File extension (multi-select)
- Media type: Photo, Video, Live Photo (multi-select)

Filtering is cached-first and incremental. It immediately evaluates metadata that has already been indexed in the current app run, then scans additional Personal Library item-page sections in chronological order when the user reaches the end of the filtered results. A Library menu command loads every Personal Library item-page section so the filter and its option catalog can become complete.

The timeline response itself does **not** contain camera, lens, exposure, resolution, size, extension, or item type. It contains only section/date/count descriptors. Those filter fields are in the lazily fetched `PhotoItem` pages. In this plan, “load all timeline sections” therefore means “fetch and validate the item page for every section in the current Personal Library timeline.”

## Product decisions and constraints

- Scope the first slice to the Personal Library. Favorites, albums, map-result collections, and an open viewer are not independently filterable.
- Keep filter criteria, scan coverage, and the filtered collection session-only. Cached source pages remain on disk under the existing cache policy, but the active filter is not restored after relaunch.
- Treat an empty selection for a multi-select facet as “all values.” Within one facet values are ORed; facets are ANDed together.
- Use inclusive range bounds. Either bound may be empty. An item missing a value fails that facet only when the facet has an active bound.
- Normalize camera and lens by trimming whitespace, but otherwise preserve the server string. Match case-insensitively while displaying the first observed spelling.
- Normalize file extensions to uppercase literal suffixes without the dot. Keep literal extensions distinct (`JPG` and `JPEG`, `HIF`, `HEIC`, and `HEIF`) because the suffix itself is useful provenance: for example, Fujifilm cameras commonly produce `.hif`, while an edited derivative may be `.heic`. The multi-select control still lets the user combine related extensions when desired.
- Classify an item as Live Photo when `type == "live"` or `live_type == "live"`; otherwise `type == "video"` is Video and the remaining displayable stills are Photo. Unknown server types do not silently become Photo: retain an internal `.unknown(String)` classification, exclude them from an active type filter, and show them only when type filtering is inactive.
- Applying or changing a filter clears the filtered collection selection and starts its result view at the newest match. Clearing the filter returns to the unfiltered Personal Library and its preserved scroll anchor and selection.
- A viewer opened from filtered results freezes the playlist available at open time, matching the existing viewer contract. Results found by later scanning appear in the browser after the viewer closes; they are not inserted into an open playlist.
- Do not retain complete `[PhotoItem]` arrays for the library. The compact filter index may retain scalar filter records and interned camera/lens/extension IDs, while renderable page payloads remain bounded by the existing page-window policy.

## User experience

### Filter control

Add a filter button to the Personal Library toolbar, before the rotation/favorite controls:

- Inactive: `line.3.horizontal.decrease.circle`, help and accessibility label “Filter Library”.
- Active: filled variant plus an accessibility value such as “3 active filters”.
- The control is shown only for the Personal Library, not Favorites, albums, map results, or the viewer.
- Clicking opens a popover. The popover owns a draft; edits do not rebuild the browser until **Apply** is pressed. **Clear** removes every criterion and returns to the unfiltered library.

Popover layout:

1. Media type checkboxes: Photo, Video, Live Photo.
2. Camera, Lens, and File Extension disclosure groups containing searchable multi-select checklists. Sort camera/lens localized case-insensitively and extensions lexically. Preserve selected values even if a later provisional-page replacement temporarily removes them from the discovered catalog.
3. Range rows with Min and Max text fields:
   - Megapixels: decimal MP.
   - Size: decimal value plus a per-field unit menu (KB, MB, GB); store bytes.
   - ISO: positive integer.
   - Focal Length: decimal millimetres.
   - Aperture: decimal f-number; accept `2.8`, `f/2.8`, or `F2.8`.
   - Shutter Speed: accept `1/250`, `0.004`, `1/250 s`, or `0.004 s`; store seconds as `Double` and compare actual exposure duration.
4. A secondary coverage line: for example, “Options from 18 of 642 sections” or “All 642 sections loaded”. The catalog is explicitly incomplete until all sections have been processed.
5. Validation appears beside the relevant range row. Reject non-finite/non-positive values and a minimum greater than its maximum; disable **Apply** while invalid.

The filtered browser uses the existing fixed grid, day headings, selection gestures, day navigator, Info panel, viewer, Favorites, and rotation actions. Its status distinguishes:

- “No matches in loaded sections” when unscanned sections remain.
- “No matches in library” only when every section has been processed successfully.
- “12 matches · 84 of 642 sections” while coverage is partial.
- A retryable incomplete state when one or more sections failed.

Near the tail, request another bounded scan batch automatically. Also render a trailing **Load More Results** button so a zero-match batch never leaves the user with no way to continue. A batch processes at most eight source sections and continues through the end of the current day so published result days are never partial. Stop earlier only after at least two viewport-heights of new matches are available. Do not turn a rare filter into an implicit whole-library scan; each subsequent tail demand or button click starts another batch.

### Media-type icon in Info

Add `PhotoItem.mediaKind` as the single source of truth and show its icon immediately before the copyable filename in the single-item Info layout:

- Photo: `photo`
- Video: `video`
- Live Photo: `livephoto`
- Unknown: `doc`

The icon is decorative inside the combined filename row but the row accessibility label includes “Photo”, “Video”, or “Live Photo”. This is independent of whether a type filter is active.

### Load-all command

Add **Load All Timeline Sections** to the existing Library menu, after **Download Thumbnails…** and separated from selection commands. It has no keyboard shortcut.

- Enable only when the Personal Library has a validated current-run timeline and a repository is available.
- Starting it opens a nonmodal `UtilityWindow` titled “Load Timeline Sections”. A second invocation focuses the existing operation instead of starting a duplicate.
- Show processed/total sections, matching-item count when a filter is active, cache/network status for the current page, failures, and a determinate progress bar.
- **Cancel** stops admitting new page work but retains completed cache entries and compact index records. Re-running resumes missing/failed sections.
- **Close** after completion leaves all page entries subject to the ordinary disk budget; this command does not pin metadata or download thumbnails/originals.
- Fetch at most two item pages concurrently at `.prefetch` priority. Visible browser page demand retains priority through the repository's existing shared-job promotion.
- Cached pages emit immediately. A page counts as fully processed for this run only after a verified value; when validation fails, keep provisional filter results useful but report the section as unverified/failed rather than claiming complete coverage.

## Data model and parsing

### 1. Media kind (`SynologyAPI`)

In `Sources/SynologyAPI/PhotoModels.swift` add:

```swift
public enum PhotoMediaKind: Hashable, Sendable {
    case photo
    case video
    case livePhoto
    case unknown(String)
}

public extension PhotoItem {
    var mediaKind: PhotoMediaKind
}
```

Keep `type` and `liveType` intact for wire/cache round trips. Do not replace them with the normalized enum because unknown response values must remain recoverable.

### 2. Filter definition and compact record (`PhotoCache`)

Add `Sources/PhotoCache/LibraryFilter.swift`:

```swift
public struct OptionalNumericRange<Value: Comparable & Sendable>: Equatable, Sendable {
    public var minimum: Value?
    public var maximum: Value?
}

public struct LibraryFilter: Equatable, Sendable {
    public var mediaKinds: Set<PhotoMediaKind>
    public var cameras: Set<String>
    public var lenses: Set<String>
    public var extensions: Set<String>
    public var megapixels: OptionalNumericRange<Double>
    public var bytes: OptionalNumericRange<Int64>
    public var iso: OptionalNumericRange<Double>
    public var focalLengthMM: OptionalNumericRange<Double>
    public var aperture: OptionalNumericRange<Double>
    public var exposureSeconds: OptionalNumericRange<Double>

    public var isEmpty: Bool
    public func matches(_ item: PhotoItem) -> Bool
}
```

Add a compact internal `LibraryFilterRecord` containing item ID, capture day/time, source section index and page offset, media kind, interned string-table IDs for camera/lens/extension, and optional numeric values. The controller retains records, not `PhotoItem`, after a page is processed.

Parsing rules:

- Megapixels: `Double(width) * Double(height) / 1_000_000`; do not use the Info panel's truncated display integer.
- Size: positive `filesize` in bytes. Zero or missing is absent.
- ISO: first positive finite numeric token in `exif.iso`.
- Focal length: first positive finite numeric token in `exif.focalLength`; server display suffixes such as `mm` are ignored.
- Aperture: accept `F2.8`, `f/2.8`, or a numeric scalar and store `2.8`.
- Shutter: parse `numerator/denominator` or a decimal, ignoring a trailing `s`; reject a zero denominator and non-positive/non-finite results.
- Extension: last filename suffix after the final dot, uppercased using a fixed locale. A missing/empty suffix is absent.

Keep parser functions internal but pure so `PhotoCacheTests` can exercise observed strings and malformed input. Comparison is inclusive. Multi-select matching uses normalized lookup keys rather than localized display strings.

## Filter scanning and session collection

### 3. Controller and coverage (`PhotoCache`)

Add `Sources/PhotoCache/LibraryFilterController.swift` as an actor owned by `LibraryModel` for the current Personal Library timeline fingerprint. It owns:

- The validated source `TimelineSnapshot` and `LibraryIndex`.
- One compact `LibraryFilterRecord` table keyed by source section/page offset.
- Interned camera, lens, and extension catalogs with reference counts, so a verified replacement can remove values no longer present without leaving stale options.
- Per-source-section state: unseen, provisional, verified, or failed.
- A monotonically increasing revision and `AsyncStream<LibraryFilterControllerEvent>` with catalog, coverage, scan progress, and active-filter snapshot changes.
- At most one scan scheduler. Tail loading and load-all upgrade the same scheduler's target; they never start competing scans.

Public operations:

```swift
public func observe() -> AsyncStream<LibraryFilterControllerEvent>
public func ingest(sectionIndex: Int, items: [PhotoItem], verified: Bool)
public func apply(_ filter: LibraryFilter) async -> LibraryFilterRegistration
public func loadNextBatch()
public func loadAll()
public func cancelScan()
public func retryFailed()
public func unregisterFilter()
```

`ingest` is also called for Personal Library pages the ordinary browser has already loaded. Add a narrow page-observation callback to `LibraryBrowserScrollView`/its coordinator and invoke it only for `.personalLibrary`; do not expose the page arrays through `LibraryModel` or retain them there.

Scanning walks source section indices newest-to-oldest. It uses `repository.page(section, collection: .personalLibrary, allowNetwork: true, priority: .prefetch)`, consumes cached then verified emissions, updates/replaces that section's compact records, and releases the `[PhotoItem]` immediately. Process no more than two source page streams concurrently, but commit records and advance contiguous published coverage in section order.

When a filter is active, recompute matches away from the main actor over compact records. Publish only complete capture days: if the last processed section splits a day that continues in the next descriptor, keep that day's matches pending until every contributing source section has been processed. This makes published result days append-only during normal scanning and avoids selection/scroll churn.

For each completed matched day, chunk references into bounded result pages (use `DayGroupedTimelineBuilder.defaultSectionLimit`, currently 1,000). Build a synthetic `TimelineSnapshot` with the normal newest-first day/order contract and a parallel mapping from each synthetic section to ordered `(sourceSectionIndex, sourcePageOffset, itemID)` references. The compact mapping is the only full result index retained.

On a provisional-to-verified replacement whose membership/order differs, rebuild the affected synthetic day and publish a semantic revision. Preserve the browser's top visible item and selection by item ID; remove selected IDs that no longer match. Do not use raw filtered ordinals as the reconciliation identity across this replacement.

### 4. Session collection routing (`SynologyAPI` and `PhotoCache`)

Extend `PhotoCollectionDescriptor` with a session-only `.libraryFilter(UUID)` case plus `libraryFilterID`/`isLibraryFilter`. Like `.mapFilter`, it is never included in `allCases`, persisted in navigation restoration, or sent to Synology timeline endpoints.

Add `Sources/PhotoCache/LibraryFilterCollection.swift` and repository entry points:

```swift
public func registerLibraryFilter(_ registration: LibraryFilterRegistration)
public func replaceLibraryFilterSnapshot(_ registration: LibraryFilterRegistration)
public func unregisterLibraryFilter(_ descriptor: PhotoCollectionDescriptor)
```

Route `CachedPhotosRepository.page` for `.libraryFilter` to a derived-page loader:

1. Resolve the synthetic section to its compact ordered source references and capture the filter-session revision.
2. Group references by source section.
3. Read the source Personal Library pages cached-first, at most two concurrently. New network work still requires the source timeline to be validated in this run.
4. Extract only the referenced offsets, verify the expected item IDs, reapply the filter to protect against stale mappings, and restore synthetic order.
5. Reject publication if the session revision changed while suspended. Ask the controller to rebuild that source section when identity or membership differs.
6. Keep only bounded session derived pages in the existing `LibraryPageWindow`; do not persist them under durable cache keys. The authoritative Personal Library pages remain the sole persisted metadata.

Store the latest synthetic snapshot in repository session state so `latestTimelineSnapshot(collection:)`, `SelectionInfoResolver`, `SelectionFavoriteResolver`, `SelectionRotationResolver`, and `PhotoViewerSession` continue to use their existing collection-aware paths.

Generalize the current `isMapFilter` branches that really mean “derived Personal Library collection” into a semantic property such as `usesPersonalLibrarySource`. In particular:

- Favorite mutations patch authoritative Personal Library pages, then publish item/favorite changes to filtered page windows.
- Rotation publishes item replacements to the filtered browser/viewer. Megapixel membership is unchanged by a width/height swap, so no filter rebuild is needed for rotation alone.
- Metadata-only/full cache reset and a semantic Personal Library timeline replacement unregister the filter and return the shell to the unfiltered Personal Library.
- Filter-page failures never write partial derived data to disk.

Do not duplicate the browser, viewer, Info, selection, Favorites, or rotation implementations for filtering.

## App integration

### 5. Filter state (`SynoTimelineApp`)

Add `Sources/SynoTimelineApp/LibraryFilterModel.swift`, a `@MainActor ObservableObject` responsible only for presentation state:

- Committed and draft `LibraryFilter` values.
- Discovered catalog and coverage/progress published by the controller.
- Range-field strings, unit choices, and validation errors.
- Active derived collection descriptor and synthetic snapshot/revision.
- Popover visibility and active-filter count.
- Commands to apply, clear, load next, load all, cancel, and retry.

`LibraryModel` remains the source for repository/timeline availability. It creates or resets the controller when the verified Personal Library timeline fingerprint changes and forwards controller snapshots into its existing per-collection snapshot dictionaries. Append-only scan updates increment `snapshotRevision` but not `viewerSnapshotRevision`; membership corrections that affect an already published day invalidate the filtered viewer only if its frozen playlist can no longer be resolved.

Add `Sources/SynoTimelineApp/LibraryFilterView.swift` for the popover and `LibraryFilterToolbarControl` in `LibraryControls.swift`.

### 6. Shell and browser wiring

In `App.swift`, create one `LibraryFilterModel`, inject it into the main window, and add the timeline-loading utility scene.

In `AppShellView.swift`:

- When the sidebar destination is `.personalLibrary` and a filter is active, browse the `.libraryFilter` descriptor while leaving the sidebar selection on Library.
- Preserve the ordinary Personal Library restoration anchor before activating the filter. Use a session-only anchor for the filter and restore the ordinary anchor when cleared.
- Show the filter toolbar control only in the non-viewer Personal Library state.
- Show a compact principal status while active, e.g. “128 Matches · 84/642 Sections”.
- Keep a filter active when navigating temporarily to Favorites/Map/Albums and restore it on return during the same run.
- Clear/unregister the filter on metadata invalidation or a changed authoritative Personal Library fingerprint.

In `LibraryBrowserView.swift`:

- Forward delivered Personal Library pages to the filter controller via the narrow callback described above.
- Add a trailing scan sentinel for the derived filter collection. Near-tail visibility calls `loadNextBatch`; the explicit button does the same.
- Preserve the top visible filtered item ID and selection IDs across a corrected filtered snapshot, then translate them back to new ordinals after rebuild.
- Keep the existing maximum-eight derived page window. Source-page resolution inside a derived page is separately bounded to two concurrent reads.

### 7. Info panel

In `InfoPanelContent`, add `mediaKind` (or a precomputed symbol/accessibility label). Populate it in `InfoPanelModel.singleContent(from:)` from `PhotoItem.mediaKind`.

In `InfoPanelView.singleContent`, replace the standalone filename button with an `HStack` containing the media-kind symbol and the existing copy button. Keep middle truncation, copy behavior, and the existing item ID/path row unchanged.

## Load-all implementation

### 8. Progress model and window

The load-all command is a target upgrade on `LibraryFilterController`, not a second downloader. Add `TimelineSectionLoadProgress` with:

- total, processed, verified, provisional, failed, and remaining section counts;
- current section/day label;
- active-filter match count when available;
- running/canceling/finished state;
- one concise failure entry per section.

Add `Sources/SynoTimelineApp/TimelineSectionLoadView.swift`. Follow the cancellation/lifecycle patterns in `ThumbnailRangeDownloadView`, but do not add date handles or thumbnail work. Closing a running window cancels the scheduler after the user confirms; closing a finished window only dismisses it.

In `LibraryControls.LibraryCommands`, add the menu command and route it through `LibraryFilterModel.startLoadAll()`. In `App.swift`, register the nonmodal scene once. The controller shares repository page jobs with the browser, selection resolvers, and other metadata consumers.

## Execution order

1. Add `PhotoMediaKind`, parsing helpers, `LibraryFilter`, compact records, and pure predicate tests.
2. Implement `LibraryFilterController` ingestion, catalogs, coverage, bounded scan scheduling, complete-day publication, cancellation/resume, and unit tests.
3. Add `.libraryFilter`, repository session registration/page derivation, lifecycle invalidation, and repository tests.
4. Generalize mutation/source-collection branches and verify Info/Favorites/rotation/viewer behavior against a filtered collection.
5. Add `LibraryFilterModel`, popover, toolbar control, result status, and shell collection switching.
6. Add browser ingestion, tail loading, and item-ID-based snapshot reconciliation.
7. Add load-all progress window and Library menu item.
8. Add the Info-panel media icon and tests.
9. Update current-behavior documentation only after implementation, run the full test suite, and complete manual validation.

## Automated validation

### `SynologyAPITests`

- `PhotoMediaKind` classifies ordinary photo, video, both observed Live Photo shapes (`type=live, live_type=photo|live`), and unknown values.
- Existing `PhotoItem` JSON/cache round trips retain raw type fields.

### `PhotoCacheTests`

- Multi-select OR semantics, cross-facet AND semantics, empty facet behavior, inclusive/open bounds, and missing-value exclusion.
- Literal extension normalization and camera/lens case-insensitive lookup.
- MP, ISO, focal, aperture, and shutter parsers, including malformed/zero/non-finite inputs.
- Compact record replacement updates interned catalog reference counts.
- Scanner consumes cached then verified page emissions without double-counting; a changed verified page replaces provisional records.
- Maximum two concurrent page reads, visible-job priority sharing, eight-section tail batch bound, completion of split days, cancellation, resume, failure, and retry.
- Filtered snapshot order/counts across split source days and 1,000-item synthetic page boundaries.
- Derived pages resolve sparse source offsets in synthetic order, reject stale IDs/revisions, and retain no durable session page cache.
- Favorite and rotation events update visible derived pages; favorite cache patching targets Personal Library source pages.
- Source timeline replacement and both cache reset modes unregister the session filter.
- Load-all reaches exact total coverage, does not request thumbnails/originals, and retains only compact records after releasing page arrays.

### `SynoTimelineAppTests`

- Filter draft validation, Apply/Clear, active count, catalog/coverage copy, and range unit conversion.
- Filter toolbar visibility by destination/viewer state.
- Active filter swaps only the Library detail collection and clear restores its prior anchor.
- Tail demand is coalesced and the explicit load-more action works after a zero-match batch.
- Item-ID selection and top-visible anchor survive a provisional-to-verified result correction.
- Menu command enablement, one-operation behavior, progress, cancel/resume, and completion.
- Info filename row chooses the correct symbol/accessibility media label and preserves copying.

Run `swift test` after focused suites.

## Manual validation

- Apply each facet alone and representative combinations; verify OR within facets and AND between facets.
- Verify boundary equality for every range and missing-EXIF behavior.
- Confirm uncommon shutter strings either parse as documented or are treated as missing without crashing.
- Start with only the newest pages loaded, apply a rare filter, scroll/load more repeatedly, and verify chronological insertion, stable scroll, and accurate partial-coverage copy.
- Run Load All on a warm cache, a cold cache, a slow NAS connection, after cancellation, and with a forced section failure. Confirm the browser remains responsive.
- Go offline after cached pages exist; confirm provisional results remain useful and are not labeled complete.
- Open filtered photos/videos/Live Photos in the viewer; verify navigation is limited to the opening filtered playlist and Info shows the correct icon.
- Exercise selection, Cmd+A, Favorites, rotation, Info, and return-from-viewer in filtered results.
- Clear the filter and confirm the original Library scroll anchor and selection return.
- Switch destinations with a filter active and confirm only Personal Library is filtered.
- Clear metadata and full cache while filtered; confirm safe return to the unfiltered Library with no stale session page.
- Use Accessibility Inspector/VoiceOver for the filter control, checklist values, range errors, load-more sentinel, progress window, and Info filename media label.

## Documentation after implementation

- `docs/PROJECT.md`: describe Personal Library client-side filtering, incremental coverage, the load-all command, and the Info media icon; remove “general client-side filtering” from deferred scope only to the extent implemented.
- `docs/ARCHITECTURE.md`: document compact filter records, the session derived collection, source-page mapping, bounded scanner, mutation routing, invalidation, and load-all behavior.
- Root `AGENTS.md`: update the concise current-scope sentence to include Personal Library filtering.
- `docs/plans/README.md`: rename this file to `DONE_LIBRARY_FILTERING_PLAN.md` and update its entry when implementation and validation are complete.

## Confirmed decisions

1. **Scope:** the first version filters only the Personal Library. Favorites, albums, and map-result collections remain unchanged.
2. **Persistence:** filter criteria and scan coverage are session-only. Cached source item pages continue to follow the existing disk-cache policy.
3. **File extension:** literal suffixes remain distinct and are not grouped into display formats. This intentionally preserves clues about capture and editing provenance, such as Fujifilm `.hif` originals versus `.heic` edited derivatives. Users can combine extensions through multi-select.
4. **Load-all meaning:** **Load All Timeline Sections** loads and validates all Personal Library item pages. The timeline descriptor list itself is already loaded in full.
