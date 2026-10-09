# Location Map and Info-Panel Maps

Status: Implemented.

## Execution order

1. `TimelineCore`: `PhotoCoordinate` and the pure cluster builder plus unit tests (step 1).
2. `SynologyAPI`: decode `additional.gps`, add `gps` to the page field list, add the location-scan transport method, and generalize the album day-section builder (step 2).
3. `PhotoCache`: cached-first, fingerprint-validated location index built from the personal-library scan, with the new cache kind and retention class plus unit tests (step 3).
4. `PhotoCache`: session map-filter registry and a filtered page pipeline over Personal Library pages, plus Favorites integration and unit tests (step 4).
5. `PhotoCache`: expose coordinates on `SelectionInfo` (step 5).
6. `SynoTimelineApp`: `MapBrowserModel` and `MapBrowserView` (step 6).
7. `SynoTimelineApp`: sidebar destination, filtered-browser routing, toolbar back control, session snapshot registration (step 7).
8. `SynoTimelineApp`: info-panel map with pin(s) (step 8).
9. Documentation: `ARCHITECTURE.md`, `AGENTS.md`, plan index (step 9).
10. `swift build --build-tests`, `swift test`, then the manual checklist.

## Goal

Add a Map browsing surface and location context to the info panel:

- A **Map** destination under the sidebar's **Collections** section (next to Favorites). It always shows every geotagged photo of the Personal Library, independent of the currently selected destination.
- The map is an Apple Map (MapKit). Photos appear as thumbnail pins. Nearby photos are clustered into a single counted pin when zoomed out; when the view is zoomed in far enough that a location holds one photo, that thumbnail is shown alone.
- Clicking a pin or a cluster opens the existing day-grouped, virtualized timeline browser, filtered to exactly those photos, with a "Map" back control (same pattern as albums). Selection, favorites, the viewer, scroll behavior, and the info panel all keep working inside that filtered timeline.
- The info panel (`Cmd+I`) shows a small map: one pin for a single photo/viewer item, one pin per located photo for a multi-selection. The map is omitted when none of the involved photos has a location.

Out of scope: place names or reverse-geocoded labels, search, Shared Space, video playback, map-based writes, a favorites-only map, and persistence of the map camera or the filtered timeline across launches.

## Confirmed data availability

Read-only probes against `cirrus` on 2026-10-06 (using the `scripts/test_synology_login.py` login plumbing) established everything below. The same facts will be recorded in `docs/SYNOLOGY_PHOTOS_API.md`.

- The Personal Library timeline currently reports **497 sections / 58,760 items** (sum of section `limit`).
- `SYNO.Foto.Browse.Item` `method=list` honors `additional` including `"gps"` (and the already-requested `"address"`). A page returns, per located item:

  ```json
  "additional": {
    "gps": { "latitude": 35.6585805555556, "longitude": 139.745438888889 },
    "thumbnail": { "unit_id": 238257, "cache_key": "238257_1791227407",
                   "sm": "ready", "m": "ready", "xl": "ready", "preview": "broken" }
  }
  ```

  Items without a location simply omit the `gps` key.
- `method=list` also works **without date bounds**: `offset`/`limit=1000` walks the whole library newest-first. Termination is an empty or short list; no `total` is returned. Measured cost: 191 B/item with `additional=[]`, **345 B/item with `["gps","thumbnail"]`** (~20 MB for the full library), and 4.1–4.3 s per 1000-item page for `["gps"]` alone (`["gps","thumbnail","resolution","address"]` cost 565 B/item and ~10 s/page). Three concurrent pages completed six pages in 14.8 s.
- GPS coverage is partial and front-loaded: 332/1000 in the newest page, 1,764/5,000 across the newest five pages (~35%). Roughly 20k located photos are expected.
- `SYNO.Foto.Browse.Item` `method=get` accepts an **`id` array**: `id=[12,34,56]` returns `data.list` with the requested full records **in request order**. Verified with 100, 500, and 1000 IDs (2.2 s, 7.8 s, 6.7 s). `additional` supports `thumbnail`, `resolution`, `orientation`, `video_meta`, `gps`, `favorite`, `exif`, and `address` (all fields the client already requests). One ID must also be wrapped in an array (`id=[12]`).
- The server has **no usable spatial filter**. `Browse.Item` on `cirrus` advertises max version 7, so `list_with_filter` (v1.11) and `list_basic_timeline_info` (v1.9+) return error 104. `geocoding_id` and `id` are silently ignored by `method=list`.
- `SYNO.Foto.Browse.Geocoding` `method=list` returns 735 places (`id`, `name`, `first_level`, `second_level`, `country`, `country_id`, `item_count`) but **no coordinates**, so it cannot place pins; `method=get` requires `id=[..]` and returns the same fields. `SYNO.Foto.Browse.Timeline` `method=get_geocoding` returns only level-name lists (for example `second_level: ["Japan", "Germany", "Romania"]`). Neither can drive a zoomable map.
- Consequence: the map and its clustering are computed client-side from a one-time, cached scan of item locations. This is the only approach that supports both arbitrary spatial clustering and per-photo pins.

## Design overview

```text
Personal Library timeline (existing, startup)
        |
        v
locationIndex() scan: Browse.Item.list, offset/limit=1000, additional ["gps","thumbnail"]
        |  persisted as one cache-kind payload; validated by personal-timeline fingerprint
        v
MapBrowserModel: records -> MapClusterBuilder (pure) -> <=256 annotations
        |                                          |
        | cluster click (member IDs)               | single photo click
        v                                          v
LibraryModel.openMapFilter(records) -> .mapFilter(UUID) descriptor
        |
        | synthetic day-grouped TimelineSnapshot + per-section ID lists
        v
existing LibraryBrowserView / LibraryPageWindow / viewer / info panel / favorites
        |
        v
repository.page(filter:...) -> Personal Library day pages -> exact ID filtering
```

Key decisions:

- **Client-side spatial clustering.** No server endpoint can answer "photos near this region". A grid-accelerated radius builder starts with a fine radius, raises it to the on-screen pin pitch, and doubles it until the result stays within the annotation cap (~256). It joins a photo only to a nearby representative, so grid boundaries do not split neighbors and transitive chains do not create sprawling clusters. Low zoom shows counted clusters, medium zoom splits them, and single-photo groups render a lone thumbnail. Identical coordinates intentionally stay clustered at every zoom.
- **One persisted location index.** The scan runs inside `CachedPhotosRepository`, is shared by all subscribers, yields cached records first, and is validated once per run by comparing the stored personal-timeline fingerprint against the fingerprint of the personal timeline already loaded at startup. A matching fingerprint skips the network entirely; a mismatch refreshes in the background while cached pins stay visible.
- **Filtered browsing reuses the collection descriptor.** A map click registers a session-only `.mapFilter(UUID)` collection whose synthetic `TimelineSnapshot` is structurally identical to album snapshots. All existing machinery (page window, fixed-grid geometry, selection, favorites, viewer, info panel, timeline navigator) works unchanged because filtered pages are served through the same `repository.page(section, collection:)` entry point.
- **Filtered pages reuse Personal Library day pages.** The registration stores the exact ID list for every synthetic section (sections are capped at 250 IDs). A filtered request resolves every Personal Library section covering that day through the existing cached-first page pipeline, then emits the registered IDs in their original order. This populates and reuses the ordinary timeline cache instead of maintaining a second metadata transport path.
- **The info panel map reuses decoded `gps`.** `gps` joins the shared page field list, so every page (normal, album, filtered) carries coordinates; `SelectionInfoResolver` already visits exactly the required items.

### Why the timeline view supports this cheaply

The browser is parameterized by `PhotoCollectionDescriptor` + `TimelineSnapshot`, and everything below `LibraryBrowserView` (page window, viewport geometry, thumbnails, viewer session, info-panel resolver, selection-favorite resolver) talks to the repository through `page(_:collection:)`. Albums already proved this seam by adding a descriptor case, a synthetic snapshot, and a repository page path. The map filter follows the same recipe with one extra piece: session-local pages instead of disk-cached pages, because the ID set exists only for the run.

## Implementation

### 1. Pure coordinate and clustering types (`TimelineCore`)

New `Sources/TimelineCore/MapClustering.swift` (a separate `PhotoCoordinate` type keeps `TimelineCore` platform- and API-independent; `SynologyAPI` and the app both depend on it):

```swift
public struct PhotoCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double)
    /// False for non-finite values or latitude/longitude out of range.
    public var isValid: Bool
    // Custom `init(from:)` accepts a JSON number or a numeric string (defensive;
    // the server currently sends numbers). Encodes as numbers.
}

public struct MapRegion: Sendable, Equatable {
    public let center: PhotoCoordinate
    public let latitudeDelta: Double
    public let longitudeDelta: Double
}

public struct MapCellSpan: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
}

public struct MapPhotoRecord: Sendable, Equatable {
    public let id: Int64
    public let time: Int64
    public let coordinate: PhotoCoordinate
}

public struct MapClusterGroup: Sendable, Equatable {
    public let coordinate: PhotoCoordinate
    public let count: Int
    /// Newest member; supplies the pin thumbnail.
    public let representative: MapPhotoRecord
    /// Descending capture time, then descending id for determinism.
    public let memberIDs: [Int64]
    public var isSingle: Bool { count == 1 }
}

public enum MapClusterBuilder {
    /// Grid-accelerated radius clustering constrained by an annotation cap.
    public static func groups(records: [MapPhotoRecord],
                              in region: MapRegion,
                              maxAnnotations: Int = 256,
                              minimumCellSpan: MapCellSpan? = nil) -> [MapClusterGroup]
}
```

Algorithm, deterministic and O(n · iterations) after the initial O(n log n) ordering:

1. Drop invalid coordinates; keep records inside `region` expanded by a 10% margin.
2. Sort newest-first. Start each axis radius at the viewport span divided by 512, raised to the caller's on-screen pin pitch when supplied.
3. Visit records in order. Search the record's grid cell and its eight neighbors, joining the nearest open cluster whose newest representative is within one radius on both axes; otherwise open a cluster. Double the radii and rebuild until the group count is `<= maxAnnotations`.
4. Emit member IDs and groups newest-first. A one-member group yields `.isSingle`; records sharing the exact same coordinate never split. Longitude wrap is not handled.

Tests (`Tests/TimelineCoreTests/MapClusteringTests.swift`): invalid coordinates excluded; region margin; two nearby points cluster at coarse zoom and separate at fine zoom; a single-point bucket is single; max-annotation cap is respected for thousands of synthetic records; representative is the newest member; identical coordinates stay in one group; deterministic output across runs.

### 2. GPS decoding, field list, transport, and day-section builder (`SynologyAPI`)

`Sources/SynologyAPI/PhotoModels.swift`:

- Add `public let gps: PhotoCoordinate?` to `PhotoItem.Additional` with `case gps`, and update the `Additional(...)` construction in `withFavorite` with `gps: nil`.
- Add `public var coordinate: PhotoCoordinate? { additional?.gps.flatMap { $0.isValid ? $0 : nil } }` on `PhotoItem`.

`Sources/SynologyAPI/PhotosRequestFields.swift`:

- Append `"gps"` to `pageAdditional`. The page cache key derives from this list, so cached pages from earlier builds miss once and are re-fetched, then trimmed by the existing LRU/budget policy. No schema bump (same precedent as the `exif` addition).
- Add `public static let locationScanAdditional = ["gps", "thumbnail"]`.

`Sources/SynologyAPI/PhotosTransport.swift` and `SynologyClient.swift`:

```swift
/// One page of the whole-library location scan: Browse.Item list v7 with no date
/// bounds, `additional` from `PhotosRequestFields.locationScanAdditional`.
/// Returns at most `limit` items newest-first; an empty or short page ends the scan.
func locationScanPage(offset: Int, limit: Int) async throws -> [PhotoItem]
```

`SynologyClient` implements the scan as a form-encoded POST to `/webapi/entry.cgi/SYNO.Foto.Browse.Item`, builds the `additional` JSON from the shared field list (no inline literals), and reuses the existing `post`/`formBody` helpers. The verified ID-batch endpoint remains documented in `docs/SYNOLOGY_PHOTOS_API.md`, but the map filter deliberately reuses normal Personal Library pages.

Rename `Sources/SynologyAPI/AlbumTimelineBuilder.swift` to `DayGroupedTimelineBuilder.swift` and generalize it (album call sites are the only existing users):

```swift
public struct DayTimelineEntry: Sendable, Equatable {
    public let id: Int64
    public let time: Int64
}

public struct DayGroupedTimeline: Sendable {
    public let snapshot: TimelineSnapshot
    /// Item IDs in server order for each section; parallel to `snapshot.sections`.
    public let itemIDsBySection: [[Int64]]
}

public enum DayGroupedTimelineBuilder {
    public static let defaultSectionLimit = 1000
    /// Same day grouping and split-day semantics as the current album builder
    /// (repeated day entry with the full day count, advancing `offset`).
    public static func build(entries: [DayTimelineEntry],
                             sectionLimit: Int = defaultSectionLimit) -> DayGroupedTimeline
}
```

`SynologyClient.albumTimeline(albumID:)` keeps its behavior by using `build(entries:).snapshot` (and `AlbumScanEntry` moves to `DayTimelineEntry`). Update `Tests/SynologyAPITests/AlbumTimelineBuilderTests.swift` for the new API and add an assertion for `itemIDsBySection` (including a >1000-item split day).

Add the new scan method to the protocol-extension defaults in both test-support files (`Tests/PhotoCacheTests/PhotoCacheTestSupport.swift`, `Tests/SynoTimelineAppTests/SynoTimelineAppTestSupport.swift`) so existing mocks keep compiling; mocks that need it implement it explicitly.

### 3. Location index (`PhotoCache`)

New `Sources/PhotoCache/LocationIndex.swift`:

```swift
public struct PhotoLocationRecord: Codable, Sendable, Equatable {
    public let id: Int64
    public let time: Int64
    public let coordinate: PhotoCoordinate
    public let thumbnail: ThumbnailInfo?
}

public enum LocationIndexEvent: Sendable {
    case cached([PhotoLocationRecord])
    case progress(scanned: Int, total: Int?)
    case completed([PhotoLocationRecord], verified: Bool)
    case failure(String)
}

extension CachedPhotosRepository {
    /// Cached-first, shared, cancellable-on-clear location index stream.
    public func locationIndex() -> AsyncStream<LocationIndexEvent>
}
```

- Payload (JSON, one cache entry): `schemaVersion`, nonoptional `sourceTimelineFingerprint: String`, `scannedItemCount: Int`, `records: [PhotoLocationRecord]`. Key: `CacheKey.locationIndex(namespace:)` (`namespace|personal|location-index|v1`). Discard payloads whose `schemaVersion` is not current or whose required fields cannot decode.
- Add `CacheKind.locationIndex` (append at the end so persisted raw values do not shift) and `CacheRetentionClass.locationIndex`, inserted directly after `activeTimeline` in `CachePriorityPolicy.highestToLowest`; map it in `defaultClass(for:)`. The payload is expensive to rebuild (~20 MB of transfer) and must survive normal trimming.
- Stream behavior:
  1. Read the cached payload; emit `.cached(records)` immediately when present.
  2. Join `timeline(collection: .personalLibrary)` and wait for a snapshot verified in the current repository run, then compute its `LibraryIndex(snapshot:).fingerprint`. If it equals the stored fingerprint, emit `.completed(records, verified: true)` and finish — no location scan. A merely cached timeline from an earlier run must not validate the location index.
  3. Otherwise start (or join) the single shared scan job held in `RepositoryMetadataWork.locationIndexWork`.
- Scan job: `total` = sum of personal-timeline section limits (exact progress). Fetch pages of `limit = 1000` with up to **2 pages in flight**; each page acquires `gate.acquire(.metadata, priority: .prefetch, id:)` individually (visible browsing always wins), calls `connect()` then `client.locationScanPage`, and is released after. Assemble records in offset order from the page results; drop items whose `coordinate` is invalid or missing; each record keeps `id`, `time`, `coordinate`, and `thumbnail`. Emit `.progress(scanned:total:)` after every completed page. Stop on an empty or short page. If page 2048 is still full, fail rather than cache a partial index. Persist the payload once on completion with the validated fingerprint captured at scan start and the current `store` generation; emit `.completed(records, verified: true)`.
- Failures: emit `.failure(message)`; cached records stay valid. The job keeps running after its last subscriber leaves (bounded, useful for the next open); it is abandoned if the cache generation changes (`clearCache()`).
- Update `RepositoryMetadataWork.hasDemand` to include the running scan so login is not cancelled mid-scan.

Tests (`Tests/PhotoCacheTests/LocationIndexTests.swift`, mock transport): scan pagination until an empty page; records filtered for missing/invalid GPS; exact progress totals; cached-first emission; equal fingerprint skips the scan (assert zero scan calls); differing fingerprint rescans and replaces the payload; failure after a cached emission keeps the cached records; payload round-trip and schema discard; retention class mapping.

### 4. Map filter registry and page pipeline (`PhotoCache`)

Extend `PhotoCollectionDescriptor` (`Sources/SynologyAPI/PhotoModels.swift`):

```swift
case mapFilter(UUID)

public var mapFilterID: UUID?        // nil for the other cases
public var isMapFilter: Bool
// rawValue: "map:<uuid>"; init?(rawValue:) parses the prefix.
// allCases stays [.personalLibrary, .favorites]; favoriteOnly and
// supportsInitialTimeline stay false; albumID stays nil.
```

New `Sources/PhotoCache/MapFilter.swift`:

```swift
extension CachedPhotosRepository {
    /// Registers a session-only filtered collection. `itemIDsBySection` must be
    /// parallel to `snapshot.sections`.
    public func registerMapFilter(_ descriptor: PhotoCollectionDescriptor,
                                  source: PhotoCollectionDescriptor,
                                  snapshot: TimelineSnapshot,
                                  itemIDsBySection: [[Int64]]) throws

    public func unregisterMapFilter(_ descriptor: PhotoCollectionDescriptor)
}
```

`RepositoryMetadataWork` additions (all released on unregister):

```swift
struct MapFilterState {
    let source: PhotoCollectionDescriptor
    let snapshot: TimelineSnapshot
    let itemIDsBySection: [[Int64]]          // parallel to snapshot.sections
    let idsBySection: [TimelineSection: [Int64]]
}
var mapFilters: [UUID: MapFilterState] = [:]
var mapFilterPages: [String: [PhotoItem]] = [:]   // session LRU, cap 12 pages
var mapFilterPageOrder: [String] = []
```

- `registerMapFilter` validates that the descriptor is `.mapFilter` and that `itemIDsBySection.count == snapshot.sections.count`, stores the state, and also sets `metadata.latestTimelines[descriptor] = snapshot` so `SelectionInfoResolver`'s fingerprint check is meaningful for the filter.
- `page(_:collection:)` gets a branch before the persistent-store path: when `collection.isMapFilter`, use the session pipeline:
  1. Look up the state; if missing, emit `.failure`.
  2. Build the session key with `CacheKey.page(...)` (synthetic sections have date bounds) and emit a session-cached page as `.value(items, verified: true)` when present.
  3. Resolve all Personal Library sections whose date bounds overlap the filtered day. Demand each through `page(_:collection: .personalLibrary)`, collect only registered IDs, and restore the registered order. The underlying pipeline supplies cached-first delivery, shared jobs, validation, persistence, and cancellation.
  4. Mark the filtered result verified and insert it into the session LRU only when every source section is verified and every registered ID was found. `promotePage` promotes the corresponding underlying Personal Library jobs.
- `cachedItem(itemID:section:collection:)` (used by the single-item favorite wrapper) falls back to the session LRU for map filters.
- Favorites compatibility: in `patchAffectedPagesBatch`, treat a map-filter collection like Favorites — patch `.personalLibrary` cached pages by item day (the filter's session pages pick up the change through the favorite-override stream and `LibraryPageWindow.receiveFavorite`). `setFavoritesBatch` itself is unchanged. The viewer favorite path already passes the item, so it works without a store lookup.
- `validationRun(for:)` remains owned by the underlying Personal Library pages; the map-filter branch does not persist session pages.

Tests (`Tests/PhotoCacheTests/MapFilterTests.swift`): registration validation; only Personal Library sections covering the filter day are demanded; split-day sections fan in and registered ID order is preserved; verified and offline cached source pages behave correctly; incomplete results are not verified or session-cached; favorites overrides are applied; the session LRU evicts beyond its cap; unregister clears state; an unknown filter fails; and a filter favorite write patches Personal Library pages.

### 5. Selection info coordinates (`PhotoCache`)

`Sources/PhotoCache/SelectionInfoResolver.swift`:

- Add `public let coordinates: [PhotoCoordinate]` to `SelectionInfo` (located resolved items, in selection order; empty when none).
- `SelectionInfoAccumulator.Contribution` collects coordinates per section, replace/merge on re-emission like the existing counts, and `emit` exposes them. Single-item selections still expose `singleItem` (the panel reads `singleItem.coordinate` directly).
- Keep the existing size/count/failure semantics untouched.

Update `Tests/PhotoCacheTests/SelectionInfoResolverTests.swift`: coordinates accumulate across sections; a section re-emission replaces rather than duplicates its coordinates; unlocated items are skipped; single-item selection yields one coordinate.

### 6. Map model and view (`SynoTimelineApp`)

New `Sources/SynoTimelineApp/MapBrowserModel.swift`:

```swift
@MainActor
final class MapBrowserModel: ObservableObject {
    enum Status: Equatable { case idle, building(scanned: Int, total: Int?), ready, failed(String) }

    @Published private(set) var status: Status = .idle
    @Published private(set) var groups: [MapClusterGroup] = []
    @Published private(set) var locatedCount = 0
    @Published var camera: MapCameraPosition = .automatic
    @Published private(set) var records: [MapPhotoRecord] = []

    func start(repository: CachedPhotosRepository?)        // idempotent
    func cameraChanged(to region: MKCoordinateRegion)      // debounced recluster
    func records(for ids: [Int64]) -> [MapPhotoRecord]     // id lookup for open-filter
    func retry()                                            // re-subscribe after failure
}
```

- Consumes `repository.locationIndex()`. `.cached`/`.completed` set `records`, `locatedCount`, `status = .ready` (or keep `.failed` note alongside cached pins when a later `.failure` arrives); `.progress` updates `status` and must not thrash the map (no recluster until records arrive); on first non-empty records fit the camera to their bounding region (`MKCoordinateRegion` with ~20% padding and a minimum span), afterwards keep the user's region.
- `cameraChanged` debounces ~120 ms, then computes `MapClusterBuilder.groups(records:in:maxAnnotations: 256)` off the main actor (pass the value-type array; 20k records is a few MB and this runs at most a few times per second) and publishes `groups` on the main actor. Cancel any pending computation when a newer region arrives.
- Keep an `[Int64: Int]` id→index map for `records(for:)` so opening a cluster is O(members).
- `retry()` cancels the current subscription and re-subscribes when a failure left no data.

New `Sources/SynoTimelineApp/MapBrowserView.swift`:

- `Map(position: $model.camera)` with one `Annotation` per `MapClusterGroup`; `onMapCameraChange(frequency: .onEnd)` feeds `cameraChanged`. Annotation content:
  - `count == 1`: a rounded-rect thumbnail pin (`.sm` rendition) with a white border and shadow; tap opens that photo.
  - `count > 1`: a circular representative thumbnail with a count badge (bottom-trailing capsule); tap opens the whole group.
- Pin thumbnails reuse `repository.thumbnailWithFallback(record.thumbnail, size: .sm, allowNetwork:)` and `DecodedImages.shared.image(from:maxPixel: 200)`, with the same `.task(id:)`/placeholder pattern as `AlbumCoverView`. `allowNetwork` comes from `model.timelineVerified(for: .personalLibrary)`; offline runs still show cached pins and thumbnails.
- Overlays: while `.building`, a compact glass pill showing a `ProgressView` and "Scanning locations… N of M" (indeterminate when `total == nil`); `.failed` shows a short banner with the cached-pin state and a Retry button; `.ready` with zero records shows `ContentUnavailableView("No located photos", systemImage: "mappin.slash", description: "No photos in Personal Space have location data.")`.
- Callbacks: `onOpenPhoto: (Int64) -> Void` and `onOpenGroup: ([Int64]) -> Void`; accessibility labels ("12 photos at this location", "Photo, July 8 2026").
- The map fills the detail area under the translucent toolbar (`contentTopInset` offsets overlays only).

### 7. Shell wiring (`SynoTimelineApp`)

`Sources/SynoTimelineApp/NavigationRestoration.swift`:

- Add `case map` to `LibraryDestination` (Codable value is stable; keep `currentVersion = 3` — older payloads still decode, and pre-1.0 forward compatibility is not required). Map filter descriptors are never persisted: AppShell passes no restoration anchor for them and ignores their anchor callbacks.

`Sources/SynoTimelineApp/LibraryModel.swift`:

- `func registerSessionCollection(_ collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot)` — writes `snapshots`, bumps `snapshotRevisions`, sets `timelineVerifications[collection] = true`. `load()`/`ensureCollectionLoaded` must never fetch a session descriptor.
- `func unregisterSessionCollection(_ collection:)` — removes the snapshot, verification, and `browserSelectionStates` entry, freeing the UI reference after the repository state is unregistered.
- `func openMapFilter(records: [MapPhotoRecord]) async -> PhotoCollectionDescriptor?`:
  ```swift
  let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
  let built = DayGroupedTimelineBuilder.build(
      entries: records.map { DayTimelineEntry(id: $0.id, time: $0.time) },
      sectionLimit: 250)                       // snappier get batches than the album default
  try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                         snapshot: built.snapshot,
                                         itemIDsBySection: built.itemIDsBySection)
  registerSessionCollection(descriptor, snapshot: built.snapshot)
  return descriptor
  ```
  Returns nil without a repository. The caller unregisters the previous filter first.
- `func closeMapFilter(_ collection:) async` — repository unregister then session unregister.

`Sources/SynoTimelineApp/AppShellView.swift`:

- Sidebar: add `Label("Map", systemImage: "map").tag(LibraryDestination.map)` to the Collections section.
- State: `@StateObject private var mapModel = MapBrowserModel()`, `@State private var openedMapFilter: PhotoCollectionDescriptor?`.
- `selectedCollection`: `.map` maps to `openedMapFilter` (nil means the map overview).
- Detail: when `selectedCollection` is nil and the destination is `.map`, show `MapBrowserView(model: mapModel, contentTopInset: topInset, onOpenPhoto:/onOpenGroup:)`; otherwise the existing `LibraryBrowserView` (map filters pass `restorationAnchor: nil` and a no-op anchor callback).
- `openMapGroup(_ memberIDs: [Int64])`: close any existing filter, gather `mapModel.records(for: memberIDs)`, and set `openedMapFilter` from `model.openMapFilter(records:)`. Single-photo taps pass one ID.
- `closeMapFilter()`: clear via the model and set `openedMapFilter = nil`.
- Toolbar: when browsing a map filter, show a "Map" back button (mirroring "Back to Albums") and a principal title of "N Photos at This Location" / "1 Photo at This Location". Sidebar destination switching keeps `openedMapFilter` (same as albums), so returning to Map shows the filtered browser.
- The info-panel context, viewer opening, viewer close/reveal, and favorites routing all use `selectedCollection` unchanged.

### 8. Info-panel map (`SynoTimelineApp`)

New `Sources/SynoTimelineApp/InfoPanelMapView.swift`:

```swift
struct InfoPanelMapView: View {
    let pins: [InfoPanelPin]        // id + PhotoCoordinate
}
```

- SwiftUI `Map(initialPosition:)` (no user-position binding) at ~150 pt height, clipped to a rounded rectangle; `Marker` per pin. One pin → centered with a ~0.01° span; multiple → bounding region with padding and a minimum span. Pins are non-interactive markers; the panel map pans/zooms normally.
- Hidden entirely when `pins` is empty.

`InfoPanelModel.swift`:

- Add `var pins: [InfoPanelPin] = []` to `InfoPanelContent` and the small `InfoPanelPin: Equatable` struct.
- Single content: `pins` from `item.coordinate`.
- Multiple: `pins` from `SelectionInfo.coordinates`, capped at 500 rendered pins (the count text stays exact).
- Viewer path: same single logic through `updateViewer`.

`InfoPanelView.swift`: insert the map below the metrics/exposure block for single content and below the size row for multiple content when `pins` is non-empty. Keep the combined accessibility labels; add a short "Map with N locations" element.

Tests (`Tests/SynoTimelineAppTests/InfoPanelTests.swift`): single item with/without `gps`; multiple selection coordinates become pins; cap behavior; map hidden with no coordinates.

### 9. Documentation

- `docs/SYNOLOGY_PHOTOS_API.md`: the location/map evidence is being recorded with this plan (see "Confirmed data availability"); keep it current if the implementation discovers differences.
- `docs/ARCHITECTURE.md`: add a "Locations and map" section covering the persisted location index and fingerprint validation, client-side clustering, session `.mapFilter` collections and Personal Library page filtering, and the info-panel pin map.
- `AGENTS.md` "Project overview": extend the current UI-scope and application/cache paragraphs with the Map destination, filtered-location browsing, the location index cache, and the info-panel map.
- `docs/plans/README.md`: add this plan as `WIP_MAP_PLAN.md`; rename to `DONE_MAP_PLAN.md` when implemented.

## Validation

Automated:

- `swift build --build-tests` and `swift test` (all four test targets).
- `Tests/TimelineCoreTests/MapClusteringTests.swift` — as listed in step 1.
- `Tests/SynologyAPITests/PhotoItemTests.swift` — decode `additional.gps` with numbers and string fallbacks, invalid coordinate accessor, encode round trip through the page cache; the changed `PhotosRequestFields.pageAdditional` produces a different `CacheKey.page`.
- `Tests/SynologyAPITests/AlbumTimelineBuilderTests.swift` — adapted to `DayGroupedTimelineBuilder`, including `itemIDsBySection` and the split-day case.
- `Tests/PhotoCacheTests/LocationIndexTests.swift` and `Tests/PhotoCacheTests/MapFilterTests.swift` — as listed in steps 3 and 4.
- `Tests/PhotoCacheTests/SelectionInfoResolverTests.swift` — coordinate accumulation.
- `Tests/SynoTimelineAppTests/InfoPanelTests.swift` — pin construction and hiding.

Manual (run `bash scripts/run.sh`):

- First Map open shows progress while the scan builds the index; pins appear when it completes (or progressively on later opens from cache). Second open is instant and performs no scan when the library is unchanged.
- Zooming out merges nearby pins into clusters with counts; zooming in separates them; a location with one photo shows its thumbnail alone.
- Clicking a cluster and a single photo both open the filtered timeline with the "Map" back button and a correct count title; Back returns to the map with the camera region preserved.
- Inside the filtered timeline: selection clicks/marquee, Space/double-click viewer navigation, `.` favorites (heart badges update), scroll and the day navigator, and the info panel all behave like Personal Library.
- Cmd+I on a located photo shows a pin in the info panel map; a PNG/screenshot without GPS shows no map; a multi-selection shows multiple pins; the viewer follows selection changes.
- Offline start (disable the network): cached pins and thumbnails still render. A matching timeline fingerprint skips the scan; a mismatch attempts validation and leaves the cached pins visible with a refresh warning if the request fails.
- A library with no located photos shows the empty map state.

## Risks, limits, and follow-ups

- **First build cost.** ~20 MB of transfer and roughly 1.5–3 minutes at the measured page latency, running at `.prefetch` priority with two pages in flight. It persists only on completion; cancellation loses progress. It intentionally continues if the map view closes so the next open is instant.
- **Page cache invalidation.** Adding `gps` to `pageAdditional` changes every page cache key once. Old entries become unreferenced and are reclaimed by the existing LRU/budget trimming.
- **Stale filter membership.** A concurrent deletion or a stale location index can leave a registered ID absent from otherwise verified Personal Library pages. That short result is emitted as unverified and is not retained in the session LRU, so later demand can retry instead of making the gap permanent.
- **Identical coordinates never split.** Two photos shot at the exact same location stay one counted cluster at maximum zoom; clicking it still opens both in the filtered timeline.
- **Session-only state.** The map camera, the `.mapFilter` descriptor, and session pages live only for the app run; restoration keeps working for Library/Favorites/Albums and deliberately writes nothing for map filters.
- **Fingerprint validation** catches additions/removals through section-limit changes, not in-place thumbnail/EXIF edits; edited thumbnails may 404 within a run and show a placeholder until the next fingerprint change.
- **Videos and Live Photos** appear with their poster thumbnail and open in the filtered timeline; playback remains unsupported as elsewhere.
- **Longitude wrap** (an antimeridian-spanning region) is not handled by the grid in this iteration; the library does not currently require it.
