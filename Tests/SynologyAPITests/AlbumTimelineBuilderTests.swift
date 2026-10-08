import Foundation
import TimelineCore
import XCTest
@testable import SynologyAPI

final class AlbumTimelineBuilderTests: XCTestCase {
    private func entries(_ times: [Int64]) -> [DayTimelineEntry] {
        times.enumerated().map { DayTimelineEntry(id: Int64($0.offset), time: $0.element) }
    }

    func testEmptyInputProducesNoSections() {
        let built = DayGroupedTimelineBuilder.build(entries: [])
        XCTAssertTrue(built.snapshot.sections.isEmpty)
        XCTAssertTrue(built.itemIDsBySection.isEmpty)
    }

    func testGroupsByUTCDayAndPreservesFirstEncounterOrder() {
        let day1 = Int64(1_704_067_200)   // 2024-01-01
        let day2 = day1 + 86_400           // 2024-01-02
        let built = DayGroupedTimelineBuilder.build(entries: entries([
            day2 + 10, day2 + 20, day1 + 5, day2 + 30, day1 + 6,
        ]))
        let snapshot = built.snapshot
        XCTAssertEqual(snapshot.sections.count, 2)
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-02", "2024-01-01"])
        XCTAssertEqual(snapshot.sections[0].list, [TimelineDay(year: 2024, month: 1, day: 2, itemCount: 3)])
        XCTAssertEqual(snapshot.sections[0].offset, 0)
        XCTAssertEqual(snapshot.sections[0].limit, 3)
        XCTAssertEqual(snapshot.sections[1].list, [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 2)])
        XCTAssertEqual(built.itemIDsBySection, [[0, 1, 3], [2, 4]])
    }

    func testDayBoundaryUsesGMT() {
        let built = DayGroupedTimelineBuilder.build(entries: entries([
            1_704_067_199,   // 2023-12-31T23:59:59Z
            1_704_067_200,   // 2024-01-01T00:00:00Z
        ]))
        XCTAssertEqual(built.snapshot.timeline.days.map(\.id), ["2024-01-01", "2023-12-31"])
    }

    func testSingleDayOverLimitSplitsIntoConsecutiveSections() {
        let base = Int64(1_704_067_200)
        let times = (0..<1500).map { base + Int64($0) }
        let built = DayGroupedTimelineBuilder.build(entries: entries(times))
        let snapshot = built.snapshot
        XCTAssertEqual(snapshot.sections.count, 2)
        let day = TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1500)
        XCTAssertEqual(snapshot.sections[0], TimelineSection(offset: 0, limit: 1000, list: [day]))
        XCTAssertEqual(snapshot.sections[1], TimelineSection(offset: 1000, limit: 500, list: [day]))
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-01"])
        XCTAssertEqual(snapshot.timeline.days.map(\.count), [1500])
        XCTAssertEqual(built.itemIDsBySection[0], Array(0..<1000).map(Int64.init))
        XCTAssertEqual(built.itemIDsBySection[1], Array(1000..<1500).map(Int64.init))
    }

    func testExactlyAtLimitIsNotSplit() {
        let base = Int64(1_704_067_200)
        let times = (0..<1000).map { base + Int64($0) }
        let built = DayGroupedTimelineBuilder.build(entries: entries(times))
        XCTAssertEqual(built.snapshot.sections.count, 1)
        XCTAssertEqual(built.snapshot.sections[0].offset, 0)
        XCTAssertEqual(built.snapshot.sections[0].limit, 1000)
        XCTAssertEqual(built.itemIDsBySection, [Array(0..<1000).map(Int64.init)])
    }

    func testCustomSectionLimitSplitsSmaller() {
        let base = Int64(1_704_067_200)
        let times = (0..<600).map { base + Int64($0) }
        let built = DayGroupedTimelineBuilder.build(entries: entries(times), sectionLimit: 250)
        XCTAssertEqual(built.snapshot.sections.map(\.limit), [250, 250, 100])
        XCTAssertEqual(built.snapshot.sections.map(\.offset), [0, 250, 500])
        XCTAssertEqual(built.itemIDsBySection.count, 3)
        XCTAssertEqual(built.itemIDsBySection[2], Array(500..<600).map(Int64.init))
    }
}
