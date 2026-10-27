import Foundation
import SQLite3
import XCTest
import SynologyAPI
@testable import PhotoCache

final class MetadataStoreTests: XCTestCase, @unchecked Sendable {
    private let namespace = MetadataNamespace(account: "fixture-account")
    private func item(_ id: Int64, day: CaptureDay) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(day.startTime),\"type\":\"photo\",\"filename\":\"fixture.jpg\",\"additional\":{\"favorite\":true}}".utf8))
    }
    private func open() async throws -> (DiskCache, URL) {
        let root = temporaryTestRoot("normalized-store")
        let store = try DiskCache(root: root, budget: 10_000_000)
        try await store.initializeMetadataStore()
        return (store, root)
    }
    private func seed(_ store: DiskCache, collection: PhotoCollectionDescriptor = .personalLibrary) async throws -> DayPageRead {
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
        let favorites = try await seed(store, collection: .favorites)
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
    func testCatalogPresentationDoesNotDirtyUnrelatedDay() async throws {
        let (store, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await seed(store)
        let newDay = try CaptureDay(year: 2024, month: 1, day: 2)
        let key = CollectionKey(namespace: namespace, collection: .personalLibrary)
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
        let missing = try await store.metadataPage(page.address, namespace: .init(account: "other"), currentRun: "run")
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
        try await store.storeMetadataCatalog(catalog, key: .init(namespace: namespace, collection: .personalLibrary), validatedRun: "run", admission: admission)
        let first = try DayPageRead(address: .init(collection: .personalLibrary, day: firstDay, offset: 0), dayCount: 1, membershipGeneration: 1)
        let second = try DayPageRead(address: .init(collection: .personalLibrary, day: secondDay, offset: 0), dayCount: 1, membershipGeneration: 1)
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

}
