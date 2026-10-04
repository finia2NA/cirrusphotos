import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor RangeTransport: PhotosTransport {
    var pages: [Int: [PhotoItem]] = [:]
    var blockThumbnails = false
    var thumbnailCalls = 0

    func configure(pages: [Int: [PhotoItem]], blockThumbnails: Bool = false) {
        self.pages = pages
        self.blockThumbnails = blockThumbnails
    }
    func login(credentials: SynologyCredentials) async throws {}
    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot { TimelineSnapshot(sections: []) }
    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] { pages[section.offset] ?? [] }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        thumbnailCalls += 1
        if blockThumbnails { try await Task.sleep(for: .seconds(30)) }
        return ThumbnailResponse(data: Data([UInt8(truncatingIfNeeded: descriptor.unitID)]),
                                 etag: "test", lastModified: nil)
    }
}

final class ThumbnailRangeDownloaderTests: XCTestCase {
    private let credentials = SynologyCredentials(username: "range", password: "unused", otpSecret: "unused")
    private let server = URL(string: "https://range.example.invalid")!

    private func item(_ id: Int, ready: Bool = true) throws -> PhotoItem {
        let state = ready ? "ready" : "pending"
        let json = """
        {"id":\(id),"time":1711929600,"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key-\(id)","sm":"ready","m":"\(state)","xl":"pending"}}}
        """
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func snapshot() -> TimelineSnapshot {
        let days = [
            TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2),
            TimelineDay(year: 2024, month: 4, day: 2, itemCount: 3)
        ]
        return TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 3, list: days),
            TimelineSection(offset: 3, limit: 2, list: days),
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])
        ])
    }

    private func repository(transport: RangeTransport, root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    func testInclusiveRangeCountAndSplitMixedDaySelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoRangeTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RangeTransport()
        await transport.configure(pages: [
            0: [try item(1), try item(2), try item(3, ready: false)],
            3: [try item(4), try item(5)]
        ])
        let snapshot = snapshot()
        let range = ThumbnailDateRange(0, 1)
        XCTAssertEqual(range.estimatedThumbnailCount(in: snapshot), 5)
        XCTAssertEqual(range.dayIDs(in: snapshot), ["2024-04-03", "2024-04-02"])

        let downloader = ThumbnailRangeDownloader(repository: try repository(transport: transport, root: root))
        let first = await downloader.download(snapshot: snapshot, range: range, size: .m) { _ in }
        XCTAssertEqual(first.estimated, 5)
        XCTAssertEqual(first.processed, 5)
        XCTAssertEqual(first.fetched, 4)
        XCTAssertEqual(first.reused, 0)
        XCTAssertEqual(first.unavailable, 1)
        XCTAssertEqual(first.errors, 0)
        XCTAssertEqual(first.downloadedThumbnails, 4)
        XCTAssertEqual(first.downloadedBytes, 4)
        XCTAssertEqual(first.averageDownloadedThumbnailBytes, 1)
        XCTAssertEqual(first.estimatedDownloadBytes, 4)
        XCTAssertNotNil(first.bytesPerSecond)
        XCTAssertEqual(first.estimatedRemainingSeconds, 0)
        let firstCalls = await transport.thumbnailCalls
        XCTAssertEqual(firstCalls, 4)

        // A new repository has a new validation run. Manual warming should still reuse the
        // indexed exact files without issuing conditional requests for all of them.
        let secondDownloader = ThumbnailRangeDownloader(
            repository: try repository(transport: transport, root: root))
        let second = await secondDownloader.download(snapshot: snapshot, range: range, size: .m) { _ in }
        XCTAssertEqual(second.estimated, 5)
        XCTAssertEqual(second.processed, 5)
        XCTAssertEqual(second.fetched, 0)
        XCTAssertEqual(second.reused, 4)
        XCTAssertEqual(second.unavailable, 1)
        XCTAssertEqual(second.errors, 0)
        XCTAssertEqual(second.downloadedThumbnails, 0)
        XCTAssertEqual(second.downloadedBytes, 0)
        XCTAssertNil(second.averageDownloadedThumbnailBytes)
        XCTAssertNil(second.estimatedDownloadBytes)
        XCTAssertNil(second.bytesPerSecond)
        XCTAssertNil(second.estimatedRemainingSeconds)
        let secondCalls = await transport.thumbnailCalls
        XCTAssertEqual(secondCalls, 4)
    }

    func testRunMetricsProjectSizeSpeedAndRemainingTime() {
        var summary = ThumbnailBatchSummary(estimated: 10)
        summary.processed = 4
        summary.downloadedThumbnails = 2
        summary.downloadedBytes = 1_000
        summary.downloadElapsedSeconds = 2

        XCTAssertEqual(summary.averageDownloadedThumbnailBytes, 500)
        XCTAssertEqual(summary.estimatedDownloadBytes, 4_000)
        XCTAssertEqual(summary.bytesPerSecond, 500)
        XCTAssertEqual(summary.estimatedRemainingSeconds, 6)
    }

    func testChronologicalSliderMapsOldestLeftAndNewestRight() {
        let snapshot = snapshot()
        XCTAssertEqual(ThumbnailDateRange(chronologicalLower: 0, chronologicalUpper: 0, dayCount: 3)
            .dayIDs(in: snapshot), ["2024-04-01"])
        XCTAssertEqual(ThumbnailDateRange(chronologicalLower: 1, chronologicalUpper: 2, dayCount: 3)
            .dayIDs(in: snapshot), ["2024-04-03", "2024-04-02"])
    }

    func testCancellationStopsBoundedBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoRangeCancelTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RangeTransport()
        await transport.configure(pages: [0: [try item(1), try item(2), try item(3)]],
                                  blockThumbnails: true)
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 3,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3)])
        ])
        let downloader = ThumbnailRangeDownloader(repository: try repository(transport: transport, root: root),
                                                  workerCount: 2)
        let task = Task {
            await downloader.download(snapshot: snapshot, range: ThumbnailDateRange(0, 0), size: .m) { _ in }
        }
        for _ in 0..<200 {
            if await transport.thumbnailCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let startedCalls = await transport.thumbnailCalls
        XCTAssertEqual(startedCalls, 2)
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(result.processed, result.estimated)
        let finalCalls = await transport.thumbnailCalls
        XCTAssertLessThanOrEqual(finalCalls, 2)
    }
}
