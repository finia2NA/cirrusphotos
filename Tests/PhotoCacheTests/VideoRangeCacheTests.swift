import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class VideoRangeCacheTests: XCTestCase {
    func testSegmentEnvelopeRoundTripsRawBytesAndMetadata() throws {
        let response = VideoRangeResponse(data: Data([1, 2, 3, 4]), range: 8...11,
                                          totalLength: 20, contentType: "video/mp4",
                                          etag: "tag", lastModified: "date")
        let encoded = try CachedVideoSegment(response: response).encoded()
        let decoded = try CachedVideoSegment(encoded: encoded)
        XCTAssertEqual(decoded.header.rangeLower, 8)
        XCTAssertEqual(decoded.header.rangeUpper, 11)
        XCTAssertEqual(decoded.header.totalLength, 20)
        XCTAssertEqual(decoded.header.contentType, "video/mp4")
        XCTAssertEqual(decoded.data, Data([1, 2, 3, 4]))
    }

    func testVideoSegmentsAreLowestRetentionAndSurviveMetadataClear() async throws {
        let root = temporaryTestRoot("VideoSegmentCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 1_000_000)
        try await cache.put("video", kind: .videoSegment, data: Data([1, 2, 3]),
                            validatedRun: "run")
        try await cache.put("preview", kind: .previewThumbnail, data: Data([4]),
                            validatedRun: "run")
        let videoRetentionClass = try await cache.retentionClass(forKey: "video")
        let previewRetentionClass = try await cache.retentionClass(forKey: "preview")
        XCTAssertEqual(videoRetentionClass, .videoPlayback)
        XCTAssertEqual(previewRetentionClass, .optionalThumbnail)
        XCTAssertLessThan(CachePriorityPolicy.evictionRank(for: .videoPlayback),
                          CachePriorityPolicy.evictionRank(for: .optionalThumbnail))
        _ = try await cache.clearMetadata()
        let retainedVideo = try await cache.get("video")
        XCTAssertNotNil(retainedVideo)
    }

    func testVideoCacheKeysIsolateQualityRevisionAndSegment() {
        let namespace = "account"
        let high = VideoPlaybackResource(scope: .space(.personal), unitID: 7, cacheKey: "r1", filename: nil,
                                         variant: .converted(.high))
        let medium = VideoPlaybackResource(scope: .space(.personal), unitID: 7, cacheKey: "r1", filename: nil,
                                           variant: .converted(.medium))
        let revised = VideoPlaybackResource(scope: .space(.personal), unitID: 7, cacheKey: "r2", filename: nil,
                                            variant: .converted(.high))
        XCTAssertNotEqual(CacheKey.videoSegment(namespace: namespace, resource: high, index: 0),
                          CacheKey.videoSegment(namespace: namespace, resource: medium, index: 0))
        XCTAssertNotEqual(CacheKey.videoSegment(namespace: namespace, resource: high, index: 0),
                          CacheKey.videoSegment(namespace: namespace, resource: revised, index: 0))
        XCTAssertNotEqual(CacheKey.videoSegment(namespace: namespace, resource: high, index: 0),
                          CacheKey.videoSegment(namespace: namespace, resource: high, index: 1))
    }

    func testRepositoryDeliversBeforeWindowFinishesAndDoesNotCacheTruncatedWindow() async throws {
        let root = temporaryTestRoot("VideoProgressive")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = expectation(description: "first bytes delivered")
        let transport = BlockingVideoTransport()
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "video", password: "unused"),
            baseURL: URL(string: "https://photos.invalid")!, budget: 8 * 1_024 * 1_024,
            cacheRoot: root, transport: transport)
        let resource = VideoPlaybackResource(scope: .space(.personal), unitID: 9, cacheKey: "r", filename: nil, variant: .original)
        let task = Task {
            try await repository.streamVideoData(resource, offset: 0, length: 131_072) { value in
                if value.range.lowerBound == 0 { first.fulfill() }
            }
        }
        await fulfillment(of: [first], timeout: 5)
        await transport.finishWithTruncation()
        do { try await task.value; XCTFail("Truncated response must fail") } catch { }
        do {
            try await repository.streamVideoData(resource, offset: 0, length: 1, allowNetwork: false) { _ in }
            XCTFail("Incomplete window must not be cached")
        } catch { }
    }

    func testRepositoryDownloadsAlignedSegmentsAndReusesThemOffline() async throws {
        let root = temporaryTestRoot("VideoRangeRepository")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = VideoRangeTestTransport(totalLength: CachedPhotosRepository.videoSegmentSize * 2 + 19)
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "video", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://photos.invalid")!,
            budget: 8 * 1_024 * 1_024,
            cacheRoot: root,
            transport: transport
        )
        let resource = VideoPlaybackResource(scope: .space(.personal), unitID: 9, cacheKey: "revision", filename: "clip.mp4",
                                             variant: .converted(.medium))
        let offset = CachedPhotosRepository.videoSegmentSize - 2
        let first = VideoDataCollector()
        try await repository.streamVideoData(resource, offset: offset, length: 6) { value in await first.append(value.data) }
        let firstBytes = await first.data
        XCTAssertEqual(firstBytes, VideoRangeTestTransport.bytes(in: offset...(offset + 5)))
        let firstCallCount = await transport.callCount()
        XCTAssertEqual(firstCallCount, 1)

        let cached = VideoDataCollector()
        try await repository.streamVideoData(resource, offset: offset, length: 6, allowNetwork: false) { value in await cached.append(value.data) }
        let cachedBytes = await cached.data
        XCTAssertEqual(cachedBytes, firstBytes)
        let cachedCallCount = await transport.callCount()
        XCTAssertEqual(cachedCallCount, 1)
    }
}

private actor VideoRangeTestTransport: PhotosTransport {
    let totalLength: Int64
    private var ranges: [ClosedRange<Int64>] = []

    init(totalLength: Int64) {
        self.totalLength = totalLength
    }

    func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>,
                          receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws {
        let upper = min(range.upperBound, totalLength - 1)
        let delivered = range.lowerBound...upper
        ranges.append(delivered)
        try await receive(.header(VideoRangeHeader(range: delivered, totalLength: totalLength,
                                                  contentType: "video/mp4", etag: "revision", lastModified: nil)))
        try await receive(.bytes(offset: delivered.lowerBound, data: Self.bytes(in: delivered)))
    }

    func callCount() -> Int { ranges.count }

    nonisolated static func bytes(in range: ClosedRange<Int64>) -> Data {
        Data(range.map { UInt8($0 % 251) })
    }
}

private actor VideoDataCollector {
    var data = Data()
    func append(_ value: Data) { data.append(value) }
}

private actor BlockingVideoTransport: PhotosTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>,
                          receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws {
        try await receive(.header(VideoRangeHeader(range: range, totalLength: range.upperBound + 1,
                                                  contentType: "video/mp4", etag: nil, lastModified: nil)))
        try await receive(.bytes(offset: range.lowerBound, data: Data(repeating: 1, count: 16_384)))
        if !released { await withCheckedContinuation { continuation = $0 } }
        // The repository must reject an apparently successful but truncated transport.
    }

    func finishWithTruncation() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
