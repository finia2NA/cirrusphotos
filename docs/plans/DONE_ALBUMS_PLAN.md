# Albums browsing plan

Status: implemented (2026-10-06). Current behavior is documented in the root `AGENTS.md`.

## Goal

Add Personal Space album browsing:

- A single **Albums** sidebar destination (no per-album rows in the sidebar).
- The detail area shows a full-screen **Albums overview**: a scrollable grid of album cards with cover thumbnail, name, and item count.
- Clicking a card opens that album in the existing day-grouped timeline browser (same grid, selection, navigator, viewer, info panel, favorite actions, and scroll restoration as Personal Library/Favorites), with a back control to the overview.
- Album list and album contents are cached on disk with the same cached-first, validate-once-per-run policy as the timelines.

Read-only slice: no album create/rename/delete/add/remove.

Decisions already confirmed with the user:

- Sidebar shows one Albums button that opens a full-screen albums view; individual albums are not listed in the sidebar.
- Album photos always use capture-time descending order and day grouping. A custom album sort order is ignored.
- The full-screen Albums overview shows album cards with cover thumbnail, name, and item count.

## Verified API behavior

Recorded requests (HAR, `docs/captures/`):

- `almbumsoverviewandopening.har`:
  - `POST SYNO.Foto.Browse.Album` `version=4` `method=list` `offset=0` `limit=100` `category="normal"` `sort_by="album_name"` `sort_direction="asc"` `additional=["sharing_info","thumbnail"]`
  - `POST SYNO.Foto.Browse.Album` `version=4` `method=get` `id=[54]` `additional=["sharing_info","flex_section","provider_count","thumbnail"]`
  - `POST SYNO.Foto.Browse.Item` `version=7` `method=list` `offset=0` `limit=28` `album_id=54` `sort_by="takentime"` `sort_direction="desc"` `additional=["thumbnail","resolution","orientation","video_convert","video_meta","provider_user_id"]`
  - No `Browse.Timeline` request was made while an album was open.
- `albumcreationadditionremovaldeletion.har` (misleading name; see below):
  - `POST SYNO.Foto.Browse.Album` `version=1` `method=delete` `id=[68]` — the only album write captured.
  - `POST SYNO.Foto.BackgroundTask.File` `method=delete` `item_id=[188121]` — this is a library file deletion, **not** an album removal. Never implement it as "remove from album".
  - No create, add-photo, or remove-photo requests exist in the capture, so those write shapes are unverified and out of scope.

Read-only probes against `cirrus` on 2026-10-06 (using the pattern in `scripts/test_synology_login.py`; no writes):

- `Browse.Album list` returned 41 `normal` albums. Sampled records carry `id`, `name`, `item_count`, `type`, `sort_by` (`"default"` for all sampled), `sort_direction`, `start_time`, `end_time`, `create_time`, and `additional.{thumbnail,sharing_info}`. `additional.thumbnail` has the same `unit_id` / `cache_key` / `sm` / `m` / `xl` shape as `ThumbnailInfo` (probe album: `unit_id=77607`, `sm`/`m`/`xl` ready, `preview` broken).
- `Browse.Timeline version=6 method=get` **accepts `album_id` without error but silently ignores it**: the response was byte-for-byte equivalent in sections and day counts to the personal timeline (497 sections, 424,170 items). Do not use it for albums.
- `Browse.Item list` with `album_id` honors `start_time`/`end_time`: for a scanned album day with 112 items, the bounded request returned exactly 112 items, all within that day.
- Bulk scanning works: `album_id` + `offset` + `limit=1000` + `additional=[]` returned all 987 items of the largest album in one request (~196 KB, ~200 B/item). Requesting `limit=5000` returned the same 987 items. An offset beyond the end returns an empty list, which is the reliable scan termination condition.
- `favorite_only=true` is accepted alongside `album_id` (returned 0 on an empty album). Whether `additional.favorite` is populated for favorited album items was not directly observable (no album in the sample contained a known favorite); treat absent as false exactly like the timeline path and verify live once.
- `additional.flex_section` in `Album.get` is a list of per-section item counts that sums to `item_count`; it is not needed for day grouping.

## Unofficial documentation (writes unverified)

`github.com/zeichensatz/SynologyPhotosAPI` (vendored at `docs/SynologyPhotosAPI/`) documents only `SYNO.Foto.Browse.Album.list` (no parameter-bearing write docs), but its captured `SYNO.Foto.lib` advertises these method families:

- `SYNO.Foto.Browse.Album` v1: `count`, `delete`, `download`, `get`, `list`, `set_cover`, `set_name`, `set_order`.
- `SYNO.Foto.Browse.NormalAlbum` v1: `add_item`, `copy`, `count`, `create`, `delete_item`, `get`, `list`, `set_unfreeze`.
- `SYNO.Foto.Browse.ConditionAlbum` v1: `count`, `create`, `get`, `list`, `peek_item_count`, `set_condition`, `suggest`.

Community reverse engineering linked from that repo's issue #16 (`fortysix2ahead/synophotos`, `synophotos/parameters/photos.py`) shows the likely write shapes for a later slice:

- Create album: `api=SYNO.Foto.Browse.NormalAlbum`, `method=create`, `version=1`, `name=<album name>`, `item='[<item ids>]'` (a JSON-encoded string; empty allowed but the web UI requires at least one item).
- Add items: `method=add_item`, `version=1`, `id=<album id>`, `item='[<item ids>]'`.
- Remove items: `method=delete_item` (same `id`/`item` pattern by analogy; not documented).
- Rename/cover/order: `Browse.Album` `set_name` / `set_cover` / `set_order`; album delete: the captured `Browse.Album delete version=1 id=[<album id>]`.

None of these are confirmed against `cirrus`. Before the writes slice, capture the web UI interactions (create album, add photos, remove photo) in a HAR and confirm with the user.

## Design

### Identity model

Album photo sources reuse `PhotoCollectionDescriptor` so every existing collection-keyed subsystem (cache keys, repository state, model dictionaries, viewer, resolvers, restoration anchors) works unchanged:

```swift
public enum PhotoCollectionDescriptor: CaseIterable, Hashable, Codable, Sendable {
    case personalLibrary
    case favorites
    case album(Int64)      // Synology album id
}
```

`Sources/SynologyAPI/PhotoModels.swift:261` currently declares the `String`-raw two-case enum. Replace it with:

- `var rawValue: String` computed as `"personal"`, `"favorites"`, or `"album:<id>"`. Every existing `collection.rawValue` use (cache digests, `validationRun(for:)`, restoration keys, the raw-value test) keeps working.
- `var albumID: Int64?` (`if case .album(let id) = self`).
- `static var allCases: [PhotoCollectionDescriptor] { [.personalLibrary, .favorites] }` — keeps `CaseIterable` conformance so `LibraryModel.load()`'s bootstrap loops are unchanged and albums are never fetched eagerly.
- `favoriteOnly` (`self == .favorites`) and `supportsInitialTimeline` (`self == .personalLibrary`) unchanged.
- Custom `Codable` using the single-string `rawValue` form (do not rely on synthesized associated-value encoding).

The sidebar no longer selects collections directly. Add an app-level destination:

```swift
// Sources/SynoTimelineApp/NavigationRestoration.swift (or its own small file)
enum LibraryDestination: String, Codable, Hashable, Sendable, CaseIterable {
    case personalLibrary, favorites, albums
}
```

### Detail-area navigation

`AppShellView` state:

- `@State private var selectedDestination: LibraryDestination` (initialized from the restoration store).
- `@State private var openedAlbumID: Int64?` (initialized from the restoration store).
- `private var selectedCollection: PhotoCollectionDescriptor?`: `.personalLibrary`/`.favorites` for those destinations; for `.albums` it is `.album(openedAlbumID!)` when an album is open, otherwise `nil` (overview).

Routing:

- `.personalLibrary` / `.favorites`: existing `LibraryBrowserView(collection:)` unchanged.
- `.albums` with `openedAlbumID == nil`: new `AlbumsOverviewView`.
- `.albums` with an album open: `LibraryBrowserView(collection: .album(id))` plus a navigation-placement back button ("Albums", chevron) and the album name in the toolbar principal slot (falls back to "Album" until `model.albums` resolves the name).
- Sidebar selection `select(_:)` still closes the viewer first; switching destinations away from `.albums` keeps `openedAlbumID` so returning to Albums reopens the same album, consistent with launch restoration. The back button clears it.
- After the album list is authoritatively verified, if it no longer contains `openedAlbumID` (including when the list is empty), fall back to the overview and persist the clear. Never clear from an unverified cached list.

Restoration (`NavigationRestoration.swift`) bumps to version 3 (old state is discarded by the existing version check; no migration):

```swift
struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 3
    var version = currentVersion
    var selectedDestination: LibraryDestination = .personalLibrary
    var openedAlbumID: Int64?
    var anchors: [String: PhotoTimelineRestorationAnchor] = [:]   // keyed by collection.rawValue
}
```

`NavigationRestorationStore` gains `selectedDestination`, `setOpenedAlbum(_:)`, and keeps `timelineAnchor(for:)` / `setTimelineAnchor(_:for:)` now backed by the `anchors` dictionary (works for `album:<id>` like any other collection).

### Albums overview

New `Sources/SynoTimelineApp/AlbumsOverviewView.swift`:

- `LazyVGrid` with adaptive columns (`GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20)`), one card per `AlbumSummary`, sorted in server order (`album_name` asc).
- Card: cover image, album name (headline), item count ("N items", with singular handling).
- Card `Button` calls `onOpenAlbum(album)`.
- States: albums empty and no error → `ProgressView("Loading albums…")`; empty with `model.albumListError` → `ContentUnavailableView("Albums unavailable", systemImage: "rectangle.stack.badge.exclamationmark")` with a "Try Again" button calling `model.reload()`; loaded and empty → `ContentUnavailableView("No albums", systemImage: "rectangle.stack")` ("No albums in Personal Space.").
- `AlbumCoverView`: SwiftUI view that consumes `repository.thumbnailWithFallback(thumbnail, size: .m, allowNetwork: true, priority: .visible)` (see `Sources/PhotoCache/CachedPhotosRepository+Thumbnails.swift:49` and the load pattern in `Sources/SynoTimelineApp/ThumbnailCell.swift:79-101`), decodes via `DecodedImages.shared.image(from:maxPixel: 512)`, shows an `NSImage` in a rounded rect (`.fill`/`.clipped`) or the `rectangle.stack` placeholder symbol while loading/failed. `nil` thumbnail → placeholder. Access isolated to the view; do not hold decoded images beyond the card.

### Transport (`Sources/SynologyAPI`)

New `Sources/SynologyAPI/AlbumModels.swift`:

```swift
public struct AlbumSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let createTime: Int64?
    public let startTime: Int64?
    public let endTime: Int64?
    public let sortBy: String?
    public let sortDirection: String?
    public let thumbnail: ThumbnailInfo?

    // CodingKeys mirror the wire names (id, name, item_count, create_time, start_time,
    // end_time, sort_by, sort_direction); `thumbnail` lives under `additional.thumbnail`,
    // so implement custom init(from:)/encode(to:) like PhotoItem does for its
    // `additional` nesting (Sources/SynologyAPI/PhotoModels.swift).
}
```

New `Sources/SynologyAPI/AlbumTimelineBuilder.swift` (pure, unit-testable):

```swift
struct AlbumScanEntry: Sendable {
    let id: Int64
    let time: Int64
}

enum AlbumTimelineBuilder {
    static let daySectionLimit = 1000
    static func snapshot(entries: [AlbumScanEntry]) -> TimelineSnapshot
}
```

Behavior: walk entries in order (already newest-first from `takentime desc`), compute each item's UTC wall-clock day with the same GMT calendar rule as `PhotoItem.utcDayID`, preserve first-encounter day order, and emit one `TimelineSection` per day: `offset=0`, `limit=dayItemCount`, `list=[TimelineDay(year:month:day:itemCount: dayItemCount)]`. If a single day exceeds `daySectionLimit`, emit consecutive sections for it with `offset` advancing within the day (mirrors the split-day semantics documented in `docs/SYNOLOGY_PHOTOS_API.md:164-175`). Use the existing public `TimelineDay`/`TimelineSection`/`TimelineSnapshot` initializers from `Sources/SynologyAPI/TimelineModels.swift`.

`PhotosTransport` (`Sources/SynologyAPI/PhotosTransport.swift`) gains:

```swift
func albums() async throws -> [AlbumSummary]
func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot
```

`SynologyClient` (`Sources/SynologyAPI/SynologyClient.swift`) implements them:

- `albums()`: loop `offset` in steps of `limit=100` against `api=SYNO.Foto.Browse.Album&version=4&method=list&category="normal"&sort_by="album_name"&sort_direction="asc"&additional=["sharing_info","thumbnail"]`; append decoded `data.list`; stop when a page returns fewer than 100 entries. (Values like `"normal"` are JSON-quoted strings; follow the existing parameter-quoting helpers.)
- `albumTimeline(albumID:)`: loop `offset` in steps of `limit=1000` against `api=SYNO.Foto.Browse.Item&version=7&method=list&album_id=<id>&sort_by="takentime"&sort_direction="desc"&additional=[]`; collect `(id, time)`; stop on an empty page; defensive cap of 2048 pages (throw a transport error beyond it). Pass the collected entries to `AlbumTimelineBuilder.snapshot`.
- `items(in:collection:)`: when `collection.albumID != nil`, add `album_id=<id>`, `sort_by="takentime"`, `sort_direction="desc"` to the existing section parameters (`start_time`/`end_time` from `section.dateBounds`, `offset`, `limit`, and the unchanged `PhotosRequestFields.pageAdditional`). Do not add `favorite_only`. Keep throwing/no-op paths for `.album` in `timeline(collection:initial:)`; the repository never routes albums there.

### Repository (`Sources/PhotoCache`)

Cache artifacts:

- `CacheKey.albumList(namespace:)` = `digest("\(namespace)|album|v4|list|normal|album_name|asc|sharing_info,thumbnail")`.
- Album snapshots reuse `CacheKey.timeline(namespace:collection: .album(id))` and the existing timeline validation machinery.
- Album item pages reuse `CacheKey.page(..., collection: .album(id))`; bookkeeping is automatic through `collection.rawValue`.
- `CacheKind` gains `case albumList` (append as raw value 5; existing raw values must not move). `CachePriorityPolicy.defaultClass` maps `.albumList` to `.activeTimeline`.
- Album covers reuse `CacheKey.thumbnail`/`thumbnailIdentity` with the album's `ThumbnailInfo` (unit-ID keyed; a cover that is also a library photo shares its cache entry).

New `Sources/PhotoCache/CachedPhotosRepository+Albums.swift`:

```swift
extension CachedPhotosRepository {
    public func albums() -> AsyncStream<ResourceEvent<[AlbumSummary]>>
}
```

Mirror `timeline(collection:)` in `CachedPhotosRepository+Metadata.swift:5-48`: read `CacheKey.albumList` from the store, decode `[AlbumSummary]`, yield `.value(..., verified: entry.validatedRun == albumListValidationRun())`, and return early when validated this run; otherwise register a shared job (`RepositoryState` gains `albumListJob: SharedJob<[AlbumSummary]>?` and `albumListLatest`), acquire the `.metadata` gate at `.visible`, `connect()`, call `client.albums()`, store with `kind: .albumList`, `validatedRun: albumListValidationRun()`, and yield `.value(list, verified: true)`. On failure yield `.failure("Album list: …")` and keep any cached value. Add `albumListValidationRun()` as `"\(runID):albums"` (mirror `validationRun(for:)` in `+Metadata.swift:233`). Release subscribers on termination like `releaseTimeline`.

`timeline(collection:)` album branch (`+Metadata.swift:20-35`): when `collection.albumID != nil`, skip the initial-timeline step (already excluded by `supportsInitialTimeline`) and call `client.albumTimeline(albumID:)` instead of `client.timeline(collection:initial:)`; everything else — cached read, `metadata.latestTimelines[collection]`, store write, verified-flag computation, cancellation, and subscriber release — is identical.

Favorite writes (`CachedPhotosRepository+Favorites.swift:182-241`): rename `patchPersonalPagesBatch` to a collection-aware `patchAffectedPagesBatch`. Personal Library keeps using `action.sectionsByID`; albums use `action.sectionsByID` too (they are the album's synthesized sections) and must patch `CacheKey.page(..., collection: action.collection)`; only Favorites keeps the search-personal-pages-by-day behavior and the `.personalLibrary` patch keys. `setFavoritesBatch`'s `.favorites` mutation-epoch bumps and the authoritative Favorites refresh stay as they are — album membership is independent of favorite status. Because `favorites.applyingOverrides` and the global `favoriteChanges()` stream apply to every collection, hearts in album grids, the album viewer, and album selection batches update without further changes.

`ThumbnailRangeDownloader.swift:113` stays personal-only.

### Model (`Sources/SynoTimelineApp/LibraryModel.swift`)

Add:

```swift
@Published private(set) var albums: [AlbumSummary] = []
@Published private(set) var albumsVerified = false
@Published private(set) var albumListError: String?

func albumName(for collection: PhotoCollectionDescriptor) -> String?
func ensureCollectionLoaded(_ collection: PhotoCollectionDescriptor)

private var albumsTask: Task<Void, Never>?
private var openedCollections: Set<PhotoCollectionDescriptor> = []          // albums only
private var collectionFetchTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]
```

- `ensureAlbumsLoaded()`: record album-list demand and start the `repository.albums()` subscription once (`albumsTask`) when the repository exists. `AppShellView` calls it only when Albums is selected, so ordinary Library/Favorites startup does not fetch album metadata.
- `load()`: after the repository exists, start the album-list subscription only when it was requested, and start a `repository.timeline(collection:)` fetch for every collection in `openedCollections` (so `reload()` re-fetches demanded albums too). `receive` updates `albums`/`albumsVerified`/`albumListError` on its events, and album timeline events flow through the existing `receive(_:collection:)` paths (snapshots, revisions, verification, errors are already collection-keyed dictionaries).
- `ensureCollectionLoaded`: ignore non-album collections; insert into `openedCollections`; start the fetch task if the repository exists (otherwise `load()` drains the set).
- `reload()`: also cancel `albumsTask` and all `collectionFetchTasks`, clear both, then run the existing reload flow so albums re-validate with the rest of the app.

`timelineVerified(for: .album(id))` becomes true after the scan completes and drives `allowNetwork` exactly like other collections.

### Views (`Sources/SynoTimelineApp`)

`AppShellView.swift`:

- Sidebar `List` becomes destination-based: `Label("Library"…)` tag `.personalLibrary`, `Section("Collections")` with Favorites tag `.favorites`, and a new `Section("Albums")` containing one `Label("Albums", systemImage: "rectangle.stack")` tag `.albums`. No album rows.
- `detail` switch as described above; keep `.id(collection)` on the browser for personal/favorites and on the album browser.
- `openPhoto`, `closeViewer`, `followViewer`, `revealRequest`, `updateInfoPanelContext`, and the viewer-revision `onChange` guard must handle `selectedCollection == nil` (overview): no browser controls, no viewer, no info context.
- Toolbar: viewer path unchanged; in a collection browser show size/favorite/info controls as today; on the overview show only the connection item.
- `openAlbum(_ album: AlbumSummary)`: set `openedAlbumID`, persist via the store, `model.ensureCollectionLoaded(.album(album.id))`, refresh the info-panel context.
- Back button action: clear `openedAlbumID` (and persist), update info-panel context.

`LibraryBrowserView.swift` empty/loading copy (`:226-243`): branch for albums — title `library.albumName(for: collection) ?? "Album"`, empty description "This album is empty." / "Cached album is empty. Checking Cirrus…", and `ProgressView("Opening album…")`. Keep the Favorites branch as-is.

`InfoPanelModel`: add `func clearBrowserContext()` (clear content and browser collection) for the overview state; the album browser path needs no change because the panel is already collection-keyed.

Viewer, selection favorites resolver, selection info resolver, browser favorite control, and library commands need no album-specific code once the collection cases and the repository paths above exist.

## Caching and retention summary

- Album list: one cache entry (`.albumList`, active-timeline retention), validated once per run; stale-safe (a failed validation keeps the cached list).
- Album snapshot: one entry per album under the timeline key namespace, validated once per run; a scan costs `ceil(itemCount / 1000)` metadata requests (~200 B/item) only on the validating run.
- Album pages: day-section pages under album-specific keys, `metadataPage` retention, shared 8-page window per browser.
- Covers: ordinary thumbnails; shared with item thumbnails by unit ID.
- Originals/decodes unchanged.

## Constraints and edge cases

- Never call `Browse.Timeline` with `album_id` (silently ignored, returns the whole personal timeline).
- Never call `BackgroundTask.File delete` for album flows; it permanently deletes library files.
- Empty album: scan returns no entries → snapshot with zero sections → existing empty state.
- Membership changes between the scan and page fetches (or between runs) are bounded by the existing once-per-run validation model; a snapshot is stable for the rest of the run. Same exposure as timeline counts.
- Equal `time` values rely on server ordering, exactly like the timeline.
- Very large albums: scan cost scales linearly before first paint on a cold cache; none of the current albums exceeds 987 items, and no cap is added beyond the defensive page cap. If it becomes a problem, a later slice can extend the snapshot lazily as pages load.
- Custom album sort orders are intentionally ignored (capture-time desc day grouping).
- Shared Space, shared albums, folder-backed condition albums, and album writes are out of scope.

## Tests

Update first:

- `Tests/PhotoCacheTests/PhotoCacheTestSupport.swift`: add default `albums()` and `albumTimeline(albumID:)` implementations that throw `TestFailure`.
- `Tests/SynoTimelineAppTests/NavigationRestorationTests.swift` and its support: cover the version-3 state (`selectedDestination`, `openedAlbumID`, anchors dictionary), an old-version payload being discarded, and an `album:<id>` anchor round-trip.

New:

- `Tests/SynologyAPITests/AlbumTimelineBuilderTests.swift`: day grouping and ordering (newest-first), count accuracy, single-day split at the 1000-item boundary, empty input, GMT wall-clock day boundaries.
- `Tests/PhotoCacheTests/AlbumBrowserTests.swift` (mock `PhotosTransport`, mirroring `LibraryBrowserTests`):
  - `albums()` yields the network list, persists it, and a second repository over the same root serves it without a transport call, then validates once.
  - `timeline(collection: .album(id))` performs the scan (mock pages of 1000 + a short page), builds sections, caches the snapshot, and does not call `timeline(collection:initial:)`.
  - `page(section: .album(id))` reaches the transport with `album_id` and the section's date bounds/offset/limit, and caches under the album key.
  - Key isolation: the same section under `.personalLibrary` and `.album(id)` produces different `CacheKey.page` values.
  - A batch favorite action with `collection: .album(id)` patches cached album pages (and leaves personal pages untouched), while a `.favorites` action keeps patching personal pages.

Commands: `swift build --build-tests`, `swift test`, `swift test --filter AlbumBrowserTests`, `swift test --filter AlbumTimelineBuilderTests`, `swift test --filter NavigationRestorationTests`.

## Manual verification (live NAS)

1. Launch: sidebar shows Library, Favorites, Albums; Albums opens the overview; album count and order match the Synology web UI; covers load.
2. Open the largest album (987 items expected): day grouping and day counts match the web UI; scrolling, day navigator, selection, Space/double-click viewer, arrow navigation, zoom, favorite toggle (`.`), and info panel all behave as in Personal Library.
3. Favorite a photo inside an album, return to Favorites, and confirm it appears after the authoritative refresh; confirm the album grid heart updates immediately.
4. Restart: last destination and opened album restore with the scroll anchor; previously opened album anchors restore per album.
5. Cache: open an album, relaunch offline — overview and the opened album render from cache; counts and covers survive; no network error state.
6. Empty album: shows the album empty state, not a spinner.
7. Guardrail: watch the NAS session (proxy/log) and confirm no `Browse.Timeline` request carries `album_id`, and no write requests other than `set_favorite` are issued.

## Files

| File | Change |
| --- | --- |
| `Sources/SynologyAPI/PhotoModels.swift` | `PhotoCollectionDescriptor` gains `.album(Int64)`; computed rawValue/Codable/albumID/allCases |
| `Sources/SynologyAPI/AlbumModels.swift` | new: `AlbumSummary` |
| `Sources/SynologyAPI/AlbumTimelineBuilder.swift` | new: scan entries → `TimelineSnapshot` |
| `Sources/SynologyAPI/PhotosTransport.swift` | `albums()`, `albumTimeline(albumID:)` |
| `Sources/SynologyAPI/SynologyClient.swift` | implement both; album `items(in:collection:)` parameters |
| `Sources/PhotoCache/DiskCache.swift` | `CacheKind.albumList`, `CacheKey.albumList` |
| `Sources/PhotoCache/CachePriorityPolicy.swift` | album-list retention class |
| `Sources/PhotoCache/RepositoryState.swift` | album-list shared job/latest |
| `Sources/PhotoCache/CachedPhotosRepository+Albums.swift` | new: `albums()` cached-first stream |
| `Sources/PhotoCache/CachedPhotosRepository+Metadata.swift` | album branch in `timeline(collection:)` |
| `Sources/PhotoCache/CachedPhotosRepository+Favorites.swift` | collection-aware page patching |
| `Sources/SynoTimelineApp/LibraryModel.swift` | albums list + lazy album timeline loads |
| `Sources/SynoTimelineApp/NavigationRestoration.swift` | `LibraryDestination`, version 3 state, anchors dictionary |
| `Sources/SynoTimelineApp/AlbumsOverviewView.swift` | new: overview grid + cover view |
| `Sources/SynoTimelineApp/AppShellView.swift` | Albums destination, routing, back control, toolbar/info-panel guards |
| `Sources/SynoTimelineApp/LibraryBrowserView.swift` | album empty/loading copy |
| `Sources/SynoTimelineApp/InfoPanelModel.swift` | `clearBrowserContext()` |
| `Tests/...` | as listed above |
| `docs/SYNOLOGY_PHOTOS_API.md` | albums section (already added alongside this plan) |
| `docs/plans/README.md` | index entry for this plan |
| `AGENTS.md` | update the overview's current-scope paragraph when implemented |

## Deferred

- Album create/rename/delete/add/remove. A future slice can start from the community-documented `NormalAlbum.create` / `add_item` / `delete_item` shapes above and the captured `Browse.Album.delete`, but must confirm them with a fresh HAR first.
- Shared Space and shared albums.
- Respecting a custom album sort order.
- Album covers in the sidebar (explicitly not wanted) and album folders.
- Lazy/incremental album snapshot extension for very large albums.
