import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor ScopedWarmingTransport: PhotosTransport {
    var spaces: [PhotoSpace] = []
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        spaces.append(space)
        return ThumbnailResponse(data: Data("fixture-thumbnail".utf8), etag: nil, lastModified: nil)
    }
}

final class ThumbnailWarmingPlanTests: XCTestCase, @unchecked Sendable {
    private func snapshot(_ entries: [(day: Int, count: Int)]) -> TimelineSnapshot {
        TimelineSnapshot(sections: entries.map { entry in
            TimelineSection(offset: 0, limit: entry.count,
                list: [TimelineDay(year: 2024, month: 1, day: entry.day, itemCount: entry.count)])
        })
    }
    func testUnionCountsOverlappingDatesAndRangeIncludesSharedOnlyDates() {
        let personal = snapshot([(4, 1), (2, 3)])
        let shared = snapshot([(5, 2), (4, 2), (1, 1)])
        let combined = ThumbnailWarmingPlan.combinedSnapshot([personal, shared])
        XCTAssertEqual(combined.timeline.days.map(\.id), ["2024-01-05", "2024-01-04", "2024-01-02", "2024-01-01"])
        XCTAssertEqual(combined.timeline.days.map(\.count), [2, 3, 3, 1])
        let range = ThumbnailWarmingPlan.range(in: shared, from: "2024-01-02", through: "2024-01-05")
        XCTAssertEqual(range?.dayIDs(in: shared), ["2024-01-05", "2024-01-04"])
        XCTAssertNil(ThumbnailWarmingPlan.range(in: personal, from: "2024-01-05", through: "2024-01-05"))
    }

    func testSharedThumbnailWarmingNeverReusesPersonalCacheIdentity() async throws {
        let root = temporaryTestRoot("scoped-warming"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScopedWarmingTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "warm", password: "unused"), cacheRoot: root, transport: transport)
        let thumbnail = ThumbnailInfo(unitID: 1, cacheKey: "same-key")
        _ = try await repository.cacheThumbnailMeasurement(thumbnail, size: .sm, collection: .personalLibrary, validateCached: false)
        let shared = try await repository.cacheThumbnailMeasurement(thumbnail, size: .sm, collection: .sharedLibrary, validateCached: false)
        let cached = try await repository.cacheThumbnailMeasurement(thumbnail, size: .sm, collection: .sharedLibrary, validateCached: false)
        XCTAssertEqual(shared.outcome, .fetched)
        XCTAssertEqual(cached.outcome, .reused)
        let spaces = await transport.spaces
        XCTAssertEqual(spaces, [.personal, .shared])
    }
}
