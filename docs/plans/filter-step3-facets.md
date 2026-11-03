# Step 3: Stored filter facets and single-query cached discovery

> Needs revision before use: storage now uses GRDB records (`Sources/PhotoCache/CacheSchema.swift`, decision 002). Facet columns belong on `ItemDetailRecord`, and the discovery query below should be expressed with records and the query interface, not raw SQL. `item_details` no longer has a `cost` column, and the summary tables are one `collection_summaries` table.

Goal: make the filter's cached discovery one SQL query over scalar columns instead of decoding every cached page's JSON items. This also stores a lowercased filename for the later filename search (issue #13). Builds on step 1 (batched scan, cache-only availability) and step 2 (GRDB `DatabaseQueue` in `DiskCache`, helpers take `Database`).

Read `CLAUDE.md`, `docs/PROJECT.md`, `docs/ARCHITECTURE.md`, and the step 2 code in `Sources/PhotoCache/MetadataStore.swift` first. Do not commit.

## Design

- Facets are columns on `item_details`, written in the same statement as the payload. They have exactly the detail's lifetime: eviction, deletion, Diff replacement and reset remove or rewrite them together, so no new consistency rules are needed.
- In-memory filtering stays. At ~60k items, matching scalar records in memory takes milliseconds. The cost being removed is the page walk (JSON decoding, per-page reads and rebuilds), not the comparison. No per-criterion SQL predicates and no extra indexes in this step.
- Discovery returns the same `LibraryFilterRecord`s that `replace(sectionIndex:items:verified:)` builds today, so registrations, browser pages, the network scan and tests keep their contracts.

## A. Schema (`MetadataStore.swift`)

1. Bump `metadataFormatVersion` from 4 to 5 (discards normalized metadata on first launch; media is kept, as the format-change rule requires).
2. Add columns to `item_details` (after the existing ones):
   `filename_lower TEXT, media_kind TEXT NOT NULL, camera TEXT, lens TEXT, file_extension TEXT, megapixels REAL, bytes INTEGER, iso REAL, focal_length REAL, aperture REAL, exposure REAL, indexed_time INTEGER`.
   `indexed_time` is `PhotoItem.indexedTime` (milliseconds), needed because `PhotoCollectionDescriptor.membershipTime(for:)` uses it for `.recentlyAdded`.
3. Every write of `item_details` must set these columns from the stored `PhotoItem`:
   - The `INSERT OR REPLACE INTO item_details` in `storeMetadataItem` (full profile).
   - `patchMetadataDetail` (favorite and rotation patches): recompute all facet columns from the transformed item in the same `UPDATE`.
   Compute values with a single helper `static func facetArguments(_ item: PhotoItem) -> [DatabaseValueConvertible?]` in `MetadataStore.swift` built on `LibraryFilterValues(item)` (`Sources/PhotoCache/LibraryFilter.swift`) so parsing lives in one place. `media_kind` stores `PhotoMediaKind`'s raw value (check its definition; add `String` raw values if it has none). `filename_lower` is `item.filename?.lowercased()`.

## B. Facet read (`MetadataStore.swift`)

Add to `extension DiskCache`:

```swift
struct MetadataFilterFacetRow: Sendable {
    let day: String; let pageOffset: Int; let ordinal: Int; let itemID: Int64
    let captureTime: Int64; let indexedTime: Int64?
    let values: LibraryFilterValues
    let verified: Bool
}
public func metadataFilterFacets(_ namespace: MetadataNamespace, collection: PhotoCollectionDescriptor,
                                 capacity: Int, order: String, days: Set<String>?, currentRun: String) throws -> [MetadataFilterFacetRow]
```

One `db.read` with:

```sql
SELECT p.day, p.page_offset, p.ordinal, p.item_id, i.capture_time, d.indexed_time,
       d.media_kind, d.camera, d.lens, d.file_extension, d.megapixels, d.bytes, d.iso, d.focal_length, d.aperture, d.exposure,
       (pg.validated_run=?1 AND pg.epoch=?2 AND cd.membership_generation=pg.day_generation AND cd.item_count=pg.day_count) AS membership_ok,
       (d.content_epoch=?2 AND d.annotation_run=?1) AS detail_ok
FROM page_items p
JOIN day_pages pg ON pg.namespace=p.namespace AND pg.collection=p.collection AND pg.day=p.day
     AND pg.page_offset=p.page_offset AND pg.capacity=p.capacity AND pg.sort_order=p.sort_order
JOIN item_details d ON d.namespace=p.namespace AND d.item_id=p.item_id
JOIN item_index i ON i.namespace=p.namespace AND i.item_id=p.item_id
LEFT JOIN collection_days cd ON cd.namespace=p.namespace AND cd.collection=p.collection AND cd.day=p.day
WHERE p.namespace=?3 AND p.collection=?4 AND p.capacity=?5 AND p.sort_order=?6
ORDER BY p.day DESC, p.page_offset, p.ordinal
```

- `?1` current run, `?2` the namespace's `resetEpoch` from `metadata_state`, `?3`–`?6` namespace key, collection raw value, capacity, sort order. When `days` is non-nil, add `AND p.day IN (...)` (batch the list in chunks of 500 if needed).
- `verified = membership_ok && detail_ok` (NULLs → false). This mirrors `metadataPage`'s verification after the step 2 change (D1). Check the exact `metadataPage` logic after step 2 and match it; if anything differs, follow `metadataPage`.
- Add a memberwise `init` to `LibraryFilterValues` so rows can be built without a `PhotoItem` (`mediaKind` from raw value; unknown raw value → skip the row).
- `CaptureDay.id` is the `day` text format; reuse it when mapping.

## C. Controller (`Sources/PhotoCache/LibraryFilterController.swift`)

1. Add a repository pass-through (in `CachedPhotosRepository+Metadata.swift` or next to `page(...)`): `func cachedFilterFacets(collection:days:) async throws -> [MetadataFilterFacetRow]` that resolves `metadataNamespace(for:)`, `DayPageAddress` capacity/order for the collection (derive from `DayPageAddress(section:collection:)` of the first snapshot section, or the constants it uses), the current `runID`, and calls `store.metadataFilterFacets`. Keep it `internal`.
2. `discoverCachedPages()`: when `!sourceCollection.isMapFilter`, replace the batched `read(...)` page walk with one `cachedFilterFacets(collection: sourceCollection, days: nil)` call:
   - Build `sectionIndexByAddress: [String /*day id*/ + ":" + offset → Int]` from `sourceSnapshot.sections` (one entry per section; use `DayPageAddress(section:collection:)` to get day and offset). Rows whose address is not in the snapshot are ignored (keeps `testCacheDiscoveryIgnoresPageOutsideCurrentTimeline` valid).
   - Group rows by section index. For each section, a section counts as present only if its row count equals the section's `limit` (all slots have details); otherwise use the rows present (sparse is fine; records are per item) but mark the section `.provisional`.
   - Build `LibraryFilterRecord(reference: .init(sourceSectionIndex:, sourcePageOffset: row.ordinal, itemID:, sourceVerified: row.verified), time: membershipTime, values: row.values)` where `membershipTime` is `indexedTime / 1000` for `.recentlyAdded`, else `captureTime`; skip rows whose membership time's `CaptureDay` differs from the section's day (same check as `metadataPage`).
   - Section state: `.verified` if every row in a complete section is verified, else `.provisional`. Respect the existing rule that a provisional result never downgrades a `.verified` section.
   - Set `recordsBySection`, invalidate caches, `revision &+= 1`, then continue with the existing completion code (`cacheDiscoveryComplete = true`, catalog persist, publish once).
   - Map-filter sources keep the existing page-walk path unchanged.
3. `receiveCachedPages(_:)` (page-commit observer): for non-Map sources, call `cachedFilterFacets(collection:days:)` with the days of the changed sections and apply the same mapping for those sections only. Map sources keep the current path.
4. Network scan emissions (`receiveScanEmission`, `scan`) keep building records from `PhotoItem`s via `LibraryFilterValues(item)`; unchanged.
5. Factor the row-to-record mapping into one private function used by 2 and 3.

## D. Tests

- `Tests/PhotoCacheTests/MetadataStoreTests.swift`:
  - Facet columns are written on page store and match `LibraryFilterValues` for an item with EXIF (camera, lens, ISO "100", aperture "f/2.8", exposure "1/250", resolution) and for a video.
  - `applyMetadataFavoriteValues` and `applyMetadataRotationValues` keep facet columns consistent (re-read via `metadataFilterFacets`).
  - Evicted details disappear from `metadataFilterFacets`, while `metadataPage` still reports the slot.
  - Verification flags: a page stored in the current run is verified; after `invalidateMetadataCollection` it is not.
- `Tests/PhotoCacheTests/LibraryFilterControllerTests.swift`: all existing discovery tests must pass. Add `testCacheDiscoveryUsesFacetQueryWithoutPageReads` if there is a practical seam (e.g. count `repository.page` calls via a test hook); otherwise assert discovery of 300 cached sections completes with correct match counts and zero transport requests.
- Run `swift build` and full `swift test`.

## E. Docs

- `docs/ARCHITECTURE.md`, metadata filtering paragraph: cached discovery reads stored filter facet columns of `item_details` (same lifetime as details) with one query per source collection, ordered by source page; Map sources still read pages; network scan unchanged. Mention `filename_lower` is stored for filename search.
- No `docs/PROJECT.md` change needed unless behavior visibly changes.

## Done when

- `swift build` and `swift test` pass; report results with counts and any failure output.
- Summary of changed files and deviations.
