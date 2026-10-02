import XCTest
@testable import TimelineCore

final class TimelineTests: XCTestCase {
    func testSplitDaysDeduplicateAndKeepFirstSection() {
        let timeline = Timeline(days: [
            LibraryDay(year: 2024, month: 1, day: 1, count: 401, section: 4),
            LibraryDay(year: 2024, month: 1, day: 1, count: 400, section: 3),
            LibraryDay(year: 2025, month: 2, day: 1, count: 1, section: 0)
        ])
        XCTAssertEqual(timeline.days.count, 2)
        XCTAssertEqual(timeline.days.first?.year, 2025)
        XCTAssertEqual(timeline.days.last?.section, 3)
        XCTAssertEqual(timeline.days.last?.count, 401)
        XCTAssertEqual(timeline.index(at: 0.49), 0)
        XCTAssertEqual(timeline.index(at: 0.5), 1)
    }

    func testHitMappingClampsAndRoundTrips() {
        let timeline = Timeline(days: (1...31).map {
            LibraryDay(year: 2025, month: 1, day: $0, count: $0, section: 0)
        })
        XCTAssertEqual(timeline.index(at: -1), 0)
        XCTAssertEqual(timeline.index(at: 1), 30)
        XCTAssertEqual(timeline.index(at: 2), 30)
        XCTAssertNil(timeline.index(at: .nan))
        for index in timeline.days.indices {
            XCTAssertEqual(timeline.index(at: timeline.fraction(at: index)), index)
        }
        XCTAssertNil(Timeline(days: []).index(at: 0.5))
    }

    func testDateSelectionFallsBackToNearestOlderAndHandlesEmptyIndex() {
        let timeline = Timeline(days: [
            LibraryDay(year: 2025, month: 1, day: 9, count: 1, section: 0),
            LibraryDay(year: 2025, month: 1, day: 5, count: 1, section: 1),
            LibraryDay(year: 2025, month: 1, day: 1, count: 1, section: 2)
        ])
        XCTAssertEqual(timeline.index(keeping: "2025-01-09"), 0)
        XCTAssertEqual(timeline.index(keeping: "2025-01-07"), 1)
        XCTAssertEqual(timeline.index(keeping: "2024-12-31"), 2)
        XCTAssertEqual(timeline.index(keeping: nil), 0)
        XCTAssertNil(Timeline(days: []).index(keeping: "2025-01-07"))
    }

    func testRepeatedDayJumpHasNewIdentity() {
        let first = DayJumpRequest(dayID: "2025-01-05")
        let second = DayJumpRequest(dayID: "2025-01-05")
        XCTAssertEqual(first.dayID, second.dayID)
        XCTAssertNotEqual(first, second)
    }
}
