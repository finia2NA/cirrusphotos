import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class LibraryViewportGeometryTests: XCTestCase {
    private func section(day: Int, offset: Int = 0, limit: Int = 100, count: Int = 100) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
                        list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: count)])
    }

    private func item(_ id: Int64, width: Int = 100, height: Int = 100) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
            {"id":\(id),"time":1712102400,"type":"photo","additional":{"resolution":{"width":\(width),"height":\(height)}}}
            """.utf8))
    }

    func testLargeIndexUsesSliceGeometryAndBinaryLookup() {
        let sections = (0..<10_000).map { section(day: 3, offset: $0 * 100, count: 1_000_000) }
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: sections))
        let geometry = LibraryViewportGeometry(index: index, width: 600)
        XCTAssertEqual(geometry.slices.count, 10_000)
        XCTAssertEqual(geometry.slices.filter(\.heading).count, 1)
        XCTAssertEqual(geometry.slice(at: 0), 0)
        XCTAssertEqual(geometry.slice(at: geometry.totalHeight - 1), 9_999)
        XCTAssertLessThanOrEqual(geometry.sliceRange(y: geometry.totalHeight / 2, height: 400).count, 2)
    }

    func testSplitDayJumpAndNearestOlderDate() {
        let snapshot = TimelineSnapshot(sections: [
            section(day: 3, offset: 0, limit: 2, count: 4),
            section(day: 3, offset: 2, limit: 2, count: 4),
            section(day: 1, limit: 2, count: 2)
        ])
        let index = LibraryIndex(snapshot: snapshot)
        let geometry = LibraryViewportGeometry(index: index, width: 500)
        XCTAssertEqual(geometry.slices.map(\.heading), [true, false, true])
        XCTAssertEqual(geometry.y(forDay: "2024-04-03"), 0)
        XCTAssertEqual(geometry.y(forDay: "2024-04-01"), geometry.slices[2].y)
        XCTAssertEqual(geometry.nearestDay(to: "2024-04-02", orderedDays: index.dayIDs), "2024-04-01")
        XCTAssertEqual(geometry.nearestDay(to: "2024-03-01", orderedDays: index.dayIDs), "2024-04-01")
    }

    func testMeasuredPageCorrectsItemAnchorAndResize() throws {
        let snapshot = TimelineSnapshot(sections: [section(day: 3, limit: 6, count: 6)])
        let index = LibraryIndex(snapshot: snapshot)
        var geometry = LibraryViewportGeometry(index: index, width: 500)
        let items = try (1...6).map { try item(Int64($0), width: $0.isMultiple(of: 2) ? 200 : 100) }
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: items, verified: false)])
        let firstRow = try XCTUnwrap(geometry.rows(in: 0).first)
        let anchor = try XCTUnwrap(geometry.anchor(at: firstRow.y + 10))
        XCTAssertEqual(anchor.itemID, 1)
        let initial = try XCTUnwrap(geometry.y(for: anchor))
        XCTAssertEqual(initial, firstRow.y + 10, accuracy: 0.001)
        geometry.setWidth(300, pages: [0: LibraryPage(sectionIndex: 0, items: items, verified: true)])
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)), geometry.rows(in: 0)[0].y + 10, accuracy: 0.001)
        let replaced = try (10...15).map { try item(Int64($0)) }
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: replaced, verified: true)])
        XCTAssertNotNil(geometry.y(for: anchor)) // Falls back to the same date/slice.
    }

    func testOnlyRetainedRowsKeepItemIDs() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3), section(day: 2)]))
        var geometry = LibraryViewportGeometry(index: index, width: 500)
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: [try item(7)], verified: false)])
        XCTAssertNotNil(geometry.y(forItem: 7, offset: 0))
        geometry.reconcile(pages: [:])
        XCTAssertNil(geometry.y(forItem: 7, offset: 0))
        XCTAssertNotNil(geometry.y(forDay: "2024-04-02"))
    }

    func testItemAnchorFindsMovedSectionAfterIndexRefresh() throws {
        let old = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3), section(day: 2)]))
        var oldGeometry = LibraryViewportGeometry(index: old, width: 500)
        oldGeometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: [try item(17)], verified: true)])
        let anchor = try XCTUnwrap(oldGeometry.anchor(at: oldGeometry.rows(in: 0)[0].y + 7))
        let shifted = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3), section(day: 3), section(day: 2)]))
        var newGeometry = LibraryViewportGeometry(index: shifted, width: 500)
        newGeometry.reconcile(pages: [1: LibraryPage(sectionIndex: 1, items: [try item(17)], verified: true)])
        XCTAssertEqual(try XCTUnwrap(newGeometry.y(for: anchor)),
                       newGeometry.rows(in: 1)[0].y + newGeometry.slices[1].y + 7, accuracy: 0.001)
    }

    func testDayAnchorSurvivesMeasurementOfEarlierDayInSameSection() throws {
        let mixed = TimelineSection(offset: 0, limit: 8, list: [
            TimelineDay(year: 2024, month: 4, day: 3, itemCount: 4),
            TimelineDay(year: 2024, month: 4, day: 2, itemCount: 4)
        ])
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [mixed]))
        var geometry = LibraryViewportGeometry(index: index, width: 500)
        let target = try XCTUnwrap(geometry.y(forDay: "2024-04-02"))
        let anchor = try XCTUnwrap(geometry.anchor(at: target))
        let items = try (1...8).map { try item(Int64($0), width: 300, height: 100) }
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: items, verified: true)])
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)),
                       try XCTUnwrap(geometry.y(forDay: "2024-04-02")), accuracy: 0.001)
    }
}
