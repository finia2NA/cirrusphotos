import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor DetailJobTransport: PhotosTransport {
    var calls: [PhotoContentScope: Int] = [:]
    var pending: [CheckedContinuation<Void, Never>] = []
    var blocked = true
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        try await lookup(ids, scope: .space(space))
    }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] {
        try await lookup(ids, scope: .album(albumID))
    }
    func lookup(_ ids: [Int64], scope: PhotoContentScope) async throws -> [PhotoItem] {
        calls[scope, default: 0] += 1
        let version = calls[scope]!
        if blocked { await withCheckedContinuation { pending.append($0) } }
        try Task.checkCancellation()
        return try ids.map { id in
            try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":1704067200,\"filename\":\"\(scope.cacheComponent)-\(version).jpg\",\"type\":\"photo\"}".utf8))
        }
    }
    func release() {
        blocked = false
        let waiting = pending; pending = []
        waiting.forEach { $0.resume() }
    }
}

extension CachedPhotosRepository {
    fileprivate func detailSubscriberCount(scope: PhotoContentScope) -> Int {
        metadata.detailJobs.values.filter { $0.scope == scope }.reduce(0) { $0 + $1.subscribers.count }
    }
}

final class ScopedMetadataDetailTests: XCTestCase, @unchecked Sendable {
    func testCoalescingCancellationAndCacheReuseAreIsolatedByScope() async throws {
        let root = temporaryTestRoot("scoped-detail-jobs")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DetailJobTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        try await repository.initializeMetadataEngine()
        try await repository.connect()
        let first = Task { try await repository.resolveMetadataItems([1], priority: .prefetch, collection: .library(.shared)) }
        let started = await waitUntil { await repository.detailSubscriberCount(scope: .space(.shared)) == 1 }
        XCTAssertTrue(started)
        let second = Task { try await repository.resolveMetadataItems([1], priority: .visible, collection: .favorites(.shared)) }
        let personal = Task { try await repository.resolveMetadataItems([1], priority: .visible, collection: .library(.personal)) }
        let joined = await waitUntil { await repository.detailSubscriberCount(scope: .space(.shared)) == 2 }
        XCTAssertTrue(joined)
        first.cancel()
        let releasedSubscriber = await waitUntil { await repository.detailSubscriberCount(scope: .space(.shared)) == 1 }
        XCTAssertTrue(releasedSubscriber)
        await transport.release()
        do { _ = try await first.value; XCTFail("Cancelled subscriber returned a value") } catch is CancellationError { }
        let sharedResult = try await second.value
        let personalResult = try await personal.value
        XCTAssertEqual(sharedResult.first?.filename, "shared-1.jpg")
        XCTAssertEqual(personalResult.first?.filename, "personal-1.jpg")
        _ = try await repository.resolveMetadataItems([1], priority: .visible, collection: .library(.shared))
        let calls = await transport.calls
        XCTAssertEqual(calls, [.space(.shared): 1, .space(.personal): 1])
    }

    func testFreshReadSupersedesAnOlderInFlightRead() async throws {
        let root = temporaryTestRoot("fresh-detail-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DetailJobTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        try await repository.initializeMetadataEngine()
        try await repository.connect()
        let old = Task { try await repository.resolveMetadataItems([1], priority: .visible, collection: .album(7)) }
        let started = await waitUntil { await transport.calls[.album(7)] == 1 }
        XCTAssertTrue(started)
        let fresh = Task { try await repository.resolveMetadataItems([1], priority: .visible, collection: .album(7), freshness: .fresh) }
        let freshStarted = await waitUntil { await transport.calls[.album(7)] == 2 }
        XCTAssertTrue(freshStarted)
        await transport.release()
        do { _ = try await old.value; XCTFail("Superseded details must not publish") } catch MetadataAdmissionError.superseded { }
        let result = try await fresh.value
        XCTAssertEqual(result.first?.filename, "album:7-2.jpg")
        let cached = try await repository.resolveMetadataItems([1], priority: .visible, collection: .album(7))
        XCTAssertEqual(cached.first?.filename, "album:7-2.jpg")
    }

    func testExplicitFreshAlbumReadBypassesCurrentRunDetails() async throws {
        let root = temporaryTestRoot("fresh-album-detail")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DetailJobTransport()
        await transport.release()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        try await repository.initializeMetadataEngine()
        try await repository.connect()
        let first = try await repository.resolveMetadataItems([1], priority: .visible, collection: .album(7))
        let reused = try await repository.resolveMetadataItems([1], priority: .visible, collection: .album(7))
        XCTAssertEqual(first, reused)
        let fresh = try await repository.resolveMetadataItems([1], priority: .visible, collection: .album(7), freshness: .fresh)
        XCTAssertEqual(fresh.first?.filename, "album:7-2.jpg")
        let calls = await transport.calls
        XCTAssertEqual(calls[.album(7)], 2)
        let personal = try await repository.store.metadataDetails(repository.personalMetadataNamespace, ids: [1], currentRun: repository.runID)
        XCTAssertTrue(personal.isEmpty)
    }
}
