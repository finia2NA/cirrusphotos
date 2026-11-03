# Step 3: Stored filter facets and record-based cached discovery

Goal: cached filter discovery reads small scalar facet columns for a whole source collection in one database read, instead of reading every cached day page through `repository.page` (one actor hop, one write transaction and a full `PhotoItem` JSON decode per item). Network scanning is unchanged.

Read `CLAUDE.md`, `docs/PROJECT.md`, `docs/ARCHITECTURE.md`, `docs/decisions/002-grdb-records.md`, `Sources/PhotoCache/CacheSchema.swift`, `Sources/PhotoCache/MetadataStore.swift` and `Sources/PhotoCache/LibraryFilterController.swift` first. Do not commit.

## Hard rules

- No hand-written SQL. Use GRDB records and the query interface only (`filter { ... }`, `fetchAll`, `fetchOne`, `contains`, `order`). No `SQLRequest`, no `db.execute(sql:)`, no `Row` subscripting by string.
- Do not change the meaning of verification. The facet path must produce the same records, the same `verified` flag and the same section state that the current `metadataPage` → `repository.page` → `replace(sectionIndex:items:verified:)` path produces for the same stored data.
- Map-filter and library-filter sources (`sourceCollection.isSessionDerived`) keep the existing page-walk path unchanged.
- Discovery must not update `accessed` (LRU) columns. Only real page reads touch LRU.

## A. Facet columns on `item_details` (`CacheSchema.swift`)

1. Add a value type next to `ItemDetailRecord`:

   ```swift
   /// Scalar filter facets derived from a stored item. Written with every detail row,
   /// so they share its lifetime (eviction, deletion, replacement, reset).
   struct ItemFacets: Codable, Equatable, Sendable {
       var captureTime: Int64        // PhotoItem.time
       var indexedTime: Int64?       // PhotoItem.indexedTime (milliseconds)
       var mediaKind: String         // see mediaKindKey below
       var camera: String?
       var lens: String?
       var fileExtension: String?
       var megapixels: Double?
       var bytes: Int64?
       var iso: Double?
       var focalLength: Double?
       var aperture: Double?
       var exposure: Double?
       enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
           case camera, lens, megapixels, bytes, iso, aperture, exposure
           case captureTime = "capture_time", indexedTime = "indexed_time", mediaKind = "media_kind"
           case fileExtension = "file_extension", focalLength = "focal_length"
       }
       init(_ item: PhotoItem)
       /// Filter values for matching; nil for an unknown stored media kind.
       var values: LibraryFilterValues
   }
   ```

   - `init(_ item:)` builds `let values = LibraryFilterValues(item)` and copies every field from it (`focalLength = values.focalLengthMM`, `exposure = values.exposureSeconds`), plus `captureTime = item.time`, `indexedTime = item.indexedTime`, `mediaKind = Self.mediaKindKey(values.mediaKind)`. Parsing stays only in `LibraryFilterValues`.
   - `mediaKindKey`: `.photo` → `"photo"`, `.video` → `"video"`, `.livePhoto` → `"live"`, `.unknown(let type)` → `"other:" + type`. The `values` property reverses it (`"other:"` prefix → `.unknown(rest)`; anything else unexpected → `.unknown(key)`).
   - Add a memberwise `init(mediaKind:camera:lens:fileExtension:megapixels:bytes:iso:focalLengthMM:aperture:exposureSeconds:)` to `LibraryFilterValues` in `Sources/PhotoCache/LibraryFilter.swift` for `values`.
   - Add `func membershipTime(in collection: PhotoCollectionDescriptor) -> Int64?` that mirrors `PhotoCollectionDescriptor.membershipTime(for:)`: `collection == .recentlyAdded ? indexedTime.map { $0 / 1000 } : captureTime`. Leave a one-line comment pointing at `membershipTime(for:)`.

2. Flatten the facets into `ItemDetailRecord`'s row (not a JSON column):

   ```swift
   struct ItemDetailRecord: Codable, FetchableRecord, PersistableRecord {
       ...
       var payload: PhotoItem { didSet { facets = ItemFacets(payload) } }
       private(set) var facets: ItemFacets
       init(namespace:itemID:payload:contentEpoch:annotationRun:revision:accessed:)   // sets facets = ItemFacets(payload)
       init(from decoder: Decoder) throws      // decode own CodingKeys, then `facets = try ItemFacets(from: decoder)`
       func encode(to encoder: Encoder) throws  // encode own CodingKeys, then `try facets.encode(to: encoder)`
   }
   ```

   GRDB's record encoder and row decoder allow a second keyed container on the same encoder/decoder, so `ItemFacets`' keys become columns of the same row. `CodingKeys` stays as it is (no facet cases). Keep the existing memberwise argument order so current call sites compile.

3. In `CacheSchema.createMetadataTables`, add the facet columns to the `item_details` table. `TableBuilder` is typed to the record's `Columns`, so add a small second builder call or a helper that takes `ItemFacets.CodingKeys`: `capture_time INTEGER NOT NULL`, `media_kind TEXT NOT NULL`, all others nullable (`indexed_time INTEGER`, `camera TEXT`, `lens TEXT`, `file_extension TEXT`, `megapixels REAL`, `bytes INTEGER`, `iso REAL`, `focal_length REAL`, `aperture REAL`, `exposure REAL`). No new indexes.

4. Add a read-only projection of the same table for discovery:

   ```swift
   /// The facet columns of `item_details`, without the payload.
   struct ItemFacetRecord: Decodable, FetchableRecord, TableRecord {
       static let databaseTableName = ItemDetailRecord.databaseTableName
       static var databaseSelection: [any SQLSelectable] {
           [ItemDetailRecord.Columns.itemID, ItemDetailRecord.Columns.contentEpoch, ItemDetailRecord.Columns.annotationRun]
               + ItemFacets.CodingKeys.allCases
       }
       var itemID: Int64
       var contentEpoch: Int64
       var annotationRun: String?
       var facets: ItemFacets
       init(from decoder: Decoder) throws   // itemID/contentEpoch/annotationRun via ItemDetailRecord.CodingKeys, facets via ItemFacets(from: decoder)
   }
   ```

   Filtering uses `ItemDetailRecord.Columns` (e.g. `ItemFacetRecord.filter(ItemDetailRecord.Columns.namespace == key)`).

5. Bump `metadataFormatVersion` in `MetadataStore.swift` from 5 to 6 (metadata rebuilds; media is kept).

6. Every place that changes `payload` already goes through `ItemDetailRecord`; `didSet` keeps facets current in `patchMetadataDetail` (`detail.update(db)` writes all columns). Check every `ItemDetailRecord` write in `MetadataStore.swift` and `DiskCache.swift`: the ones that update only `contentEpoch` (`update(db, columns: [...contentEpoch])`) need no change. If any code writes `payload` with `update(db, columns:)` listing only `payload`, add the facet columns there.

## B. Facet read (`MetadataStore.swift`)

Add, in `extension DiskCache`:

```swift
/// One stored day page of a collection, reduced to filter facets.
struct MetadataFilterPage: Sendable {
    let address: DayPageAddress
    /// Members with stored details, in ordinal order. Members without details are omitted.
    let entries: [MetadataFilterEntry]
    let verified: Bool
}
struct MetadataFilterEntry: Sendable {
    let ordinal: Int
    let itemID: Int64
    let time: Int64?          // ItemFacets.membershipTime(in: collection)
    let values: LibraryFilterValues
}

func metadataFilterPages(_ namespace: MetadataNamespace, collection: PhotoCollectionDescriptor,
                         days: Set<CaptureDay>?, currentRun: String) throws -> [MetadataFilterPage]
```

Implementation, one `database.read { db in ... }`, return `[]` when `!metadataInitialized`:

1. `state = try metadataState(db, namespace)`.
2. Fetch for `namespace.key` and `collection.rawValue` (add `day` filter `dayIDs.contains($0.day)` when `days` is non-nil, with `dayIDs = days.map(\.id)`):
   - `DayPageRecord`s,
   - `PageItemRecord`s,
   - `CollectionDayRecord`s (key them by `day`).
3. Facets: when `days == nil`, fetch all `ItemFacetRecord`s of the namespace in one query; otherwise fetch them for the member ids in batches of 500 (same pattern as `itemDetails`). Key by `itemID`.
4. Group `PageItemRecord`s by page key `(day, pageOffset, capacity, sortOrder)` (a private `Hashable` struct). For each `DayPageRecord`:
   - Build `DayPageAddress(collection:day:offset:capacity:order:)` with `CaptureDay` parsed from `page.day` and `CollectionOrder(rawValue: page.sortOrder)`; skip the page if either fails or the init throws. `CaptureDay` has no init from its `id` (`"YYYY-MM-DD"`); add `init?(id: String)` in `Sources/SynologyAPI/CollectionDayCatalog.swift` that splits on `-`, parses three integers and calls `try? init(year:month:day:)`, returning nil on any failure.
   - Skip the page if `actualCount <= 0`, `actualCount > capacity`, `revision < 0`, members sorted by ordinal are not exactly `0..<actualCount`, or a facet row's `itemID` differs from its member's. These are the cases where `metadataPage` throws `CacheError.storage`; skipping keeps one bad page from failing the whole discovery.
   - Compute exactly as `metadataPage` does:
     - `membershipVerified = page.validatedRun == currentRun && page.epoch == state.resetEpoch && day?.membershipGeneration == page.dayGeneration && day?.itemCount == page.dayCount`
     - for each member with facets: if `facets.membershipTime(in: collection).flatMap { try? CaptureDay(time: $0) } != address.day` then `membershipVerified = false`; `detailVerified = facets.contentEpoch == state.resetEpoch && facets.annotationRun == currentRun`.
     - `verified = membershipVerified && every member has facets && every detailVerified` (this equals `PhotoPageSnapshot.verified`, which requires non-empty slots that are all verified; a slot without detail is unverified).
   - Entries: members with facets, `time = facets.membershipTime(in: collection)`, `values = facets.values`.
5. Return pages sorted by `(day descending, pageOffset ascending)`.

Do not touch `accessed` anywhere in this function.

## C. Repository pass-through (`Sources/PhotoCache/CachedPhotosRepository+Metadata.swift`)

```swift
/// Cached filter facets of a stored (non-session-derived) collection, or nil when the
/// metadata engine was reset or the collection mutated while reading.
func cachedFilterPages(collection: PhotoCollectionDescriptor, days: Set<CaptureDay>?) async throws -> [MetadataFilterPage]?
```

Mirror the cached branch of `page(_:collection:...)`:

1. `try await initializeMetadataEngine()`.
2. Capture `epoch = metadata.admissionEpoch` and `mutationEpoch = metadata.mutationEpochs[collection, default: 0]`.
3. `let pages = try await store.metadataFilterPages(metadataNamespace(for: collection), collection: collection, days: days, currentRun: runID)`.
4. If `!isAdmitted(epoch)` or the mutation epoch changed, return `nil`.
5. Compute `mutationInProgress` with the same expression used in `page(...)`; extract that expression into a private helper `func collectionMutationInProgress(_ collection:) -> Bool` and use it in `timeline`, `page` and here. When true, return the pages with `verified: false`.

Favorite overrides do not matter here: no filter criterion uses favorites.

## D. Controller (`Sources/PhotoCache/LibraryFilterController.swift`)

1. Split `replace(sectionIndex:items:verified:)`:
   - `replace(sectionIndex:records:verified:) -> Bool` holds the existing body after records are built (downgrade guard, equality check, state, failure cleanup, revision, catalog write).
   - `replace(sectionIndex:items:verified:)` builds records exactly as now and calls it.
2. Add `private lazy var` (or init-built `let`) `sectionIndexByAddress: [DayPageAddress: Int]` from `sourceSnapshot.sections` via `try? DayPageAddress(section:collection: sourceCollection)`. Build it in `init` as a `let` for actor simplicity.
3. Add `private func applyCachedFilterPages(_ pages: [MetadataFilterPage]) -> Bool` that, for each page whose address is in `sectionIndexByAddress`, builds records

   ```swift
   LibraryFilterRecord(reference: .init(sourceSectionIndex: index, sourcePageOffset: entry.ordinal,
                                        itemID: entry.itemID, sourceVerified: page.verified),
                       time: time, values: entry.values)
   ```

   skipping entries whose `time` is nil (same as `replace(items:)`), and calls `replace(sectionIndex:records:verified: page.verified)`. Returns whether anything changed. Pages not in the snapshot are ignored (keeps `testCacheDiscoveryIgnoresPageOutsideCurrentTimeline` valid).
4. `discoverCachedPages()`: when `!sourceCollection.isSessionDerived`, replace the batched `read(...)` loop with

   ```swift
   if let pages = try? await repository.cachedFilterPages(collection: sourceCollection, days: nil) {
       guard !stopped, !Task.isCancelled else { return }
       if applyCachedFilterPages(pages) { publish() }
   }
   ```

   then fall through to the existing completion code. Session-derived sources keep the existing loop (move it into a private `discoverCachedPagesByReading()` helper so both branches stay readable).
5. `receiveCachedPages(_:)`: for non-session-derived sources, compute the days of the changed sections (`CaptureDay(year:month:day:)` from `section.list.first`), call `cachedFilterPages(collection:days:)`, and apply only pages whose address maps to one of the changed section indices. Session-derived sources keep the current loop.
6. `cacheReadBatchSize` stays for the session-derived path.

## E. Tests

`Tests/PhotoCacheTests/MetadataStoreTests.swift` (follow the file's existing fixtures for storing pages and items):

- `testFacetColumnsMatchFilterValues`: store a full page with a photo carrying EXIF (camera, lens, ISO `"100"`, aperture `"f/2.8"`, exposure `"1/250"`, resolution, filesize, filename `x.jpg`) and a video. `metadataFilterPages` returns entries whose `values == LibraryFilterValues(item)` for both.
- `testFacetsFollowFavoriteAndRotationPatches`: after `applyMetadataRotationValues` with a replacement that changes resolution, the entry's `values.megapixels` reflects the replacement.
- `testEvictedDetailLeavesPageUnverifiedWithoutEntry`: after `evictMetadataDetails` for one item, the page is returned with that entry missing and `verified == false`, while `metadataPage` still reports the slot.
- `testFilterPageVerificationMatchesMetadataPage`: for a page stored in the current run, `verified == metadataPage(...).verified == true`; after `invalidateMetadataCollection` (or the existing invalidation API used in tests) both are false; with a different `currentRun` both are false.
- `testDetailRecordRoundTripsFacets`: insert an `ItemDetailRecord`, fetch it back, `facets == ItemFacets(payload)`; fetch `ItemFacetRecord` and compare.

`Tests/PhotoCacheTests/LibraryFilterControllerTests.swift`: all existing tests must pass unchanged. Add `testCacheDiscoveryOfManyPagesUsesNoTransport`: seed 300 single-item cached sections with alternating cameras, `indexCachedPages()`, assert the match count for one camera is 150 and `transport.totalCalls() == 0`.

Run `swift build` and the full `swift test`. Report counts and any failure output.

## F. Docs

- `docs/ARCHITECTURE.md`, metadata filtering paragraph: cached discovery reads the scalar facet columns stored on `item_details` (same lifetime as details) for the whole source collection in one read and applies the same verification as page reads; Map and filter-derived sources still read pages; the network scan is unchanged.
- `docs/decisions/002-grdb-records.md` needs no change.

## Done when

- `swift build` and `swift test` pass.
- No raw SQL was added (`grep -n "sql:" Sources/PhotoCache` shows only the pre-existing pragma/marker/introspection calls).
- A summary lists changed files and any deviation from this plan with the reason.
