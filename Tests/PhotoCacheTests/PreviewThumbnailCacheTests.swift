import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor PreviewThumbnailTransport: TestPhotosTransport {
    private var releaseResponse = false
    private(set) var thumbnailCalls = 0

    func releaseThumbnail() { releaseResponse = true }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   space: PhotoSpace) async throws -> Data {
        thumbnailCalls += 1
        while !releaseResponse { try await Task.sleep(for: .milliseconds(2)) }
        return Data([4, 2])
    }
}

private func consumePreviewStream(_ stream: AsyncStream<ResourceEvent<Data>>) async -> Data? {
    var latest: Data?
    for await event in stream {
        if case .value(let data, _) = event { latest = data }
    }
    return latest
}

final class PreviewThumbnailCacheTests: XCTestCase {
    private let credentials = SynologyCredentials(username: "preview", password: "unused", otpSecret: "unused")
    private let server = URL(string: "https://preview.example.invalid")!

    private func root() -> URL { temporaryTestRoot("SynoPreviewCache") }

    private func descriptor() throws -> ThumbnailInfo {
        try JSONDecoder().decode(ThumbnailInfo.self, from: Data("""
        {"unit_id":42,"cache_key":"revision","sm":"ready","m":"ready","xl":"ready"}
        """.utf8))
    }

    func testPreviewEvictsBeforeFullImage() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = try DiskCache(root: cacheRoot, budget: 20)
        try await cache.put("timeline", kind: .thumbnail, data: Data(repeating: 1, count: 4), validatedRun: nil)
        try await cache.put("page", kind: .thumbnail, data: Data(repeating: 2, count: 4), validatedRun: nil)
        try await cache.put("thumbnail", kind: .thumbnail, data: Data(repeating: 3, count: 4), validatedRun: nil)
        try await cache.put("full", kind: .fullImage, data: Data(repeating: 4, count: 4), validatedRun: nil)
        try await cache.put("preview", kind: .previewThumbnail, data: Data(repeating: 5, count: 4), validatedRun: nil)
        try await cache.put("another-page", kind: .thumbnail, data: Data(repeating: 6, count: 4), validatedRun: nil)

        let evictedPreview = try await cache.get("preview")
        let retainedFull = try await cache.get("full")
        XCTAssertNil(evictedPreview)
        XCTAssertNotNil(retainedFull)
        try await cache.setBudget(16)
        let evictedFull = try await cache.get("full")
        let retainedThumbnail = try await cache.get("thumbnail")
        let retainedPage = try await cache.get("page")
        let retainedTimeline = try await cache.get("timeline")
        XCTAssertNil(evictedFull)
        XCTAssertNotNil(retainedThumbnail)
        XCTAssertNotNil(retainedPage)
        XCTAssertNotNil(retainedTimeline)
    }

    func testPreviewWriteCannotDemoteOrdinaryThumbnail() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = try DiskCache(root: cacheRoot, budget: 100)
        try await cache.put("shared", kind: .thumbnail, data: Data([1]), validatedRun: "one")
        try await cache.put("shared", kind: .previewThumbnail, data: Data([2]), validatedRun: "two")
        let cached = try await cache.get("shared")
        let entry = try XCTUnwrap(cached)
        XCTAssertEqual(entry.kind, .thumbnail)
        XCTAssertEqual(entry.data, Data([2]))
    }

    func testOrdinaryDemandJoinsPreviewFetchAndPromotesWithoutRedownload() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = PreviewThumbnailTransport()
        let repository = try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                                     cacheRoot: cacheRoot, transport: transport)
        let descriptor = try descriptor()
        let preview = Task {
            await consumePreviewStream(repository.thumbnail(descriptor, size: .xl, allowNetwork: true, collection: .library(.personal),
                                                            cachePurpose: .viewerPreview))
        }
        while await transport.thumbnailCalls == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let ordinary = Task {
            await consumePreviewStream(repository.thumbnail(descriptor, size: .xl, allowNetwork: true, collection: .library(.personal),
                                                            cachePurpose: .library))
        }
        await transport.releaseThumbnail()
        let previewData = await preview.value
        let ordinaryData = await ordinary.value
        let joinedCalls = await transport.thumbnailCalls
        XCTAssertEqual(previewData, Data([4, 2]))
        XCTAssertEqual(ordinaryData, Data([4, 2]))
        XCTAssertEqual(joinedCalls, 1)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = CacheKey.thumbnail(scope: .space(.personal), namespace: namespace, descriptor: descriptor, size: .xl, collection: .library(.personal))
        let cachedEntry = try await repository.store.get(key)
        let entry = try XCTUnwrap(cachedEntry)
        XCTAssertEqual(entry.kind, .thumbnail)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            cacheRoot.appendingPathComponent("images/\(key).img").path))

        _ = await consumePreviewStream(repository.thumbnail(descriptor, size: .xl, allowNetwork: true, collection: .library(.personal),
                                                            cachePurpose: .viewerPreview))
        let finalCalls = await transport.thumbnailCalls
        let finalKind = try await repository.store.get(key)?.kind
        XCTAssertEqual(finalCalls, 1)
        XCTAssertEqual(finalKind, .thumbnail)
    }
}
