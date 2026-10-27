import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class TimelineSectionCacheLoaderTests: XCTestCase, @unchecked Sendable {
    private func finished(_ loader: TimelineSectionCacheLoader) async -> TimelineSectionCacheProgress {
        _ = await waitUntil(attempts: 1000) { await loader.progress().state == .finished }
        return await loader.progress()
    }
    func testCachedPagesSkipCompleteDetailsAndForceWarmRevalidatesMembership() async throws {
        let root = temporaryTestRoot("warmer-cache-policy"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BatchedMetadataTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "warmer", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .favorites)
        let first = TimelineSectionCacheLoader(repository: repository, collection: .favorites, snapshot: snapshot)
        await first.loadAll()
        let initial = await finished(first)
        XCTAssertEqual(initial.verified, 69)
        let second = TimelineSectionCacheLoader(repository: repository, collection: .favorites, snapshot: snapshot)
        await second.loadAll(useCachedPages: true)
        let cached = await finished(second)
        XCTAssertEqual(cached.cached, 69)
        let before = await transport.stats()
        XCTAssertEqual(before.requests.count, 3)
        let forced = TimelineSectionCacheLoader(repository: repository, collection: .favorites, snapshot: snapshot)
        await forced.loadAll(useCachedPages: false)
        let validated = await finished(forced)
        XCTAssertEqual(validated.verified, 69)
        let after = await transport.stats()
        XCTAssertEqual(after.requests.count, 6)
    }
    func testSparseDetailsAreRepairedRatherThanSkippedByUseCachedPages() async throws {
        let root = temporaryTestRoot("warmer-sparse"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BatchedMetadataTransport(days: 1)
        let repository = try CachedPhotosRepository(credentials: .init(username: "warmer", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .favorites)
        let first = TimelineSectionCacheLoader(repository: repository, collection: .favorites, snapshot: snapshot)
        await first.loadAll(); _ = await finished(first)
        try await repository.store.evictMetadataDetails(namespace: repository.metadataNamespace, itemIDs: [1])
        let repair = TimelineSectionCacheLoader(repository: repository, collection: .favorites, snapshot: snapshot)
        await repair.loadAll(useCachedPages: true)
        let progress = await finished(repair)
        XCTAssertEqual(progress.cached, 0); XCTAssertEqual(progress.verified, 1)
        let details = await transport.detailCallCount()
        XCTAssertEqual(details, 1)
        let stats = await transport.stats()
        XCTAssertEqual(stats.requests.count, 1, "Known current membership needs only the one missing canonical detail")
    }
    func testFailedNetworkBatchesWaitForExplicitRetryAndRetainForcePolicy() async throws {
        let root = temporaryTestRoot("warmer-retry-policy"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BatchedMetadataTransport(days: 32)
        let repository = try CachedPhotosRepository(credentials: .init(username: "warmer", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .favorites)
        await transport.failNextTransport()
        let loader = TimelineSectionCacheLoader(repository: repository, collection: .favorites, snapshot: snapshot)
        await loader.loadAll(useCachedPages: false)
        let failed = await finished(loader)
        XCTAssertEqual(failed.failed, 32)
        let initialCalls = await transport.stats()
        XCTAssertEqual(initialCalls.requests.count, 1)
        await loader.retryFailed()
        let repaired = await finished(loader)
        XCTAssertEqual(repaired.verified, 32); XCTAssertEqual(repaired.failed, 0)
        let finalCalls = await transport.stats()
        XCTAssertEqual(finalCalls.requests.count, 2)
    }
}
