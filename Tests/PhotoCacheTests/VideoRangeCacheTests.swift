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
        let high = VideoPlaybackResource(unitID: 7, cacheKey: "r1", filename: nil,
                                         variant: .converted(.high))
        let medium = VideoPlaybackResource(unitID: 7, cacheKey: "r1", filename: nil,
                                           variant: .converted(.medium))
        let revised = VideoPlaybackResource(unitID: 7, cacheKey: "r2", filename: nil,
                                            variant: .converted(.high))
        XCTAssertNotEqual(CacheKey.videoSegment(namespace: namespace, resource: high, index: 0),
                          CacheKey.videoSegment(namespace: namespace, resource: medium, index: 0))
        XCTAssertNotEqual(CacheKey.videoSegment(namespace: namespace, resource: high, index: 0),
                          CacheKey.videoSegment(namespace: namespace, resource: revised, index: 0))
        XCTAssertNotEqual(CacheKey.videoSegment(namespace: namespace, resource: high, index: 0),
                          CacheKey.videoSegment(namespace: namespace, resource: high, index: 1))
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
        let resource = VideoPlaybackResource(unitID: 9, cacheKey: "revision", filename: "clip.mp4",
                                             variant: .converted(.medium))
        let offset = CachedPhotosRepository.videoSegmentSize - 2
        let first = try await repository.videoData(resource, offset: offset, length: 6)
        XCTAssertEqual(first.range, offset...(offset + 5))
        XCTAssertEqual(first.data, VideoRangeTestTransport.bytes(in: offset...(offset + 5)))
        let firstCallCount = await transport.callCount()
        XCTAssertEqual(firstCallCount, 2)

        let cached = try await repository.videoData(resource, offset: offset, length: 6,
                                                    allowNetwork: false)
        XCTAssertEqual(cached.data, first.data)
        let cachedCallCount = await transport.callCount()
        XCTAssertEqual(cachedCallCount, 2)
    }
}

private actor VideoRangeTestTransport: PhotosTransport {
    let totalLength: Int64
    private var ranges: [ClosedRange<Int64>] = []

    init(totalLength: Int64) {
        self.totalLength = totalLength
    }

    func videoRange(_ resource: VideoPlaybackResource,
                    range: ClosedRange<Int64>) async throws -> VideoRangeResponse {
        let upper = min(range.upperBound, totalLength - 1)
        let delivered = range.lowerBound...upper
        ranges.append(delivered)
        return VideoRangeResponse(data: Self.bytes(in: delivered), range: delivered,
                                  totalLength: totalLength, contentType: "video/mp4",
                                  etag: "revision", lastModified: nil)
    }

    func callCount() -> Int { ranges.count }

    nonisolated static func bytes(in range: ClosedRange<Int64>) -> Data {
        Data(range.map { UInt8($0 % 251) })
    }
}
