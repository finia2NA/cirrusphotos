import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor RecentTransport: PhotosTransport {
    let offline: Bool
    let items: [PhotoItem]
    init(offline: Bool = false) throws {
        self.offline = offline
        let json = #"[{"id":1,"time":1577836800,"indexed_time":1793577600123,"type":"photo"},{"id":2,"time":1609459200,"indexed_time":1793577600000,"type":"photo"}]"#
        items = try JSONDecoder().decode([PhotoItem].self, from: Data(json.utf8))
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        if offline { throw TestFailure("Offline") }
        XCTAssertEqual(collection, .recentlyAdded)
        return try CollectionDayCatalog(days: [.init(day: .init(year: 2026, month: 11, day: 2), count: 2)], completeness: .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        if offline { throw TestFailure("Offline") }
        XCTAssertEqual(request.collection, .recentlyAdded)
        return CollectionBatchResult(items: items, profile: fields)
    }
}

final class RecentlyAddedTests: XCTestCase {
    func testIndexedDayKeepsCaptureTimeAndSurvivesOffline() async throws {
        let root = temporaryTestRoot("recently-added")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = SynologyCredentials(username: "test", password: "unused")
        let first = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: RecentTransport())
        var timeline: TimelineSnapshot?
        for await event in await first.timeline(collection: .recentlyAdded) { if case .value(let value, true) = event { timeline = value } }
        let section = try XCTUnwrap(timeline?.sections.first)
        var result: PhotoPageSnapshot?
        for await event in await first.page(section, collection: .recentlyAdded) { if case .value(let value, true) = event { result = value } }
        let items = try XCTUnwrap(result).slots.compactMap(\.item)
        XCTAssertEqual(items.map(\.time), [1577836800, 1609459200])
        XCTAssertEqual(items.map(\.id), [1, 2])
        let snapshot = try XCTUnwrap(timeline)
        let controller = LibraryFilterController(repository: first, snapshot: snapshot, sourceCollection: .recentlyAdded)
        _ = await controller.apply(LibraryFilter(mediaKinds: [.photo]))
        await controller.indexCachedPages()
        let filterEvent = await controller.currentEvent()
        let registration = try XCTUnwrap(filterEvent.registration)
        XCTAssertEqual(registration.snapshot.sections.first?.list.first?.year, 2026)
        XCTAssertEqual(registration.referencesBySection.flatMap { $0 }.map(\.itemID), [1, 2])
        try await first.registerLibraryFilter(registration)
        var filtered: PhotoPageSnapshot?
        for await event in await first.page(try XCTUnwrap(registration.snapshot.sections.first), collection: registration.descriptor, allowNetwork: false) {
            if case .value(let value, _) = event { filtered = value }
        }
        XCTAssertEqual(filtered?.slots.compactMap(\.item).map(\.time), [1577836800, 1609459200])
        await controller.shutdown()
        let offline = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: RecentTransport(offline: true))
        var cachedTimeline: TimelineSnapshot?
        for await event in await offline.timeline(collection: .recentlyAdded) { if case .value(let value, false) = event { cachedTimeline = value } }
        XCTAssertNotNil(cachedTimeline)
        var cachedPage: PhotoPageSnapshot?
        for await event in await offline.page(section, collection: .recentlyAdded) { if case .value(let value, false) = event { cachedPage = value } }
        XCTAssertEqual(cachedPage?.slots.compactMap(\.item).map(\.time), [1577836800, 1609459200])
    }

    func testMissingIndexedTimeFailsClosed() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":1,"time":1793577600,"type":"photo"}"#.utf8))
        let day = try CaptureDay(year: 2026, month: 11, day: 2)
        let address = try DayPageAddress(collection: .recentlyAdded, day: day, offset: 0)
        let page = try DayPageRead(address: address, dayCount: 1, membershipGeneration: 1)
        let catalog = try CollectionDayCatalog(days: [.init(day: day, count: 1)], completeness: .complete)
        let batch = try XCTUnwrap(MetadataReadPlanner.plan(demands: [page], catalog: catalog, profile: .fullPage).first)
        XCTAssertThrowsError(try batch.materialize(.init(items: [item], profile: .fullPage)))
    }
}
