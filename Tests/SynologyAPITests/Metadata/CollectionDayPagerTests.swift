import Foundation
import XCTest
@testable import SynologyAPI

final class CollectionDayPagerTests: XCTestCase {
    private func day(_ day: Int, count: Int) -> TimelineDay { TimelineDay(year: 2024, month: 1, day: day, itemCount: count) }
    func testPackedDaysAndSplitLargeDaysNormalizeIdentically() throws {
        let sections = [TimelineSection(offset: 0, limit: 30, list: [day(3, count: 10), day(2, count: 20)]),
                        TimelineSection(offset: 0, limit: 228, list: [day(1, count: 501)]),
                        TimelineSection(offset: 228, limit: 273, list: [day(1, count: 501)])]
        let catalog = try CollectionDayCatalog(sections: sections, completeness: .complete)
        let snapshot = try CollectionDayPager.snapshot(catalog: catalog)
        XCTAssertEqual(catalog.itemCount, 531)
        XCTAssertEqual(snapshot.sections.map(\.limit), [10, 20, 250, 250, 1])
        XCTAssertEqual(snapshot.sections.map(\.offset), [0, 0, 0, 250, 500])
        XCTAssertEqual(snapshot.sections.suffix(3).map { $0.list[0].itemCount }, [501, 501, 501])
    }
    func testPartialCannotPretendToBeFullAndRejectsOverlaps() throws {
        let section = TimelineSection(offset: 0, limit: 114, list: [day(1, count: 228)])
        XCTAssertNoThrow(try CollectionDayCatalog(sections: [section], completeness: .partial))
        XCTAssertThrowsError(try CollectionDayCatalog(sections: [section], completeness: .complete))
        XCTAssertThrowsError(try CollectionDayCatalog(sections: [section, section], completeness: .complete))
        XCTAssertThrowsError(try CollectionDayCatalog(sections: [section, .init(offset: 114, limit: 114, list: [day(1, count: 229)])], completeness: .complete))
    }
    func testRejectsInvalidCalendarCountsAndOverflow() throws {
        XCTAssertThrowsError(try CaptureDay(year: 2023, month: 2, day: 29))
        XCTAssertNoThrow(try CaptureDay(year: 2024, month: 2, day: 29))
        XCTAssertThrowsError(try CollectionDayCount(day: CaptureDay(year: 2024, month: 1, day: 1), count: -1))
        XCTAssertThrowsError(try CollectionDayCatalog(sections: [.init(offset: Int.max, limit: 2, list: [day(1, count: 1)])], completeness: .complete))
        XCTAssertThrowsError(try CaptureDay(time: Int64.max))
    }
    func testNewDaysNeverChangeExistingAddressesAndGrowthAddsTail() throws {
        let old = try CaptureDay(year: 2024, month: 1, day: 10)
        let counts = try [CollectionDayCount(day: old, count: 1500)]
        let before = try CollectionDayPager.snapshot(catalog: CollectionDayCatalog(days: counts, completeness: .complete))
        let after = try CollectionDayPager.snapshot(catalog: CollectionDayCatalog(days: counts + [
            CollectionDayCount(day: CaptureDay(year: 2024, month: 1, day: 20), count: 1),
            CollectionDayCount(day: CaptureDay(year: 2024, month: 1, day: 5), count: 1)
        ], completeness: .complete))
        XCTAssertEqual(Array(after.sections[1...6]), before.sections)
        let growth = try CollectionDayPager.snapshot(catalog: CollectionDayCatalog(days: [.init(day: old, count: 1501)], completeness: .complete))
        XCTAssertEqual(growth.sections.map(\.offset), [0, 250, 500, 750, 1000, 1250, 1500])
        XCTAssertEqual(try DayPageAddress(collection: .library(.personal), day: old, offset: before.sections[0].offset),
                       try DayPageAddress(collection: .library(.personal), day: old, offset: growth.sections[0].offset))
    }
    func testCaptureLocalBoundariesAndStrictDecode() throws {
        XCTAssertEqual(try CaptureDay(time: 1_704_067_199).id, "2023-12-31")
        XCTAssertEqual(try CaptureDay(time: 1_704_067_200).id, "2024-01-01")
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureDay.self, from: Data(#"{"year":2024,"month":2,"day":31}"#.utf8)))
    }
    func testExistingCaptureSectionTopologyWhenExplicitlyProvided() throws {
        guard let directory = ProcessInfo.processInfo.environment["SYNO_SECTION_FIXTURE_DIRECTORY"] else {
            throw XCTSkip("Optional offline capture section fixtures were not provided")
        }
        for (name, days, items, pages) in [("firstone.har", 2192, 58712, 2245), ("favoritesAlbum.har", 69, 344, 69)] {
            let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("syno-\(name).sections.json"))
            let sections = try JSONDecoder().decode([TimelineSection].self, from: data)
            let catalog = try CollectionDayCatalog(sections: sections, completeness: .complete)
            XCTAssertEqual(catalog.days.count, days)
            XCTAssertEqual(catalog.itemCount, items)
            XCTAssertEqual(try CollectionDayPager.snapshot(catalog: catalog).sections.count, pages)
        }
    }

}
