import Foundation
import TimelineCore
import XCTest
@testable import SynologyAPI

final class AlbumTimelineBuilderTests: XCTestCase {
    private func entries(_ times: [Int64]) -> [AlbumScanEntry] {
        times.enumerated().map { AlbumScanEntry(id: Int64($0.offset), time: $0.element) }
    }

    func testEmptyInputProducesNoSections() {
        XCTAssertTrue(AlbumTimelineBuilder.snapshot(entries: []).sections.isEmpty)
    }

    func testGroupsByUTCDayAndPreservesFirstEncounterOrder() {
        let day1 = Int64(1_704_067_200)   // 2024-01-01
        let day2 = day1 + 86_400           // 2024-01-02
        let snapshot = AlbumTimelineBuilder.snapshot(entries: entries([
            day2 + 10, day2 + 20, day1 + 5, day2 + 30, day1 + 6,
        ]))
        XCTAssertEqual(snapshot.sections.count, 2)
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-02", "2024-01-01"])
        XCTAssertEqual(snapshot.sections[0].list, [TimelineDay(year: 2024, month: 1, day: 2, itemCount: 3)])
        XCTAssertEqual(snapshot.sections[0].offset, 0)
        XCTAssertEqual(snapshot.sections[0].limit, 3)
        XCTAssertEqual(snapshot.sections[1].list, [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 2)])
    }

    func testDayBoundaryUsesGMT() {
        let snapshot = AlbumTimelineBuilder.snapshot(entries: entries([
            1_704_067_199,   // 2023-12-31T23:59:59Z
            1_704_067_200,   // 2024-01-01T00:00:00Z
        ]))
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-01", "2023-12-31"])
    }

    func testSingleDayOverLimitSplitsIntoConsecutiveSections() {
        let base = Int64(1_704_067_200)
        let times = (0..<1500).map { base + Int64($0) }
        let snapshot = AlbumTimelineBuilder.snapshot(entries: entries(times))
        XCTAssertEqual(snapshot.sections.count, 2)
        let day = TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1500)
        XCTAssertEqual(snapshot.sections[0], TimelineSection(offset: 0, limit: 1000, list: [day]))
        XCTAssertEqual(snapshot.sections[1], TimelineSection(offset: 1000, limit: 500, list: [day]))
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-01"])
        XCTAssertEqual(snapshot.timeline.days.map(\.count), [1500])
    }

    func testExactlyAtLimitIsNotSplit() {
        let base = Int64(1_704_067_200)
        let times = (0..<1000).map { base + Int64($0) }
        let snapshot = AlbumTimelineBuilder.snapshot(entries: entries(times))
        XCTAssertEqual(snapshot.sections.count, 1)
        XCTAssertEqual(snapshot.sections[0].offset, 0)
        XCTAssertEqual(snapshot.sections[0].limit, 1000)
    }
}
