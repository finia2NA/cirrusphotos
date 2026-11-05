import Foundation
import SQLite3
import GRDB
import XCTest
import SynologyAPI
@testable import PhotoCache

final class MetadataStoreTests: XCTestCase, @unchecked Sendable {
    private let namespace = MetadataNamespace(account: "fixture-account", scope: .space(.personal))
    private func item(_ id: Int64, day: CaptureDay) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(day.startTime),\"type\":\"photo\",\"filename\":\"fixture.jpg\",\"additional\":{\"favorite\":true}}".utf8))
    }
    private func open() async throws -> (DiskCache, URL) {
        let root = temporaryTestRoot("normalized-store")
        let store = try DiskCache(root: root, budget: 10_000_000)
        try await store.initializeMetadataStore()
        return (store, root)
    }
    private func seed(_ store: DiskCache, collection: PhotoCollectionDescriptor = .library(.personal)) async throws -> DayPageRead {
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let catalog = try CollectionDayCatalog(days: [.init(day: day, count: 3)], completeness: .complete)
        let admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog, key: .init(namespace: namespace, collection: collection), validatedRun: "run", admission: admission)
        let page = try DayPageRead(address: .init(collection: collection, day: day, offset: 0), dayCount: 3, membershipGeneration: 1)
        try await store.storeMetadataPage(page, items: [item(1, day: day), item(2, day: day), item(3, day: day)], profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
        return page
    }
    func testNormalizedWritesAutomaticallyEnforceBudgetAndRetireInventoryProof() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let catalogCost = try JSONEncoder().encode(CollectionDayCatalog(days: [.init(day: page.address.day, count: 3)], completeness: .complete)).count + 128
        try await store.setBudget(Int64(catalogCost + 100))
        let admission = try await store.metadataAdmission(namespace)
        let rows = try [item(1, day: page.address.day), item(2, day: page.address.day), item(3, day: page.address.day)]
        try await store.storeMetadataPage(page, items: rows, profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
        let usage = try await store.usage()
        XCTAssertLessThanOrEqual(usage, Int64(catalogCost + 100))
        let job = UUID()
        try await store.stageMetadataInventory(rows, job: job, namespace: namespace, admission: admission)
        let catalog = try CollectionDayCatalog(days: [.init(day: page.address.day, count: 3)], completeness: .complete)
        try await store.commitMetadataInventory(job, namespace: namespace, catalog: catalog, cursor: nil, admission: admission)
        let state = try await store.metadataState(namespace)
        XCTAssertFalse(state.inventoryComplete, "Trimming the committed inventory must retire completeness")
    }
    func testSparseEvictionNeverCompactsOrdinalsOrOtherCollections() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let favorites = try await seed(store, collection: .favorites(.personal))
        let full = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(full?.slots.map(\.itemID), [1, 2, 3])
        XCTAssertEqual(full?.verified, true)
        let before = try await store.metadataStorageCost()
        try await store.evictMetadataDetails(namespace: namespace, itemIDs: [1])
        let sparse = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertNil(sparse?.slots[0].item)
        XCTAssertEqual(sparse?.slots[1].item?.id, 2)
        XCTAssertEqual(sparse?.membershipVerified, true)
        XCTAssertEqual(sparse?.verified, false)
        let other = try await store.metadataPage(favorites.address, namespace: namespace, currentRun: "run")
        XCTAssertNil(other?.slots[0].item)
        XCTAssertEqual(other?.slots[2].item?.id, 3)
        let after = try await store.metadataStorageCost()
        XCTAssertLessThan(after, before)
    }
    /// Eviction subtracts the cost it removed from the usage estimate. That cost must be
    /// the same quantity the full scan sums, including for non-ASCII text.
    func testMetadataEvictionKeepsUsageEstimateEqualToFreshScan() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let rows = try (1...6).map { id -> PhotoItem in
            try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(day.startTime),\"type\":\"photo\",\"filename\":\"Zürich 東京 \(id).jpg\",\"additional\":{\"favorite\":true,\"gps\":{\"latitude\":47.37,\"longitude\":8.54}}}".utf8))
        }
        let admission = try await store.metadataAdmission(namespace)
        for collection in [PhotoCollectionDescriptor.library(.personal), .favorites(.personal)] {
            let catalog = try CollectionDayCatalog(days: [.init(day: day, count: rows.count)], completeness: .complete)
            try await store.storeMetadataCatalog(catalog, key: .init(namespace: namespace, collection: collection), validatedRun: "run", admission: admission)
            let page = try DayPageRead(address: .init(collection: collection, day: day, offset: 0), dayCount: rows.count, membershipGeneration: 1)
            try await store.storeMetadataPage(page, items: rows, profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
        }
        var limit = try await store.usage()
        XCTAssertGreaterThan(limit, 0)
        while limit > 0 {
            limit = limit * 3 / 4
            try await store.setBudget(limit)
            let estimate = await store.estimatedUsage
            let fresh = try await store.usage()
            XCTAssertEqual(estimate, fresh, "estimate drifted from a fresh scan at budget \(limit)")
        }
        let remaining = try await store.usage()
        XCTAssertEqual(remaining, 0)
    }
    func testCatalogPresentationDoesNotDirtyUnrelatedDay() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let newDay = try CaptureDay(year: 2024, month: 1, day: 2)
        let key = CollectionKey(namespace: namespace, collection: .library(.personal))
        let catalog = try CollectionDayCatalog(days: [.init(day: page.address.day, count: 3), .init(day: newDay, count: 2)], completeness: .complete)
        try await store.storeMetadataCatalog(catalog, key: key, validatedRun: "run", admission: store.metadataAdmission(namespace))
        let retained = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(retained?.verified, true)
        let stored = try await store.metadataCatalog(key)
        XCTAssertEqual(stored?.presentationRevision, 2)
        let changed = try CollectionDayCatalog(days: [.init(day: page.address.day, count: 4)], completeness: .complete)
        try await store.storeMetadataCatalog(changed, key: key, validatedRun: "run", admission: store.metadataAdmission(namespace))
        let dirty = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(dirty?.membershipVerified, false)
        XCTAssertEqual(dirty?.slots.count, 3)
    }
    func testPartialProfilePreservesFullDetailsAndCannotGrantAnnotationAuthority() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let admission = try await store.metadataAdmission(namespace)
        let partial = try [item(1, day: page.address.day), item(2, day: page.address.day), item(3, day: page.address.day)]
        try await store.storeMetadataPage(page, items: partial, profile: .identityAndTime, namespace: namespace, currentRun: "next-run", admission: admission)
        let snapshot = try await store.metadataPage(page.address, namespace: namespace, currentRun: "next-run")
        XCTAssertEqual(snapshot?.membershipVerified, true)
        XCTAssertEqual(snapshot?.slots[0].item?.filename, "fixture.jpg")
        XCTAssertEqual(snapshot?.slots[0].verified, false)
    }
    func testMetadataAdmissionRejectsAnotherNamespaceWithMatchingCounters() async throws {
        let root = temporaryTestRoot("admission-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiskCache(root: root, budget: 10_000_000)
        try await store.initializeMetadataStore()
        let personal = MetadataNamespace(account: "test", scope: .space(.personal))
        let shared = MetadataNamespace(account: "test", scope: .space(.shared))
        let admission = try await store.metadataAdmission(personal)
        let sharedAdmission = try await store.metadataAdmission(shared)
        XCTAssertEqual(admission.revision, sharedAdmission.revision)
        XCTAssertEqual(admission.resetEpoch, sharedAdmission.resetEpoch)
        do {
            try await store.storeMetadataCollectionIndex(.person, [], namespace: shared, currentRun: "run", admission: admission)
            XCTFail("A token from another namespace must not authorize this write")
        } catch MetadataAdmissionError.superseded { }
        do {
            try await store.applyMetadataFavoriteValues([1: true], namespace: shared, currentRun: "run", admission: admission)
            XCTFail("Mutation patches must also reject tokens from another namespace")
        } catch MetadataAdmissionError.superseded { }
        let cached = try await store.metadataCollectionIndex(.person, namespace: shared)
        XCTAssertNil(cached)
    }

    func testMetadataAdmissionRejectsLateResetWriter() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let old = try await store.metadataAdmission(namespace)
        _ = try await store.clearMetadata()
        do {
            try await store.storeMetadataPage(page, items: [item(1, day: page.address.day), item(2, day: page.address.day), item(3, day: page.address.day)], profile: .fullPage, namespace: namespace, currentRun: "run", admission: old)
            XCTFail("Reset writer was admitted")
        } catch { }
    }
    func testNamespaceIsolation() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let missing = try await store.metadataPage(page.address, namespace: .init(account: "other", scope: .space(.personal)), currentRun: "run")
        XCTAssertNil(missing)
    }
    func testSourceCursorAndDayInvalidationAreAtomicAndEmptyCannotReviveResetRows() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let first = DiffCursor(diffVersion: 1, versionTime: 1)
        try await store.applyMetadataChanges(namespace: namespace, cursor: first, replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: true,
                                             currentRun: "run", admission: store.metadataAdmission(namespace))
        let invalidated = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(invalidated?.membershipVerified, false)
        let next = DiffCursor(diffVersion: 2, versionTime: 2)
        try await store.applyMetadataChanges(namespace: namespace, cursor: next, replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: false,
                                             currentRun: "run", admission: store.metadataAdmission(namespace))
        let stillDirty = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(stillDirty?.membershipVerified, false)
        let state = try await store.metadataState(namespace)
        XCTAssertEqual(state.cursor, next)
        XCTAssertEqual(state.resetEpoch, 1)
        XCTAssertEqual(state.revision, 1)
    }
    func testSourceCommitRollbackKeepsOldCursorAndDayVersions() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TRIGGER reject_checkpoint BEFORE INSERT ON metadata_state BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        do {
            try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [], affectedDays: [page.address.day], invalidateAll: true,
                                                 currentRun: "run", admission: store.metadataAdmission(namespace))
            XCTFail("Injected commit failure succeeded")
        } catch { }
        let state = try await store.metadataState(namespace)
        XCTAssertNil(state.cursor)
        let retained = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(retained?.verified, true)
    }
    func testResetThenIdentityReadCannotPromoteOldGPS() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let located = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":\(page.address.day.startTime),\"type\":\"photo\",\"additional\":{\"gps\":{\"latitude\":12.5,\"longitude\":40.5}}}".utf8))
        try await store.storeMetadataPage(page, items: [located, item(2, day: page.address.day), item(3, day: page.address.day)], profile: .fullPage, namespace: namespace, currentRun: "run", admission: store.metadataAdmission(namespace))
        let before = try await store.metadataCurrentLocations(namespace)
        XCTAssertEqual(before.count, 1)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: true,
                                             currentRun: "run", admission: store.metadataAdmission(namespace))
        let refreshed = try DayPageRead(address: page.address, dayCount: 3, membershipGeneration: 2)
        try await store.storeMetadataPage(refreshed, items: [item(1, day: page.address.day), item(2, day: page.address.day), item(3, day: page.address.day)], profile: .identityAndTime, namespace: namespace, currentRun: "run", admission: store.metadataAdmission(namespace))
        let after = try await store.metadataCurrentLocations(namespace)
        XCTAssertTrue(after.isEmpty)
        let cached = try await store.metadataInventory(namespace)
        XCTAssertNotNil(cached.first { $0.id == 1 }?.coordinate)
        let snapshot = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(snapshot?.slots[0].verified, false)
    }

    func testPageReadsTouchCanonicalAndMembershipLRUBeforeEviction() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDay = try CaptureDay(year: 2024, month: 1, day: 1)
        let secondDay = try CaptureDay(year: 2024, month: 1, day: 2)
        let catalog = try CollectionDayCatalog(days: [.init(day: firstDay, count: 1), .init(day: secondDay, count: 1)], completeness: .complete)
        let admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog, key: .init(namespace: namespace, collection: .library(.personal)), validatedRun: "run", admission: admission)
        let first = try DayPageRead(address: .init(collection: .library(.personal), day: firstDay, offset: 0), dayCount: 1, membershipGeneration: 1)
        let second = try DayPageRead(address: .init(collection: .library(.personal), day: secondDay, offset: 0), dayCount: 1, membershipGeneration: 1)
        try await store.storeMetadataPage(first, items: [item(1, day: firstDay)], profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
        try await Task.sleep(for: .milliseconds(10))
        try await store.storeMetadataPage(second, items: [item(2, day: secondDay)], profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
        try await Task.sleep(for: .milliseconds(10))
        _ = try await store.metadataPage(first.address, namespace: namespace, currentRun: "run")
        let usage = try await store.usage()
        try await store.setBudget(usage - 1)
        let hot = try await store.metadataPage(first.address, namespace: namespace, currentRun: "run")
        let cold = try await store.metadataPage(second.address, namespace: namespace, currentRun: "run")
        XCTAssertNotNil(hot?.slots.first?.item)
        XCTAssertNil(cold?.slots.first?.item)
        XCTAssertEqual(cold?.slots.first?.itemID, 2)
    }
    func testResetRowsDoNotSupplyCurrentIdentityEvidenceUntilReread() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await seed(store)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: true, currentRun: "run", admission: store.metadataAdmission(namespace))
        let old = try await store.metadataItemTimes(namespace, ids: [1, 2, 3])
        XCTAssertTrue(old.isEmpty)
        let cached = try await store.metadataInventory(namespace)
        XCTAssertEqual(cached.count, 3)
    }

    func testRotationPatchesOnlyOwnedFieldsAndCompactThumbnail() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let original = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"time":\(page.address.day.startTime),"type":"photo","additional":{"favorite":true,"gps":{"latitude":35,"longitude":139},"exif":{"camera":"Camera"},"thumbnail":{"unit_id":1,"cache_key":"old"}}}
        """.utf8))
        let replacement = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"time":\(page.address.day.startTime),"type":"photo","additional":{"favorite":false,"orientation":6,"thumbnail":{"unit_id":1,"cache_key":"new"}}}
        """.utf8))
        _ = try await store.storeMetadataDetails([original], namespace: namespace, currentRun: "run", admission: store.metadataAdmission(namespace))
        try await store.applyMetadataRotationValues([1: replacement], namespace: namespace, admission: store.metadataAdmission(namespace))
        let details = try await store.metadataDetails(namespace, ids: [1], currentRun: "run")
        XCTAssertEqual(details[1]?.item?.isFavorite, true)
        XCTAssertEqual(details[1]?.item?.coordinate, original.coordinate)
        XCTAssertEqual(details[1]?.item?.additional?.exif, original.additional?.exif)
        XCTAssertEqual(details[1]?.item?.additional?.orientation, 6)
        let projection = try await store.metadataCachedLocations(namespace)
        XCTAssertEqual(projection.first?.thumbnail?.cacheKey, "new")
        XCTAssertEqual(projection.first?.coordinate, original.coordinate)
    }
    func testIdentityTimeChangeRetiresCompleteInventory() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let catalog = try CollectionDayCatalog(days: [.init(day: page.address.day, count: 3)], completeness: .complete)
        let job = UUID()
        let admission = try await store.metadataAdmission(namespace)
        try await store.stageMetadataInventory([item(1, day: page.address.day), item(2, day: page.address.day), item(3, day: page.address.day)], job: job, namespace: namespace, admission: admission)
        try await store.commitMetadataInventory(job, namespace: namespace, catalog: catalog, cursor: nil, admission: admission)
        let complete = try await store.metadataState(namespace)
        XCTAssertTrue(complete.inventoryComplete)
        try await store.storeMetadataIdentityPage(page, entries: [DayTimelineEntry(id: 1, time: page.address.day.startTime + 1), DayTimelineEntry(id: 2, time: page.address.day.startTime), DayTimelineEntry(id: 3, time: page.address.day.startTime)], namespace: namespace, currentRun: "run", admission: store.metadataAdmission(namespace))
        let changed = try await store.metadataState(namespace)
        XCTAssertFalse(changed.inventoryComplete)
    }


    // MARK: Filter facets

    private func exifItem(_ id: Int64, day: CaptureDay, type: String = "photo", filename: String = "x.jpg", width: Int = 4000) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"time":\(day.startTime),"type":"\(type)","filename":"\(filename)","filesize":2048,
         "additional":{"resolution":{"width":\(width),"height":3000},
         "exif":{"camera":"Canon R5","lens":"RF 50mm","iso":"100","aperture":"f/2.8","exposure_time":"1/250","focal_length":"50 mm"}}}
        """.utf8))
    }
    private func seedFacetPage(_ store: DiskCache) async throws -> (DayPageRead, [PhotoItem]) {
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let catalog = try CollectionDayCatalog(days: [.init(day: day, count: 2)], completeness: .complete)
        let admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog, key: .init(namespace: namespace, collection: .library(.personal)), validatedRun: "run", admission: admission)
        let page = try DayPageRead(address: .init(collection: .library(.personal), day: day, offset: 0), dayCount: 2, membershipGeneration: 1)
        let items = [try exifItem(1, day: day), try exifItem(2, day: day, type: "video", filename: "clip.mov")]
        try await store.storeMetadataPage(page, items: items, profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
        return (page, items)
    }

    func testFacetColumnsMatchFilterValues() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let (page, items) = try await seedFacetPage(store)
        let pages = try await store.metadataFilterPages(namespace, collection: .library(.personal), days: nil, currentRun: "run")
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].address, page.address)
        XCTAssertEqual(pages[0].entries.map(\.ordinal), [0, 1])
        XCTAssertEqual(pages[0].entries.map(\.values), items.map(LibraryFilterValues.init))
        XCTAssertEqual(pages[0].entries.map(\.time), items.map(\.time))
        XCTAssertEqual(pages[0].entries[0].values.camera, "Canon R5")
        XCTAssertEqual(pages[0].entries[1].values.mediaKind, .video)
    }

    func testFacetsFollowFavoriteAndRotationPatches() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let (page, _) = try await seedFacetPage(store)
        let replacement = try exifItem(1, day: page.address.day, width: 1000)
        try await store.applyMetadataRotationValues([1: replacement], namespace: namespace, admission: store.metadataAdmission(namespace))
        let pages = try await store.metadataFilterPages(namespace, collection: .library(.personal), days: nil, currentRun: "run")
        XCTAssertEqual(pages[0].entries[0].values.megapixels, LibraryFilterValues(replacement).megapixels)
        XCTAssertNotEqual(pages[0].entries[0].values.megapixels, 12)
    }

    func testEvictedDetailLeavesPageUnverifiedWithoutEntry() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let (page, _) = try await seedFacetPage(store)
        try await store.evictMetadataDetails(namespace: namespace, itemIDs: [1])
        let pages = try await store.metadataFilterPages(namespace, collection: .library(.personal), days: nil, currentRun: "run")
        XCTAssertEqual(pages[0].entries.map(\.itemID), [2])
        XCTAssertFalse(pages[0].verified)
        let snapshot = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(snapshot?.slots.map(\.itemID), [1, 2])
    }

    func testFilterPageVerificationMatchesMetadataPage() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let (page, _) = try await seedFacetPage(store)
        let collection = PhotoCollectionDescriptor.library(.personal)
        func both(_ run: String) async throws -> (Bool?, Bool?) {
            let filter = try await store.metadataFilterPages(namespace, collection: collection, days: nil, currentRun: run).first?.verified
            return (filter, try await store.metadataPage(page.address, namespace: namespace, currentRun: run)?.verified)
        }
        var result = try await both("run")
        XCTAssertEqual(result.0, true); XCTAssertEqual(result.1, true)
        result = try await both("other-run")
        XCTAssertEqual(result.0, false); XCTAssertEqual(result.1, false)
        try await store.invalidateMetadataCollection(.init(namespace: namespace, collection: collection), admission: store.metadataAdmission(namespace))
        result = try await both("run")
        XCTAssertEqual(result.0, false); XCTAssertEqual(result.1, false)
        let scoped = try await store.metadataFilterPages(namespace, collection: collection, days: [page.address.day], currentRun: "run")
        XCTAssertEqual(scoped.count, 1)
        let other = try await store.metadataFilterPages(namespace, collection: collection, days: [CaptureDay(year: 2020, month: 1, day: 1)], currentRun: "run")
        XCTAssertTrue(other.isEmpty)
    }

    func testDetailRecordRoundTripsFacets() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let payload = try exifItem(7, day: day)
        let record = ItemDetailRecord(namespace: "n", itemID: 7, payload: payload, contentEpoch: 0, annotationRun: nil, revision: 1, accessed: 1)
        let (fetched, facetRecord) = try await store.database.write { db -> (ItemDetailRecord?, ItemFacetRecord?) in
            try record.insert(db)
            return (try ItemDetailRecord.fetchOne(db, key: ["namespace": "n", "item_id": 7]),
                    try ItemFacetRecord.filter(ItemDetailRecord.Columns.itemID == 7).fetchOne(db))
        }
        XCTAssertEqual(fetched?.facets, ItemFacets(payload))
        XCTAssertEqual(facetRecord?.facets, ItemFacets(payload))
        XCTAssertNil(facetRecord?.annotationRun)
    }
    // MARK: Folder catalog proof

    private func folderItem(_ id: Int64, day: CaptureDay, folder: Int64?) throws -> PhotoItem {
        let folderField = folder.map { ",\"folder_id\":\($0)" } ?? ""
        return try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(day.startTime),\"type\":\"photo\"\(folderField)}".utf8))
    }

    /// Two folders, each with one complete day page, validated in an earlier run. A folder in
    /// `missingPage` also has a second day whose page was never stored.
    private func seedFolders(_ store: DiskCache, missingPage: Set<Int64> = []) async throws -> CaptureDay {
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let unstored = try CaptureDay(year: 2023, month: 6, day: 1)
        let members: [Int64: [Int64]] = [10: [1, 2], 20: [3]]
        for (folder, ids) in members {
            let collection = PhotoCollectionDescriptor.folder(folder, space: .personal)
            let key = CollectionKey(namespace: namespace, collection: collection)
            let admission = try await store.metadataAdmission(namespace)
            let extra: [CollectionDayCount] = missingPage.contains(folder) ? [try .init(day: unstored, count: 1)] : []
            let catalog = try CollectionDayCatalog(days: [.init(day: day, count: ids.count)] + extra, completeness: .complete)
            try await store.storeMetadataCatalog(catalog, key: key, validatedRun: "earlier", admission: admission)
            let stored0 = try await store.metadataDayGeneration(key, day: day)
            let generation = try XCTUnwrap(stored0)
            let page = try DayPageRead(address: .init(collection: collection, day: day, offset: 0), dayCount: ids.count,
                                       membershipGeneration: UInt64(generation))
            try await store.storeMetadataIdentityPage(page, entries: ids.map { DayTimelineEntry(id: $0, time: day.startTime) },
                                                     namespace: namespace, currentRun: "earlier", admission: admission)
        }
        return day
    }

    private func folderValidatedRuns(_ store: DiskCache) async throws -> [Int64: String?] {
        var result: [Int64: String?] = [:]
        for folder: Int64 in [10, 20] {
            let key = CollectionKey(namespace: namespace, collection: .folder(folder, space: .personal))
            result[folder] = try await store.metadataCatalog(key)?.validatedRun
        }
        return result
    }

    func testProvenIntervalValidatesOnlyUntouchedFolderCatalogs() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try await seedFolders(store)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2),
                                             replacements: [folderItem(1, day: day, folder: 10)], deletedIDs: [],
                                             affectedDays: [day], invalidateAll: false, proven: true, currentRun: "now",
                                             admission: store.metadataAdmission(namespace))
        let runs = try await folderValidatedRuns(store)
        XCTAssertEqual(runs[10], .some(nil), "the changed item's folder is read again")
        XCTAssertEqual(runs[20], "now")
    }

    func testFolderProofCoversMovesDeletionsAndEmptyIntervals() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try await seedFolders(store)
        // Item 3 moved from folder 20 to folder 10: both folders change.
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2),
                                             replacements: [folderItem(3, day: day, folder: 10)], deletedIDs: [],
                                             affectedDays: [day], invalidateAll: false, proven: true, currentRun: "move",
                                             admission: store.metadataAdmission(namespace))
        var runs = try await folderValidatedRuns(store)
        XCTAssertEqual(runs[10], .some(nil))
        XCTAssertEqual(runs[20], .some(nil))

        let (other, otherRoot) = try await open()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        _ = try await seedFolders(other)
        try await other.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2),
                                             replacements: [], deletedIDs: [3], affectedDays: [day], invalidateAll: false,
                                             proven: true, currentRun: "delete", admission: other.metadataAdmission(namespace))
        runs = try await folderValidatedRuns(other)
        XCTAssertEqual(runs[10], "delete")
        XCTAssertEqual(runs[20], .some(nil), "a deleted member's folder is read again")

        try await other.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 3, versionTime: 3),
                                             replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: false,
                                             proven: true, currentRun: "quiet", admission: other.metadataAdmission(namespace))
        runs = try await folderValidatedRuns(other)
        XCTAssertEqual(runs[10], "quiet", "an empty interval validates every complete folder")
        XCTAssertEqual(runs[20], .some(nil), "a withdrawn catalog stays withdrawn")
    }

    func testFolderProofIsWithheldWhenEvidenceIsIncomplete() async throws {
        // A replacement without a folder ID disables the shortcut.
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try await seedFolders(store)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2),
                                             replacements: [folderItem(1, day: day, folder: nil)], deletedIDs: [],
                                             affectedDays: [day], invalidateAll: false, proven: true, currentRun: "now",
                                             admission: store.metadataAdmission(namespace))
        var runs = try await folderValidatedRuns(store)
        XCTAssertEqual(runs[10], .some(nil))
        XCTAssertEqual(runs[20], .some(nil))

        // A folder whose pages do not list every member could hide the changed item.
        let (partial, partialRoot) = try await open()
        defer { try? FileManager.default.removeItem(at: partialRoot) }
        _ = try await seedFolders(partial, missingPage: [10])
        try await partial.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2),
                                               replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: false,
                                               proven: true, currentRun: "now", admission: partial.metadataAdmission(namespace))
        runs = try await folderValidatedRuns(partial)
        XCTAssertEqual(runs[10], "earlier", "incomplete pages keep the earlier validation, so the catalog is read again")
        XCTAssertEqual(runs[20], "now")

        // An unproven interval validates nothing.
        let (unproven, unprovenRoot) = try await open()
        defer { try? FileManager.default.removeItem(at: unprovenRoot) }
        _ = try await seedFolders(unproven)
        try await unproven.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2),
                                                replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: false,
                                                proven: false, currentRun: "now", admission: unproven.metadataAdmission(namespace))
        runs = try await folderValidatedRuns(unproven)
        XCTAssertEqual(runs[10], "earlier")
        XCTAssertEqual(runs[20], "earlier")
    }

    // MARK: Album copies

    func testAlbumCopiesAreProvenBySpaceFeedsAndInvalidatedByTheirChanges() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let album = MetadataNamespace(account: namespace.account, scope: .album(54))
        let shared = MetadataNamespace(account: namespace.account, scope: .space(.shared))
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        try await store.storeMetadataDetails([item(1, day: day), item(2, day: day)], namespace: album, currentRun: "earlier",
                                             admission: store.metadataAdmission(album))
        func verified(_ run: String) async throws -> [Int64: Bool] {
            try await store.metadataDetails(album, ids: [1, 2], currentRun: run).mapValues(\.verified)
        }
        var result = try await verified("now")
        XCTAssertEqual(result, [1: false, 2: false], "no feed proved this run")

        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2), replacements: [item(1, day: day)],
                                             deletedIDs: [], affectedDays: [day], invalidateAll: false, proven: true, currentRun: "now",
                                             admission: store.metadataAdmission(namespace))
        result = try await verified("now")
        XCTAssertEqual(result, [1: false, 2: true], "the changed item's album copy is stale; the other is proven")
        let albumState = try await store.metadataState(album)
        XCTAssertGreaterThan(albumState.revision, 0, "an album read in flight is superseded")

        // An account with a Shared feed needs it proven too.
        try await store.applyMetadataChanges(namespace: shared, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, proven: false, currentRun: "now",
                                             admission: store.metadataAdmission(shared))
        result = try await verified("now")
        XCTAssertEqual(result[2], false)
        try await store.applyMetadataChanges(namespace: shared, cursor: .init(diffVersion: 2, versionTime: 2), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, proven: true, currentRun: "now",
                                             admission: store.metadataAdmission(shared))
        result = try await verified("now")
        XCTAssertEqual(result[2], true)

        // A space reset marks every album copy stale.
        try await store.applyMetadataChanges(namespace: shared, cursor: .init(diffVersion: 3, versionTime: 3), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: true, currentRun: "now", admission: store.metadataAdmission(shared))
        try await store.applyMetadataChanges(namespace: shared, cursor: .init(diffVersion: 4, versionTime: 4), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, proven: true, currentRun: "now",
                                             admission: store.metadataAdmission(shared))
        result = try await verified("now")
        XCTAssertEqual(result, [1: false, 2: false])
    }

    func testDiffProofVerifiesUntouchedCachedPagesInALaterRun() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let other = try CaptureDay(year: 2024, month: 1, day: 2)
        let key = CollectionKey(namespace: namespace, collection: .library(.personal))
        let catalog = try CollectionDayCatalog(days: [.init(day: page.address.day, count: 3), .init(day: other, count: 1)], completeness: .complete)

        var admission = try await store.metadataAdmission(namespace)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, currentRun: "next", admission: admission)
        admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog, key: key, validatedRun: "next", admission: admission)
        let unproven = try await store.metadataPage(page.address, namespace: namespace, currentRun: "next")
        XCTAssertEqual(unproven?.verified, false, "Without a proven reconciliation a page needs this run's read")

        admission = try await store.metadataAdmission(namespace)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 3, versionTime: 3), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, proven: true, currentRun: "next", admission: admission)
        let proven = try await store.metadataPage(page.address, namespace: namespace, currentRun: "next")
        XCTAssertEqual(proven?.verified, true)
        let filterPages = try await store.metadataFilterPages(namespace, collection: .library(.personal), days: nil, currentRun: "next")
        XCTAssertEqual(filterPages.map(\.verified), [true])
        let details = try await store.metadataDetails(namespace, ids: [1], currentRun: "next")
        XCTAssertEqual(details[1]?.verified, true)

        // A touched day loses the proof; a run without this run's catalog never had it.
        admission = try await store.metadataAdmission(namespace)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 4, versionTime: 4), replacements: [], deletedIDs: [],
                                             affectedDays: [page.address.day], invalidateAll: false, proven: true, currentRun: "next", admission: admission)
        admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog, key: key, validatedRun: "next", admission: admission)
        let touched = try await store.metadataPage(page.address, namespace: namespace, currentRun: "next")
        XCTAssertEqual(touched?.verified, false)
        let laterRun = try await store.metadataPage(page.address, namespace: namespace, currentRun: "later")
        XCTAssertEqual(laterRun?.verified, false)
    }
    func testFavoriteEventsPatchDetailsAndMarkOnlyTheirFavoritesDays() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let favorites = try await seed(store, collection: .favorites(.personal))
        let other = try CaptureDay(year: 2024, month: 1, day: 2)
        let otherPage = try DayPageRead(address: .init(collection: .favorites(.personal), day: other, offset: 0), dayCount: 1, membershipGeneration: 1)
        let key = CollectionKey(namespace: namespace, collection: .favorites(.personal))
        let catalog = try CollectionDayCatalog(days: [.init(day: favorites.address.day, count: 3), .init(day: other, count: 1)], completeness: .complete)
        var admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog, key: key, validatedRun: "run", admission: admission)
        try await store.storeMetadataPage(otherPage, items: [item(9, day: other)], profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)

        admission = try await store.metadataAdmission(namespace)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, favorites: [2: false], proven: true,
                                             currentRun: "next", admission: admission)
        admission = try await store.metadataAdmission(namespace)
        let generation = try await store.metadataDayGeneration(key, day: favorites.address.day) ?? 0
        let otherGeneration = try await store.metadataDayGeneration(key, day: other) ?? 0
        let refreshed = try CollectionDayCatalog(days: [.init(day: favorites.address.day, count: 2), .init(day: other, count: 1)], completeness: .complete)
        try await store.storeMetadataCatalog(refreshed, key: key, validatedRun: "next", admission: admission)

        XCTAssertGreaterThan(generation, 1, "The favorite's day must be reread")
        XCTAssertEqual(otherGeneration, 1)
        let changed = try await store.metadataPage(favorites.address, namespace: namespace, currentRun: "next")
        XCTAssertEqual(changed?.verified, false)
        let untouched = try await store.metadataPage(otherPage.address, namespace: namespace, currentRun: "next")
        XCTAssertEqual(untouched?.verified, true)
        let details = try await store.metadataDetails(namespace, ids: [2], currentRun: "next")
        XCTAssertEqual(details[2]?.item?.additional?.favorite, false)
        XCTAssertEqual(details[2]?.verified, true)
    }
    func testWithdrawingValidationKeepsRowsButRequiresNewReads() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let admission = try await store.metadataAdmission(namespace)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 2, versionTime: 2), replacements: [], deletedIDs: [],
                                             affectedDays: [], invalidateAll: false, proven: true, currentRun: "run", admission: admission)
        let before = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(before?.verified, true)
        try await store.withdrawMetadataValidation()
        let state = try await store.metadataState(namespace)
        XCTAssertNil(state.cursor); XCTAssertNil(state.proofRun)
        let after = try await store.metadataPage(page.address, namespace: namespace, currentRun: "run")
        XCTAssertEqual(after?.slots.compactMap(\.item).count, 3, "Cached rows stay readable")
        XCTAssertEqual(after?.verified, false)
        let details = try await store.metadataDetails(namespace, ids: [1], currentRun: "run")
        XCTAssertEqual(details[1]?.verified, false)
    }
    func testReferencedDaysListEveryCachedPageThatHoldsAnID() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await seed(store)
        _ = try await seed(store, collection: .favorites(.personal))
        let days = try await store.metadataReferencedDays(namespace, ids: [2, 99])
        XCTAssertEqual(days, [2: [library.address.day]])
    }
}
