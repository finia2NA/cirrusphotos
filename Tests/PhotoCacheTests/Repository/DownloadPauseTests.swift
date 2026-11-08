import Foundation
import XCTest
@testable import PhotoCache

final class DownloadPauseTests: XCTestCase {
    private let megabyte = 1_000_000

    func testPausesOnlyWhenKeptDataNearsTheLimit() async throws {
        let root = temporaryTestRoot("DownloadPause")
        defer { try? FileManager.default.removeItem(at: root) }
        // 20 MB: no reserve, 1 MB margin.
        let cache = try DiskCache(root: root, budget: 20_000_000)
        try await cache.put("video", kind: .videoSegment, data: Data(count: 10 * megabyte), validatedRun: nil)
        try await cache.put("t1", kind: .thumbnail, data: Data(count: 5 * megabyte), validatedRun: nil)
        // Video would be evicted before thumbnails, so it does not count against the download.
        var paused = try await cache.downloadShouldPause()
        XCTAssertFalse(paused)

        try await cache.put("t2", kind: .thumbnail, data: Data(count: 10 * megabyte), validatedRun: nil)
        paused = try await cache.downloadShouldPause()
        XCTAssertFalse(paused)
        try await cache.put("t3", kind: .thumbnail, data: Data(count: 4 * megabyte), validatedRun: nil)
        paused = try await cache.downloadShouldPause()
        XCTAssertTrue(paused)
        // Pausing evicted no kept thumbnail.
        let t1 = try await cache.get("t1")
        XCTAssertNotNil(t1)

        try await cache.setBudget(40_000_000)
        paused = try await cache.downloadShouldPause()
        XCTAssertFalse(paused)
    }

    func testNoPauseWithRoomAndRepeatedChecksStayInMemory() async throws {
        let root = temporaryTestRoot("DownloadPauseRoom")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 100_000_000)
        var paused = try await cache.downloadShouldPause()
        XCTAssertFalse(paused)
        for index in 0..<50 {
            try await cache.put("t\(index)", kind: .thumbnail, data: Data(count: 1_000), validatedRun: nil)
            paused = try await cache.downloadShouldPause()
            XCTAssertFalse(paused)
        }
    }
}
