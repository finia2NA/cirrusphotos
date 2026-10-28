import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class LibraryFilterCacheDeliveryTests: XCTestCase {
    private let section = TimelineSection(offset: 0, limit: 1,
        list: [TimelineDay(year: 2024, month: 4, day: 20, itemCount: 1)])

    private func photo() throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"filename":"one.JPG","time":1713571200,"type":"photo",
         "additional":{"exif":{"camera":"Audit Camera"}}}
        """.utf8))
    }

    private func seed(_ repository: CachedPhotosRepository) async throws {
        try await seedMetadataPage([photo()], section: section, repository: repository)
    }

    func testOrdinaryPageEmitsCacheBeforeBlockedValidation() async throws {
        let root = temporaryTestRoot("AuditOrdinaryPage")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AuditBlockedTransport(snapshot: .init(sections: [section]), items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        try await seed(repository)
        let values = AuditValues()
        let reading = Task { [section] in
            for await event in await repository.page(section) {
                if case .value(let items, _) = event { let items = items.completeItems ?? []; await values.add(items) }
            }
        }
        let started = await waitUntil { await transport.started }
        XCTAssertTrue(started)
        let cachedArrived = await waitUntil { await values.count > 0 }
        XCTAssertTrue(cachedArrived)
        await transport.release()
        await reading.value
    }

    func testLibraryFilterEmitsCacheBeforeBlockedValidation() async throws {
        let root = temporaryTestRoot("AuditFilteredPage")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AuditBlockedTransport(snapshot: .init(sections: [section]), items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.timeline() {}
        try await seed(repository)
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: descriptor,
            snapshot: .init(sections: [section]), referencesBySection: [[
                .init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1)
            ]], filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: .init(sections: [section])).fingerprint))
        let values = AuditValues()
        let reading = Task { [section] in
            for await event in await repository.page(section, collection: descriptor) {
                if case .value(let items, _) = event { let items = items.completeItems ?? []; await values.add(items) }
            }
        }
        let started = await waitUntil { await transport.started }
        XCTAssertTrue(started)
        let cachedArrived = await waitUntil { await values.count > 0 }
        XCTAssertTrue(cachedArrived, "Cached filtered items must arrive while source validation is blocked")
        await transport.release()
        await reading.value
        let finalCount = await values.count
        XCTAssertGreaterThan(finalCount, 0)
    }

    func testUnverifiedSourceMembershipKeepsDerivedSlotsUnverified() async throws {
        let root = temporaryTestRoot("FilterSourceAuthority")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AuditBlockedTransport(snapshot: .init(sections: [section]), items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw"), cacheRoot: root, transport: transport)
        let run = await repository.runID
        try await seedMetadataPage([photo()], section: section, repository: repository, collection: .favorites, validatedRun: run)
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: descriptor, snapshot: .init(sections: [section]),
            referencesBySection: [[.init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1, sourceVerified: false)]],
            filter: .init(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: .init(sections: [section])).fingerprint,
            sourceCollection: .favorites))
        var pages: [PhotoPageSnapshot] = []
        for await event in await repository.page(section, collection: descriptor, allowNetwork: false) {
            if case .value(let page, _) = event { pages.append(page) }
        }
        let page = try XCTUnwrap(pages.first)
        XCTAssertEqual(page.slots.first?.item?.id, 1)
        XCTAssertFalse(page.membershipVerified)
        XCTAssertEqual(page.slots.first?.verified, false)
    }

    func testExplicitReconciliationDiscoversDirectlySeededPages() async throws {
        let root = temporaryTestRoot("AuditLateCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [section])
        let transport = AuditBlockedTransport(snapshot: snapshot, items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        let controller = LibraryFilterController(repository: repository, snapshot: snapshot)
        await controller.indexCachedPages()
        // Direct store seeding bypasses repository page notifications.
        try await seed(repository)
        _ = await controller.apply(LibraryFilter(cameras: ["Audit Camera"]))
        await controller.indexCachedPages(reconcile: true)
        let registration = await controller.currentEvent().registration
        XCTAssertEqual(registration?.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
        let freshController = LibraryFilterController(repository: repository, snapshot: snapshot)
        _ = await freshController.apply(LibraryFilter(cameras: ["Audit Camera"]))
        await freshController.indexCachedPages()
        let fresh = await freshController.currentEvent().registration
        XCTAssertEqual(fresh?.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
        await controller.shutdown()
        await freshController.shutdown()
    }

    func testRepositoryPageArrivalUpdatesActiveFilterWithoutUIForwarding() async throws {
        let root = temporaryTestRoot("FilterRepositoryArrival")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [section])
        let transport = AuditBlockedTransport(snapshot: snapshot, items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        let controller = LibraryFilterController(repository: repository, snapshot: snapshot)
        _ = await controller.apply(LibraryFilter(cameras: ["Audit Camera"]))
        let values = AuditFilterEvents()
        let observation = Task {
            for await event in await controller.observe() { await values.record(event) }
        }
        await transport.release()
        for await _ in await repository.page(section) {}
        let updated = await waitUntil { await values.ids == [1] }
        XCTAssertTrue(updated)
        await controller.shutdown()
        await observation.value
        let observers = await repository.collectionPageObserverCountForTests()
        XCTAssertEqual(observers, 0)
    }

    func testKnownSecondSlotArrivesBeforeMissingFirstDetailLookup() async throws {
        let root = temporaryTestRoot("FilterSparseCanonical"); defer { try? FileManager.default.removeItem(at: root) }
        let daySection = TimelineSection(offset: 0, limit: 2, list: [.init(year: 2024, month: 4, day: 20, itemCount: 2)])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo())) as! [String: Any]
        json["id"] = 99
        let missing = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: json))
        let snapshot = TimelineSnapshot(sections: [daySection])
        let transport = AuditBlockedTransport(snapshot: snapshot, items: [missing, try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw"), cacheRoot: root, transport: transport)
        for await _ in await repository.timeline() {}
        try await seedMetadataPage([missing, photo()], section: daySection, repository: repository)
        try await repository.store.evictMetadataDetails(namespace: repository.metadataNamespace, itemIDs: [99])
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: descriptor, snapshot: snapshot, referencesBySection: [[
            .init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 99), .init(sourceSectionIndex: 0, sourcePageOffset: 1, itemID: 1)
        ]], filter: .init(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: snapshot).fingerprint))
        var iterator = await repository.page(daySection, collection: descriptor).makeAsyncIterator()
        guard case .value(let cached, false) = await iterator.next() else { return XCTFail("Missing sparse cached page") }
        XCTAssertEqual(cached.slots.map(\.itemID), [99, 1])
        XCTAssertNil(cached.slots[0].item); XCTAssertEqual(cached.slots[1].item?.id, 1)
        await transport.release()
        guard case .value(let current, true) = await iterator.next() else { return XCTFail("Missing current replacement") }
        XCTAssertEqual(current.slots.map(\.itemID), [99, 1])
    }

    func testFailedValidationKeepsCachedFilteredItems() async throws {
        let root = temporaryTestRoot("FilterValidationFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AuditBlockedTransport(snapshot: .init(sections: [section]), items: [], failAfterRelease: true)
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.timeline() {}
        try await seed(repository)
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: descriptor,
            snapshot: .init(sections: [section]), referencesBySection: [[
                .init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1)
            ]], filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: .init(sections: [section])).fingerprint))
        await transport.release()
        var latest: [Int64] = []
        var sawFailure = false
        for await event in await repository.page(section, collection: descriptor) {
            switch event {
            case .value(let items, let verified): let items = items.completeItems ?? [];
                XCTAssertFalse(verified)
                latest = items.map(\.id)
            case .failure: sawFailure = true
            }
        }
        XCTAssertEqual(latest, [1])
        XCTAssertTrue(sawFailure)
    }

    func testUnregisteredFilterRejectsLateValidation() async throws {
        try await assertLateValidationRejected(changeTimeline: false)
    }

    func testChangedSourceTimelineRejectsLateValidation() async throws {
        try await assertLateValidationRejected(changeTimeline: true)
    }

    private func assertLateValidationRejected(changeTimeline: Bool) async throws {
        let root = temporaryTestRoot("FilterLateValidation")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AuditBlockedTransport(snapshot: .init(sections: [section]), items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.timeline() {}
        try await seed(repository)
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: descriptor,
            snapshot: .init(sections: [section]), referencesBySection: [[
                .init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1)
            ]], filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: .init(sections: [section])).fingerprint))
        let values = AuditValues()
        let reading = Task { [section] in
            for await event in await repository.page(section, collection: descriptor) {
                if case .value(let items, _) = event { let items = items.completeItems ?? []; await values.add(items) }
            }
        }
        let started = await waitUntil { await transport.started }
        XCTAssertTrue(started)
        let cached = await waitUntil { await values.count == 1 }
        XCTAssertTrue(cached)
        if changeTimeline {
            await repository.replacePersonalTimelineForTests(.init(sections: []))
        } else {
            await repository.unregisterLibraryFilter(descriptor)
        }
        await transport.release()
        await reading.value
        let count = await values.count
        XCTAssertEqual(count, 1)
    }

    func testPageHintsCoalesceWithoutLosingDescriptorsAndResetDetachesObserver() async throws {
        let root = temporaryTestRoot("FilterPageHints")
        defer { try? FileManager.default.removeItem(at: root) }
        let sections = (1...20).map { day in
            TimelineSection(offset: 0, limit: 1,
                list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: 1)])
        }
        let transport = AuditBlockedTransport(snapshot: .init(sections: sections), items: [])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        let observation = await repository.observeCollectionPages(collection: .personalLibrary, sections: Set(sections))
        await repository.publishCollectionPagesForTests(sections)
        let pending = await repository.takeCollectionPageChanges(observation.id)
        XCTAssertEqual(pending, Set(sections))
        let drained = await repository.takeCollectionPageChanges(observation.id)
        XCTAssertTrue(drained.isEmpty)
        try await repository.clearMetadataCache()
        let observers = await repository.collectionPageObserverCountForTests()
        XCTAssertEqual(observers, 0)
    }
}

private actor AuditFilterEvents {
    var ids: [Int64] = []
    func record(_ event: LibraryFilterControllerEvent) {
        ids = event.registration?.referencesBySection.flatMap { $0 }.map(\.itemID) ?? []
    }
}

private extension CachedPhotosRepository {
    func collectionPageObserverCountForTests() -> Int { metadata.collectionPageObservers.count }
    func replacePersonalTimelineForTests(_ snapshot: TimelineSnapshot) {
        metadata.latestTimelines[.personalLibrary] = snapshot
    }
    func publishCollectionPagesForTests(_ sections: [TimelineSection]) {
        for section in sections {
            if let key = CacheKey.page(namespace: namespace, section: section) { publishCollectionPage(key: key) }
        }
    }
}

private actor AuditValues {
    var count = 0
    var latestIDs: [Int64] = []
    func add(_ items: [PhotoItem]) {
        if !items.isEmpty { count += 1; latestIDs = items.map(\.id) }
    }
}

private actor AuditBlockedTransport: PhotosTransport {
    let snapshot: TimelineSnapshot
    let values: [PhotoItem]
    var started = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var released = false
    let failAfterRelease: Bool
    init(snapshot: TimelineSnapshot, items: [PhotoItem], failAfterRelease: Bool = false) {
        self.snapshot = snapshot; values = items; self.failAfterRelease = failAfterRelease
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(snapshot, initial: initial)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        started = true
        if !released { await withCheckedContinuation { blocked = $0 } }
        if failAfterRelease { throw TestFailure("Validation unavailable") }
        return try fixtureBatch(values, request: request, fields: fields)
    }
    func items(ids: [Int64]) async throws -> [PhotoItem] {
        started = true
        if !released { await withCheckedContinuation { blocked = $0 } }
        if failAfterRelease { throw TestFailure("Validation unavailable") }
        return values.filter { ids.contains($0.id) }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}
