import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor FallbackThumbnailTransport: PhotosTransport {
    private(set) var requestedSizes: [ThumbnailSize] = []
    var failuresRemaining = 0

    func failNextRequest() { failuresRemaining = 1 }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        requestedSizes.append(size)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestFailure("Thumbnail request failed")
        }
        return ThumbnailResponse(data: Data("network-\(size.rawValue)".utf8),
                                 etag: size.rawValue, lastModified: nil)
    }
}

final class ThumbnailFallbackCacheTests: XCTestCase {
    private let credentials = SynologyCredentials(username: "fallback", password: "unused", otpSecret: "unused")
    private let server = URL(string: "https://fallback.example.invalid")!

    private func root() -> URL { temporaryTestRoot("SynoFallbackCache") }

    private func descriptor(unitID: Int64 = 42, revision: String = "revision",
                            medium: String = "ready") throws -> ThumbnailInfo {
        try JSONDecoder().decode(ThumbnailInfo.self, from: Data("""
        {"unit_id":\(unitID),"cache_key":"\(revision)","sm":"ready","m":"\(medium)","xl":"ready"}
        """.utf8))
    }

    private func repository(root: URL, transport: FallbackThumbnailTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    func testGlobalRetentionOrderIsExplicit() {
        XCTAssertEqual(CachePriorityPolicy.highestToLowest, [
            .activeTimeline,
            .locationIndex,
            .metadataPage,
            .configuredThumbnail,
            .smallerFallbackThumbnail,
            .fullImage,
            .optionalThumbnail,
            .videoPlayback,
        ])
    }

    func testCachedSmallerRenditionDisplaysBeforeExactAndOnlyExactUsesNetwork() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FallbackThumbnailTransport()
        let repository = try repository(root: root, transport: transport)
        try await repository.setConfiguredThumbnailSize(.m)
        let descriptor = try descriptor()
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let small = CacheKey.thumbnailIdentity(scope: .space(.personal), namespace: namespace, descriptor: descriptor, size: .sm)
        try await repository.store.put(small.key, kind: .thumbnail, data: Data("cached-sm".utf8),
                                       validatedRun: "older-run", thumbnail: small)

        var values: [ThumbnailRenditionValue] = []
        for await event in await repository.thumbnailWithFallback(descriptor, size: .m,
                                                                   allowNetwork: true) {
            if case .value(let value, _) = event { values.append(value) }
        }

        XCTAssertEqual(values.map(\.size), [.sm, .m])
        XCTAssertEqual(values.map(\.isExact), [false, true])
        XCTAssertEqual(values.first?.data, Data("cached-sm".utf8))
        let requestedSizes = await transport.requestedSizes
        XCTAssertEqual(requestedSizes, [.m])
    }

    func testCachedFallbackStillDisplaysWhenExactRenditionIsNotServerReady() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FallbackThumbnailTransport()
        let repository = try repository(root: root, transport: transport)
        try await repository.setConfiguredThumbnailSize(.m)
        let descriptor = try descriptor(medium: "pending")
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let small = CacheKey.thumbnailIdentity(scope: .space(.personal), namespace: namespace, descriptor: descriptor, size: .sm)
        try await repository.store.put(small.key, kind: .thumbnail, data: Data("cached-sm".utf8),
                                       validatedRun: "older-run", thumbnail: small)

        var values: [ThumbnailRenditionValue] = []
        for await event in await repository.thumbnailWithFallback(descriptor, size: .m,
                                                                   allowNetwork: true) {
            if case .value(let value, _) = event { values.append(value) }
        }
        let requestedSizes = await transport.requestedSizes
        XCTAssertEqual(values.map(\.size), [.sm])
        XCTAssertTrue(requestedSizes.isEmpty)
    }

    func testFailedExactRequestPreservesFallbackAndCanBeRetried() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FallbackThumbnailTransport()
        await transport.failNextRequest()
        let repository = try repository(root: root, transport: transport)
        let descriptor = try descriptor()
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let small = CacheKey.thumbnailIdentity(scope: .space(.personal), namespace: namespace, descriptor: descriptor, size: .sm)
        try await repository.store.put(small.key, kind: .thumbnail, data: Data("cached-sm".utf8),
                                       validatedRun: "older-run", thumbnail: small)

        var firstValues: [ThumbnailRenditionValue] = []
        var failed = false
        for await event in await repository.thumbnailWithFallback(descriptor, size: .m, allowNetwork: true) {
            switch event {
            case .value(let value, _): firstValues.append(value)
            case .failure: failed = true
            }
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(firstValues.map(\.size), [.sm])

        var retriedValues: [ThumbnailRenditionValue] = []
        for await event in await repository.thumbnailWithFallback(descriptor, size: .m, allowNetwork: true) {
            if case .value(let value, _) = event { retriedValues.append(value) }
        }
        XCTAssertEqual(retriedValues.map(\.size), [.sm, .m])
        let requests = await transport.requestedSizes
        XCTAssertEqual(requests, [.m, .m])
    }

    func testManualCachingDoesNotTreatFallbackAsRequestedRendition() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FallbackThumbnailTransport()
        let repository = try repository(root: root, transport: transport)
        try await repository.setConfiguredThumbnailSize(.m)
        let descriptor = try descriptor()
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let small = CacheKey.thumbnailIdentity(scope: .space(.personal), namespace: namespace, descriptor: descriptor, size: .sm)
        try await repository.store.put(small.key, kind: .thumbnail, data: Data("cached-sm".utf8),
                                       validatedRun: "older-run", thumbnail: small)

        let first = try await repository.cacheThumbnail(descriptor, size: .m)
        let second = try await repository.cacheThumbnail(descriptor, size: .m)
        let requestedSizes = await transport.requestedSizes
        XCTAssertEqual(first, .fetched)
        XCTAssertEqual(second, .reused)
        XCTAssertEqual(requestedSizes, [.m])
    }

    func testExactArrivalMakesRedundantSmallerRenditionOptional() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 100)
        try await cache.setConfiguredThumbnailSize(.m)
        let small = ThumbnailCacheIdentity(key: "small", family: "family", size: .sm)
        let medium = ThumbnailCacheIdentity(key: "medium", family: "family", size: .m)

        try await cache.put(small.key, kind: .thumbnail, data: Data([1]), validatedRun: nil,
                            thumbnail: small)
        let initialSmallClass = try await cache.retentionClass(forKey: small.key)
        XCTAssertEqual(initialSmallClass, .smallerFallbackThumbnail)

        try await cache.put(medium.key, kind: .thumbnail, data: Data([2]), validatedRun: nil,
                            thumbnail: medium)
        let mediumClass = try await cache.retentionClass(forKey: medium.key)
        let finalSmallClass = try await cache.retentionClass(forKey: small.key)
        let retainedSmall = try await cache.get(small.key)
        XCTAssertEqual(mediumClass, .configuredThumbnail)
        XCTAssertEqual(finalSmallClass, .optionalThumbnail)
        XCTAssertNotNil(retainedSmall, "Reclassification must not eagerly delete the fallback")
    }

    func testLargerRenditionSurvivesDowngradeUntilBudgetPressure() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12)
        let large = ThumbnailCacheIdentity(key: "large", family: "family", size: .xl)
        let small = ThumbnailCacheIdentity(key: "small", family: "family", size: .sm)
        try await cache.setConfiguredThumbnailSize(.xl)
        try await cache.put(large.key, kind: .thumbnail, data: Data(repeating: 1, count: 4),
                            validatedRun: nil, thumbnail: large)

        try await cache.setConfiguredThumbnailSize(.sm)
        let retainedAfterSwitch = try await cache.get(large.key)
        let largeClass = try await cache.retentionClass(forKey: large.key)
        XCTAssertNotNil(retainedAfterSwitch)
        XCTAssertEqual(largeClass, .optionalThumbnail)
        try await cache.put(small.key, kind: .thumbnail, data: Data(repeating: 2, count: 4),
                            validatedRun: nil, thumbnail: small)
        try await cache.put("page", kind: .thumbnail, data: Data(repeating: 3, count: 4), validatedRun: nil)
        let retainedWithinBudget = try await cache.get(large.key)
        XCTAssertNotNil(retainedWithinBudget)

        try await cache.put("second-page", kind: .thumbnail, data: Data(repeating: 4, count: 4), validatedRun: nil)
        let evictedLarge = try await cache.get(large.key)
        let retainedSmall = try await cache.get(small.key)
        XCTAssertNil(evictedLarge)
        XCTAssertNotNil(retainedSmall)
    }

    func testSmallerFallbackOutranksOriginalAndOptionalLargerRendition() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12)
        try await cache.setConfiguredThumbnailSize(.m)
        let smaller = ThumbnailCacheIdentity(key: "small", family: "needs-medium", size: .sm)
        let larger = ThumbnailCacheIdentity(key: "large", family: "other", size: .xl)
        try await cache.put(smaller.key, kind: .thumbnail, data: Data(repeating: 1, count: 4),
                            validatedRun: nil, thumbnail: smaller)
        try await cache.put("original", kind: .fullImage, data: Data(repeating: 2, count: 4), validatedRun: nil)
        try await cache.put(larger.key, kind: .previewThumbnail, data: Data(repeating: 3, count: 4),
                            validatedRun: nil, thumbnail: larger)
        try await cache.put("page", kind: .thumbnail, data: Data(repeating: 4, count: 4), validatedRun: nil)

        let evictedLarger = try await cache.get(larger.key)
        let retainedOriginal = try await cache.get("original")
        let retainedSmaller = try await cache.get(smaller.key)
        XCTAssertNil(evictedLarger)
        XCTAssertNotNil(retainedOriginal)
        XCTAssertNotNil(retainedSmaller)

        try await cache.setBudget(8)
        let evictedOriginal = try await cache.get("original")
        let fallbackAfterPressure = try await cache.get(smaller.key)
        let pageAfterPressure = try await cache.get("page")
        XCTAssertNil(evictedOriginal)
        XCTAssertNotNil(fallbackAfterPressure)
        XCTAssertNotNil(pageAfterPressure)
    }
}
