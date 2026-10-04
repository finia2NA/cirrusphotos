import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class ViewerPlaylistTests: XCTestCase {
    private func item(_ id: Int64, favorite: Bool = true) throws -> PhotoItem {
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":\(id),\"time\":1711929600,\"type\":\"photo\"}".utf8))
        return decoded.withFavorite(favorite)
    }

    func testRemovedItemIsReinsertedAtItsOriginalOffset() throws {
        let section = TimelineSection(offset: 0, limit: 5,
                                      list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 8)])
        var playlist = ViewerPlaylist()
        playlist.record(item: try item(1), dayID: "2024-04-01", dayOffset: 1,
                        isFavorite: false)
        let plan = playlist.plan(for: section)

        XCTAssertEqual(plan.liveSection.offset, 0)
        XCTAssertEqual(plan.liveSection.limit, 4)
        XCTAssertEqual(playlist.reconstruct(try [item(0), item(2), item(3), item(4)], using: plan)
            .map(\.id), [0, 1, 2, 3, 4])
    }

    func testPriorAndCurrentPageRemovalsTranslateAnEvictedLaterPage() throws {
        let section = TimelineSection(offset: 5, limit: 3,
                                      list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 8)])
        var playlist = ViewerPlaylist()
        playlist.record(item: try item(1), dayID: "2024-04-01", dayOffset: 1,
                        isFavorite: false)
        playlist.record(item: try item(5), dayID: "2024-04-01", dayOffset: 5,
                        isFavorite: false)
        let plan = playlist.plan(for: section)

        XCTAssertEqual(plan.liveSection.offset, 4)
        XCTAssertEqual(plan.liveSection.limit, 2)
        XCTAssertEqual(playlist.reconstruct(try [item(6), item(7)], using: plan).map(\.id),
                       [5, 6, 7])
    }

    func testRefavoritedItemRemainsSingleFrozenMember() throws {
        let section = TimelineSection(offset: 0, limit: 4,
                                      list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 4)])
        var playlist = ViewerPlaylist()
        playlist.record(item: try item(2), dayID: "2024-04-01", dayOffset: 2,
                        isFavorite: false)
        playlist.record(item: try item(2), dayID: "2024-04-01", dayOffset: 2,
                        isFavorite: true)
        let plan = playlist.plan(for: section)

        XCTAssertEqual(plan.liveSection.limit, 4)
        XCTAssertEqual(playlist.reconstruct(try [item(0), item(1), item(2), item(3)], using: plan)
            .map(\.id), [0, 1, 2, 3])
    }

    func testRefavoritedItemBeforeLaterPageKeepsStableChronologicalOffset() throws {
        let section = TimelineSection(offset: 4, limit: 3,
                                      list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 8)])
        var playlist = ViewerPlaylist()
        playlist.record(item: try item(1), dayID: "2024-04-01", dayOffset: 1,
                        isFavorite: false)
        playlist.record(item: try item(1), dayID: "2024-04-01", dayOffset: 1,
                        isFavorite: true)
        let plan = playlist.plan(for: section)

        XCTAssertEqual(plan.liveSection.offset, 4)
        XCTAssertEqual(playlist.reconstruct(try [item(4), item(5), item(6)], using: plan)
            .map(\.id), [4, 5, 6])
    }
}
