import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class LibraryViewportGeometryTests: XCTestCase {
    private func section(day: Int, offset: Int = 0, limit: Int, count: Int) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
            list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: count)])
    }
    private func item(_ id: Int64, width: Int = 100, height: Int = 100) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
            {"id":\(id),"time":1712102400,"type":"photo","additional":{"resolution":{"width":\(width),"height":\(height)}}}
            """.utf8))
    }

    func testFixedColumnsAndUnloadedHeightAreExact() {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 21, count: 21)]))
        let three = LibraryViewportGeometry(index: index, width: 620, itemsPerRow: 3)
        let ten = LibraryViewportGeometry(index: index, width: 620, itemsPerRow: 10)
        XCTAssertEqual(three.itemsPerRow, 3)
        XCTAssertEqual(ten.itemsPerRow, 10)
        XCTAssertEqual(three.totalHeight, 38 + 7 * (three.slotSide + 8), accuracy: 0.001)
        XCTAssertEqual(ten.totalHeight, 38 + 3 * (ten.slotSide + 8), accuracy: 0.001)
    }

    func testAspectFitLeavesLetterboxSpaceAndHitTestingUsesImageRect() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 2, count: 2)]))
        var geometry = LibraryViewportGeometry(index: index, width: 608, itemsPerRow: 3)
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: [
            try item(1, width: 400, height: 100), try item(2, width: 100, height: 400)
        ], verified: true)])
        let wide = try XCTUnwrap(geometry.frame(forItem: 1))
        let tall = try XCTUnwrap(geometry.frame(forItem: 2))
        let wideSlot = try XCTUnwrap(geometry.slotFrame(for: 0))
        let tallSlot = try XCTUnwrap(geometry.slotFrame(for: 1))
        XCTAssertEqual(wide.width, wideSlot.width, accuracy: 0.001)
        XCTAssertLessThan(wide.height, wideSlot.height)
        XCTAssertEqual(tall.height, tallSlot.height, accuracy: 0.001)
        XCTAssertLessThan(tall.width, tallSlot.width)
        XCTAssertNil(geometry.ordinal(at: CGPoint(x: wideSlot.midX, y: wideSlot.minY + 2)))
        XCTAssertEqual(geometry.ordinal(at: CGPoint(x: wide.midX, y: wide.midY)), 0)
    }

    func testSplitPageRowDemandsBothSectionsAndKeepsStableSlots() throws {
        let snapshot = TimelineSnapshot(sections: [
            section(day: 3, offset: 0, limit: 2, count: 4),
            section(day: 3, offset: 2, limit: 2, count: 4)
        ])
        let index = LibraryIndex(snapshot: snapshot)
        var geometry = LibraryViewportGeometry(index: index, width: 600, itemsPerRow: 3)
        XCTAssertEqual(geometry.sectionIndices(y: 38, height: geometry.slotSide), [0, 1])
        geometry.reconcile(pages: [
            0: LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true),
            1: LibraryPage(sectionIndex: 1, items: [try item(3), try item(4)], verified: true)
        ])
        let rows = geometry.slices.indices.flatMap { geometry.rows(in: $0) }
        XCTAssertEqual(rows.map(\.firstOrdinal), [0, 3])
        XCTAssertEqual(rows[0].itemIDs, [1, 2, 3])
        XCTAssertEqual(rows[1].itemIDs, [4])
        let oldHeight = geometry.totalHeight
        geometry.reconcile(pages: [1: LibraryPage(sectionIndex: 1, items: [try item(3), try item(4)], verified: true)])
        XCTAssertEqual(geometry.totalHeight, oldHeight)
        XCTAssertEqual(geometry.slices.indices.flatMap { geometry.rows(in: $0) }.flatMap(\.itemIDs), [3, 4])
        XCTAssertNotNil(geometry.slotFrame(for: 0))
    }

    func testColumnChangePreservesItemAnchorAndDayBoundaries() throws {
        let sections = [section(day: 3, limit: 8, count: 8), section(day: 2, limit: 3, count: 3)]
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: sections))
        let page = LibraryPage(sectionIndex: 0, items: try (1...8).map { try item(Int64($0)) }, verified: true)
        var geometry = LibraryViewportGeometry(index: index, width: 600, itemsPerRow: 6)
        geometry.reconcile(pages: [0: page])
        let anchor = try XCTUnwrap(geometry.anchor(at: try XCTUnwrap(geometry.frame(forItem: 7)).minY + 5))
        XCTAssertTrue(geometry.setLayout(width: 600, itemsPerRow: 3, pages: [0: page]))
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)), try XCTUnwrap(geometry.frame(forItem: 7)).minY + 5,
                       accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(geometry.y(forDay: "2024-04-02")),
                             try XCTUnwrap(geometry.y(forDay: "2024-04-03")))
    }

    func testSquareCropFillsSlotsAndHitTestingUsesSquareFrame() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 2, count: 2)]))
        var geometry = LibraryViewportGeometry(index: index, width: 608, itemsPerRow: 3,
                                               cropsThumbnailsToSquare: true)
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0, items: [
            try item(1, width: 400, height: 100), try item(2, width: 100, height: 400)
        ], verified: true)])
        let wide = try XCTUnwrap(geometry.frame(forItem: 1))
        let tall = try XCTUnwrap(geometry.frame(forItem: 2))
        let wideSlot = try XCTUnwrap(geometry.slotFrame(for: 0))
        let tallSlot = try XCTUnwrap(geometry.slotFrame(for: 1))
        XCTAssertEqual(wide, wideSlot)
        XCTAssertEqual(tall, tallSlot)
        XCTAssertEqual(wide.width, wideSlot.width, accuracy: 0.001)
        XCTAssertEqual(wide.height, wideSlot.height, accuracy: 0.001)
        // Corners letterboxed in fit mode resolve to the square's ordinal in crop mode.
        XCTAssertEqual(geometry.ordinal(at: CGPoint(x: wideSlot.midX, y: wideSlot.minY + 2)), 0)
        XCTAssertEqual(geometry.ordinal(at: CGPoint(x: tallSlot.minX + 2, y: tallSlot.midY)), 1)
        XCTAssertEqual(geometry.ordinals(intersecting: CGRect(x: tallSlot.minX + 1,
            y: tallSlot.minY + 1, width: 4, height: 4)), IndexSet(integer: 1))
    }

    func testSquareModeRelayoutReturnsTrueAndKeepsDocumentGeometry() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 2, count: 2)]))
        let page = LibraryPage(sectionIndex: 0, items: [
            try item(1, width: 400, height: 100), try item(2, width: 100, height: 400)
        ], verified: true)
        var geometry = LibraryViewportGeometry(index: index, width: 608, itemsPerRow: 3)
        geometry.reconcile(pages: [0: page])
        let height = geometry.totalHeight
        let side = geometry.slotSide
        let dayOrigin = try XCTUnwrap(geometry.y(forDay: "2024-04-03"))
        let fitFrame = try XCTUnwrap(geometry.frame(forItem: 1))
        XCTAssertFalse(geometry.cropsThumbnailsToSquare)
        XCTAssertTrue(geometry.setLayout(width: 608, itemsPerRow: 3,
                                         cropsThumbnailsToSquare: true, pages: [0: page]))
        XCTAssertTrue(geometry.cropsThumbnailsToSquare)
        XCTAssertEqual(geometry.frame(forItem: 1), geometry.slotFrame(for: 0))
        XCTAssertNotEqual(geometry.frame(forItem: 1), fitFrame)
        XCTAssertEqual(geometry.totalHeight, height, accuracy: 0.001)
        XCTAssertEqual(geometry.slotSide, side, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(geometry.y(forDay: "2024-04-03")), dayOrigin, accuracy: 0.001)
        // Re-applying the same presentation is a no-op, not a relayout.
        XCTAssertFalse(geometry.setLayout(width: 608, itemsPerRow: 3,
                                          cropsThumbnailsToSquare: true, pages: [0: page]))
    }

    func testSquareModeRelayoutPreservesItemAnchor() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 8, count: 8)]))
        let page = LibraryPage(sectionIndex: 0, items: try (1...8).map { try item(Int64($0)) }, verified: true)
        var geometry = LibraryViewportGeometry(index: index, width: 600, itemsPerRow: 6)
        geometry.reconcile(pages: [0: page])
        let anchor = try XCTUnwrap(geometry.anchor(at: try XCTUnwrap(geometry.frame(forItem: 7)).minY + 5))
        XCTAssertTrue(geometry.setLayout(width: 600, itemsPerRow: 6,
                                         cropsThumbnailsToSquare: true, pages: [0: page]))
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)),
                       try XCTUnwrap(geometry.frame(forItem: 7)).minY + 5, accuracy: 0.001)
    }

    func testRectangleHitsOnlyLoadedFittedImages() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 4, count: 4)]))
        var geometry = LibraryViewportGeometry(index: index, width: 600, itemsPerRow: 3)
        geometry.reconcile(pages: [0: LibraryPage(sectionIndex: 0,
            items: try (1...4).map { try item(Int64($0)) }, verified: true)])
        let first = try XCTUnwrap(geometry.frame(forItem: 1))
        let second = try XCTUnwrap(geometry.frame(forItem: 2))
        let rect = first.union(second).insetBy(dx: 1, dy: 1)
        XCTAssertEqual(geometry.ordinals(intersecting: rect), IndexSet(integersIn: 0...1))
        geometry.reconcile(pages: [:])
        XCTAssertTrue(geometry.ordinals(intersecting: rect).isEmpty)
    }

    func testMillionItemDayQueriesOnlyVisibleRowsAndBinarySplitSlices() {
        let count = 1_000_000
        let pageSize = 100
        let sections = stride(from: 0, to: count, by: pageSize).map {
            section(day: 3, offset: $0, limit: pageSize, count: count)
        }
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: sections))
        let geometry = LibraryViewportGeometry(index: index, width: 600, itemsPerRow: 10)
        let ordinal = 876_543
        let slot = try! XCTUnwrap(geometry.slotFrame(for: ordinal))
        XCTAssertEqual(geometry.firstOrdinal(inVerticalRange: slot.minY...slot.maxY), 876_540)
        XCTAssertEqual(geometry.sectionIndices(y: slot.minY, height: slot.height), [8_765])
        XCTAssertEqual(index.location(forOrdinal: ordinal)?.sectionIndex, 8_765)
        XCTAssertEqual(index.ordinal(sectionIndex: 8_765, pageOffset: 43), ordinal)
    }
}
