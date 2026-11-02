import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

actor BatchedMetadataTransport: PhotosTransport {
    let catalog: CollectionDayCatalog
    let rows: [PhotoItem]
    let delay: Duration
    var requests: [CollectionPageRequest] = []
    var active = 0
    var maximumActive = 0
    var catalogs = 0
    var badResponsesRemaining: Int
    var transportFailuresRemaining = 0
    var detailCalls = 0
    func failNextTransport() { transportFailuresRemaining = 1 }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { detailCalls += 1; return rows.filter { ids.contains($0.id) } }
    func detailCallCount() -> Int { detailCalls }
    init(delay: Duration = .milliseconds(10), days: Int = 69, badResponses: Int = 0) throws {
        badResponsesRemaining = badResponses
        self.delay = delay
        let newest = try CaptureDay(year: 2024, month: 6, day: 30)
        let counts = try (0..<days).map { offset in
            try CollectionDayCount(day: CaptureDay(time: newest.startTime - Int64(offset) * 86400), count: days == 69 && offset == 68 ? 4 : 5)
        }
        catalog = try CollectionDayCatalog(days: counts, completeness: .complete)
        var rows: [PhotoItem] = []
        for entry in counts {
            for within in 0..<entry.count {
                let id = rows.count + 1
                rows.append(try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(entry.day.startTime + Int64(entry.count - within)),\"type\":\"photo\"}".utf8)))
            }
        }
        self.rows = rows
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog { catalogs += 1; return catalog }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        requests.append(request)
        if transportFailuresRemaining > 0 { transportFailuresRemaining -= 1; throw SynologyAPIError.transport("fixture failure") }
        let bad = badResponsesRemaining > 0
        if bad { badResponsesRemaining -= 1 }
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        let selected = rows.filter { $0.time >= request.oldestDay.startTime && $0.time <= request.newestDay.endTime }
        let items = Array(selected.dropFirst(request.offset).prefix(request.limit))
        return .init(items: bad ? Array(items.dropLast()) : items, profile: fields)
    }
    func catalogCalls() -> Int { catalogs }
    func stats() -> (requests: [CollectionPageRequest], maximum: Int) { (requests, maximumActive) }
}
final class MetadataBatchAcquisitionTests: XCTestCase, @unchecked Sendable {
    func testWarmerBatches69TinyDaysIntoThreeRequestsWithTwoNetworkSlots() async throws {
        let root = temporaryTestRoot("metadata-69-days"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BatchedMetadataTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "batch", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .favorites(.personal))
        let loader = TimelineSectionCacheLoader(repository: repository, collection: .favorites(.personal), snapshot: snapshot)
        await loader.loadAll()
        let finished = await waitUntil(attempts: 1000) { await loader.progress().state == .finished }
        XCTAssertTrue(finished)
        let progress = await loader.progress()
        XCTAssertEqual(progress.verified, 69)
        XCTAssertEqual(progress.failed, 0)
        let stats = await transport.stats()
        XCTAssertEqual(stats.requests.count, 3)
        XCTAssertEqual(stats.requests.map(\.limit).sorted(), [24, 160, 160])
        XCTAssertLessThanOrEqual(stats.maximum, 2)
        XCTAssertTrue(stats.requests.allSatisfy { $0.limit <= 1000 })
    }
    func testCancelingWarmerStopsQueuedBatchesAfterTwoAdmittedRequests() async throws {
        let root = temporaryTestRoot("metadata-batch-cancel"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BatchedMetadataTransport(delay: .seconds(3))
        let repository = try CachedPhotosRepository(credentials: .init(username: "batch", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .favorites(.personal))
        let loader = TimelineSectionCacheLoader(repository: repository, collection: .favorites(.personal), snapshot: snapshot)
        await loader.loadAll()
        let admitted = await waitUntil { await transport.stats().requests.count == 2 }
        XCTAssertTrue(admitted)
        await loader.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let stats = await transport.stats()
        XCTAssertEqual(stats.requests.count, 2)
        XCTAssertLessThanOrEqual(stats.maximum, 2)
    }
    func testFailed32PageBatchSharesOneCatalogRepairAndOneRetry() async throws {
        let root = temporaryTestRoot("metadata-batch-repair"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BatchedMetadataTransport(days: 32, badResponses: 1)
        let repository = try CachedPhotosRepository(credentials: .init(username: "batch", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .favorites(.personal))
        let loader = TimelineSectionCacheLoader(repository: repository, collection: .favorites(.personal), snapshot: snapshot)
        await loader.loadAll()
        let finished = await waitUntil(attempts: 1000) { await loader.progress().state == .finished }
        XCTAssertTrue(finished)
        let progress = await loader.progress()
        XCTAssertEqual(progress.verified, 32)
        XCTAssertEqual(progress.failed, 0)
        let stats = await transport.stats()
        let catalogs = await transport.catalogCalls()
        XCTAssertEqual(stats.requests.count, 2)
        XCTAssertEqual(catalogs, 2)
    }

}
