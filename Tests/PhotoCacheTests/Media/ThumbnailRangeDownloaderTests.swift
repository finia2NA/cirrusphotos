import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor RangeTransport: TestPhotosTransport {
    var pages: [Int: [PhotoItem]] = [:]
    var blockThumbnails = false
    var thumbnailCalls = 0
    var blockPages = false
    var pageCalls = 0
    private var pageStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedPageContinuations: [CheckedContinuation<Void, Never>] = []

    func configure(pages: [Int: [PhotoItem]], blockThumbnails: Bool = false,
                   blockPages: Bool = false) {
        self.pages = pages
        self.blockThumbnails = blockThumbnails
        self.blockPages = blockPages
    }
    func waitUntilPageRequested() async {
        if pageCalls > 0 { return }
        await withCheckedContinuation { pageStartWaiters.append($0) }
    }
    func releasePages() {
        blockPages = false
        let waiters = blockedPageContinuations
        blockedPageContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: pages.keys.sorted().enumerated().map { index, key in
            try CollectionDayCount(day: CaptureDay(year: 2024, month: 4, day: 3-index), count: pages[key]!.count)
        }, completeness: initial ? .partial : .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {

        pageCalls += 1
        for waiter in pageStartWaiters { waiter.resume() }
        pageStartWaiters.removeAll()
        if blockPages {
            await withCheckedContinuation { blockedPageContinuations.append($0) }
        }
        var rows: [PhotoItem] = []
        for (index, key) in pages.keys.sorted().enumerated() {
            let day = try CaptureDay(year: 2024, month: 4, day: 3-index)
            if day <= request.newestDay && day >= request.oldestDay {
                rows += try pages[key]!.map { try fixtureItem($0, on: day) }
            }
        }
        return CollectionBatchResult(items: rows, profile: fields)
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   space: PhotoSpace) async throws -> Data {
        thumbnailCalls += 1
        if blockThumbnails { try await Task.sleep(for: .seconds(30)) }
        return Data([UInt8(truncatingIfNeeded: descriptor.unitID)])
    }
}

final class ThumbnailRangeDownloaderTests: XCTestCase {
    private let credentials = SynologyCredentials(username: "range", password: "unused")
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
            TimelineSection(offset: 0, limit: 2, list: [days[0]]),
            TimelineSection(offset: 0, limit: 3, list: [days[1]]),
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])
        ])
    }

    private func repository(transport: RangeTransport, root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    func testFullCachePausesBeforeDownloading() async throws {
        let root = temporaryTestRoot("SynoRangePause")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RangeTransport()
        await transport.configure(pages: [0: [try item(1), try item(2)]])
        let repository = try CachedPhotosRepository(credentials: credentials, baseURL: server, budget: 1_000_000,
                                                    cacheRoot: root, transport: transport)
        let downloader = ThumbnailRangeDownloader(repository: repository)
        let summary = await downloader.download(snapshot: snapshot(), range: ThumbnailDateRange(0, 1), size: .m,
                                                collection: .library(.personal)) { _ in }
        XCTAssertTrue(summary.budgetReached)
        XCTAssertEqual(summary.processed, 0)
        let calls = await transport.thumbnailCalls
        XCTAssertEqual(calls, 0)
    }

    func testInclusiveRangeCountAndSplitMixedDaySelection() async throws {
        let root = temporaryTestRoot("SynoRangeTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RangeTransport()
        await transport.configure(pages: [
            0: [try item(1), try item(2)],
            3: [try item(3, ready: false), try item(4), try item(5)]
        ])
        let snapshot = snapshot()
        let range = ThumbnailDateRange(0, 1)
        XCTAssertEqual(range.estimatedThumbnailCount(in: snapshot), 5)
        XCTAssertEqual(range.dayIDs(in: snapshot), ["2024-04-03", "2024-04-02"])

        let clock = TestClock()
        let downloader = ThumbnailRangeDownloader(repository: try repository(transport: transport, root: root),
                                                  now: { clock.tick() })
        let first = await downloader.download(snapshot: snapshot, range: range, size: .m, collection: .library(.personal)) { _ in }
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
            repository: try repository(transport: transport, root: root), now: { clock.tick() })
        let second = await secondDownloader.download(snapshot: snapshot, range: range, size: .m, collection: .library(.personal)) { _ in }
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
        XCTAssertEqual(second.estimatedRemainingSeconds, 0)
        let secondCalls = await transport.thumbnailCalls
        XCTAssertEqual(secondCalls, 4)
    }

    func testRunMetricsProjectWholeRunAverages() {
        var summary = ThumbnailBatchSummary(estimated: 100)
        summary.processed = 20
        summary.downloadedThumbnails = 10
        summary.downloadedBytes = 10_000
        summary.elapsedSeconds = 4

        // Half of the processed items were cache hits, so 1,000 bytes per downloaded
        // thumbnail projects 500 bytes per remaining item.
        XCTAssertEqual(summary.averageDownloadedThumbnailBytes, 1_000)
        XCTAssertEqual(summary.estimatedDownloadBytes, 50_000)
        XCTAssertEqual(summary.bytesPerSecond, 2_500)
        XCTAssertEqual(summary.estimatedRemainingSeconds, 16)
    }

    func testRunMetricsWaitForMinimumSample() {
        var summary = ThumbnailBatchSummary(estimated: 100)
        summary.processed = ThumbnailBatchSummary.minimumSample - 1
        summary.downloadedThumbnails = 1
        summary.downloadedBytes = 1_000
        summary.elapsedSeconds = 1

        XCTAssertEqual(summary.averageDownloadedThumbnailBytes, 1_000)
        XCTAssertNil(summary.estimatedDownloadBytes)
        XCTAssertNil(summary.bytesPerSecond)
        XCTAssertNil(summary.estimatedRemainingSeconds)
    }

    func testChronologicalSliderMapsOldestLeftAndNewestRight() {
        let snapshot = snapshot()
        XCTAssertEqual(ThumbnailDateRange(chronologicalLower: 0, chronologicalUpper: 0, dayCount: 3)
            .dayIDs(in: snapshot), ["2024-04-01"])
        XCTAssertEqual(ThumbnailDateRange(chronologicalLower: 1, chronologicalUpper: 2, dayCount: 3)
            .dayIDs(in: snapshot), ["2024-04-03", "2024-04-02"])
    }

    func testCancellationStopsBoundedBatch() async throws {
        let root = temporaryTestRoot("SynoRangeCancelTest")
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
            await downloader.download(snapshot: snapshot, range: ThumbnailDateRange(0, 0), size: .m, collection: .library(.personal)) { _ in }
        }
        for _ in 0..<200 {
            // Both bounded workers start independently; wait for the second before asserting.
            if await transport.thumbnailCalls >= 2 { break }
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

    func testMetadataResetInterruptsRangeResolutionWithoutStartingThumbnails() async throws {
        let root = temporaryTestRoot("SynoRangeResetTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RangeTransport()
        await transport.configure(pages: [0: [try item(1)]], blockPages: true)
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let repository = try repository(transport: transport, root: root)
        let downloader = ThumbnailRangeDownloader(repository: repository)
        let task = Task {
            await downloader.download(snapshot: snapshot, range: ThumbnailDateRange(0, 0), size: .m, collection: .library(.personal)) { _ in }
        }
        await transport.waitUntilPageRequested()

        try await repository.clearMetadataCache()
        await transport.releasePages()
        let result = await task.value

        XCTAssertTrue(result.interrupted)
        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(result.errors, 0)
        let thumbnailCalls = await transport.thumbnailCalls
        XCTAssertEqual(thumbnailCalls, 0)
    }
}

/// Advances one second per reading so elapsed time is deterministic and positive.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func tick() -> TimeInterval { lock.withLock { value += 1; return value } }
}
