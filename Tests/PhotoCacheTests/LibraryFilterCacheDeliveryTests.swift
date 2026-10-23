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
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(
            server: SynologyClient.defaultBaseURL, account: "audit"), section: section))
        try await repository.store.put(key, kind: .page,
            data: JSONEncoder().encode([photo()]), validatedRun: "previous-run")
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
                if case .value(let items, _) = event { await values.add(items) }
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
            ]], filter: LibraryFilter(), revision: 1))
        let values = AuditValues()
        let reading = Task { [section] in
            for await event in await repository.page(section, collection: descriptor) {
                if case .value(let items, _) = event { await values.add(items) }
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

    func testFilterDiscoversPagesCachedAfterInitialDiscovery() async throws {
        let root = temporaryTestRoot("AuditLateCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [section])
        let transport = AuditBlockedTransport(snapshot: snapshot, items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        let controller = LibraryFilterController(repository: repository, snapshot: snapshot)
        await controller.indexCachedPages()
        // Represents a page cached later by thumbnail warming or another repository consumer.
        try await seed(repository)
        let registration = await controller.apply(LibraryFilter(cameras: ["Audit Camera"]))
        XCTAssertEqual(registration.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
        let freshController = LibraryFilterController(repository: repository, snapshot: snapshot)
        let fresh = await freshController.apply(LibraryFilter(cameras: ["Audit Camera"]))
        XCTAssertEqual(fresh.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
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
        let observers = await repository.personalPageObserverCountForTests()
        XCTAssertEqual(observers, 0)
    }

    func testCachedSecondSourceArrivesBeforeFirstSourceValidation() async throws {
        let root = temporaryTestRoot("FilterMultipleSources")
        defer { try? FileManager.default.removeItem(at: root) }
        let second = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 19, itemCount: 1)])
        let snapshot = TimelineSnapshot(sections: [section, second])
        let transport = AuditBlockedTransport(snapshot: snapshot, items: [try photo()])
        let repository = try CachedPhotosRepository(credentials: .init(username: "audit", password: "pw", otpSecret: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.timeline() {}
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(
            server: SynologyClient.defaultBaseURL, account: "audit"), section: second))
        try await repository.store.put(key, kind: .page, data: JSONEncoder().encode([photo()]), validatedRun: "previous-run")
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: descriptor,
            snapshot: .init(sections: [second]), referencesBySection: [[
                .init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 99),
                .init(sourceSectionIndex: 1, sourcePageOffset: 0, itemID: 1)
            ]], filter: LibraryFilter(), revision: 1))
        let values = AuditValues()
        let reading = Task {
            for await event in await repository.page(second, collection: descriptor) {
                if case .value(let items, _) = event { await values.add(items) }
            }
        }
        let started = await waitUntil { await transport.started }
        XCTAssertTrue(started)
        let cachedArrived = await waitUntil { await values.latestIDs == [1] }
        XCTAssertTrue(cachedArrived)
        await transport.release()
        await reading.value
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
            ]], filter: LibraryFilter(), revision: 1))
        await transport.release()
        var latest: [Int64] = []
        var sawFailure = false
        for await event in await repository.page(section, collection: descriptor) {
            switch event {
            case .value(let items, let verified):
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
            ]], filter: LibraryFilter(), revision: 1))
        let values = AuditValues()
        let reading = Task { [section] in
            for await event in await repository.page(section, collection: descriptor) {
                if case .value(let items, _) = event { await values.add(items) }
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
        let observation = await repository.observePersonalPages(sections: Set(sections))
        await repository.publishPersonalPagesForTests(sections)
        let pending = await repository.takePersonalPageChanges(observation.id)
        XCTAssertEqual(pending, Set(sections))
        let drained = await repository.takePersonalPageChanges(observation.id)
        XCTAssertTrue(drained.isEmpty)
        try await repository.clearMetadataCache()
        let observers = await repository.personalPageObserverCountForTests()
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
    func personalPageObserverCountForTests() -> Int { metadata.personalPageObservers.count }
    func replacePersonalTimelineForTests(_ snapshot: TimelineSnapshot) {
        metadata.latestTimelines[.personalLibrary] = snapshot
    }
    func publishPersonalPagesForTests(_ sections: [TimelineSection]) {
        for section in sections {
            if let key = CacheKey.page(namespace: namespace, section: section) { publishPersonalPage(key: key) }
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
    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot { snapshot }
    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        started = true
        if !released { await withCheckedContinuation { blocked = $0 } }
        if failAfterRelease { throw TestFailure("Validation unavailable") }
        return values
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}
