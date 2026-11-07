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

    func testHeaderOffsetsPhotoGeometryAndPreservesAnchor() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 3, count: 3)]))
        let page = LibraryPage(sectionIndex: 0, items: try (1...3).map { try item(Int64($0)) }, verified: true)
        var geometry = LibraryViewportGeometry(index: index, width: 600, itemsPerRow: 3, contentOrigin: 180)
        geometry.reconcile(pages: [0: page])
        XCTAssertEqual(geometry.y(forDay: "2024-04-03"), 180)
        XCTAssertNil(geometry.anchor(at: 100))
        XCTAssertNil(geometry.ordinal(at: CGPoint(x: 20, y: 100)))
        XCTAssertTrue(geometry.ordinals(intersecting: CGRect(x: 0, y: 0, width: 600, height: 180)).isEmpty)
        XCTAssertNil(geometry.firstOrdinal(inVerticalRange: 0...179))
        let frame = try XCTUnwrap(geometry.frame(forItem: 1))
        XCTAssertEqual(frame.minY, 218, accuracy: 0.001)
        XCTAssertEqual(geometry.ordinal(at: CGPoint(x: frame.midX, y: frame.midY)), 0)
        XCTAssertEqual(geometry.slotFrame(for: 0), frame)
        let anchor = try XCTUnwrap(geometry.anchor(at: frame.minY + 5))
        XCTAssertTrue(geometry.setLayout(width: 600, itemsPerRow: 3, contentOrigin: 240, pages: [0: page]))
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)), frame.minY + 65, accuracy: 0.001)
        XCTAssertEqual(geometry.y(forDay: "2024-04-03"), 240)
        XCTAssertEqual(geometry.firstOrdinal(inVerticalRange: 278...500), 0)
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

    // MARK: Continuous layout (day grouping off)

    /// Days of 2, 2 and 5 items in three sections, newest first: ordinals 0–1, 2–3, 4–8.
    private func threeDayIndex() -> LibraryIndex {
        LibraryIndex(snapshot: TimelineSnapshot(sections: [
            section(day: 3, limit: 2, count: 2), section(day: 2, limit: 2, count: 2), section(day: 1, limit: 5, count: 5)
        ]))
    }
    private func threeDayPages() throws -> [Int: LibraryPage] {
        [0: LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true),
         1: LibraryPage(sectionIndex: 1, items: [try item(3), try item(4)], verified: true),
         2: LibraryPage(sectionIndex: 2, items: try (5...9).map { try item(Int64($0)) }, verified: true)]
    }

    func testContinuousLayoutPacksDaysWithoutHeadings() throws {
        let geometry = LibraryViewportGeometry(index: threeDayIndex(), width: 600, itemsPerRow: 3, groupsByDay: false)
        let stride = geometry.slotSide + 8
        XCTAssertEqual(geometry.headingHeight, 0)
        XCTAssertEqual(geometry.totalHeight, 3 * stride, accuracy: 0.001)
        XCTAssertFalse(geometry.slices.contains(where: \.heading))
        let second = try XCTUnwrap(geometry.slotFrame(for: 2)), third = try XCTUnwrap(geometry.slotFrame(for: 3))
        XCTAssertEqual(second.minY, 0, accuracy: 0.001)
        XCTAssertEqual(second.minX, 2 * stride, accuracy: 0.001)
        XCTAssertEqual(third.minX, 0, accuracy: 0.001)
        XCTAssertEqual(third.minY, stride, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(geometry.y(forDay: "2024-04-02")), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(geometry.y(forDay: "2024-04-01")), stride, accuracy: 0.001)
        for i in 1..<geometry.slices.count {
            XCTAssertEqual(geometry.slices[i - 1].y + geometry.slices[i - 1].height, geometry.slices[i].y, accuracy: 0.001)
        }
    }

    func testContinuousRowsSpanDaysAndHitTest() throws {
        var geometry = LibraryViewportGeometry(index: threeDayIndex(), width: 600, itemsPerRow: 3, groupsByDay: false)
        let stride = geometry.slotSide + 8
        XCTAssertEqual(geometry.sectionIndices(y: 0, height: geometry.slotSide), [0, 1])
        XCTAssertEqual(geometry.sectionIndices(y: stride, height: geometry.slotSide), [1, 2])
        XCTAssertEqual(geometry.firstOrdinal(inVerticalRange: stride...(stride + 10)), 3)
        geometry.reconcile(pages: try threeDayPages())
        let rows = geometry.slices.indices.flatMap { geometry.rows(in: $0) }
        XCTAssertEqual(rows.map(\.firstOrdinal), [0, 3, 6])
        XCTAssertEqual(rows[0].itemIDs, [1, 2, 3])
        XCTAssertEqual(rows[1].itemIDs, [4, 5, 6])
        for ordinal in 0..<9 {
            let frame = try XCTUnwrap(geometry.slotFrame(for: ordinal))
            let fitted = try XCTUnwrap(geometry.frame(forItem: Int64(ordinal + 1)))
            XCTAssertEqual(fitted.minX, frame.minX, accuracy: 0.001)
            XCTAssertEqual(fitted.minY, frame.minY, accuracy: 0.001)
            XCTAssertEqual(geometry.ordinal(at: CGPoint(x: frame.midX, y: frame.midY)), ordinal)
        }
    }

    func testSwitchingGroupingPreservesAnchor() throws {
        let pages = try threeDayPages()
        var geometry = LibraryViewportGeometry(index: threeDayIndex(), width: 600, itemsPerRow: 3)
        geometry.reconcile(pages: pages)
        XCTAssertEqual(geometry.headingHeight, 38)
        let anchor = try XCTUnwrap(geometry.anchor(at: try XCTUnwrap(geometry.frame(forItem: 8)).minY + 5))
        XCTAssertTrue(geometry.setLayout(width: 600, itemsPerRow: 3, groupsByDay: false, pages: pages))
        XCTAssertFalse(geometry.setLayout(width: 600, itemsPerRow: 3, groupsByDay: false, pages: pages))
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)), try XCTUnwrap(geometry.slotFrame(for: 7)).minY + 5,
                       accuracy: 0.001)
        XCTAssertTrue(geometry.setLayout(width: 600, itemsPerRow: 3, groupsByDay: true, pages: pages))
        XCTAssertTrue(geometry.slices[0].heading)
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)), try XCTUnwrap(geometry.slotFrame(for: 7)).minY + 5,
                       accuracy: 0.001)
    }

    func testContinuousLayoutHonorsContentOrigin() throws {
        var geometry = LibraryViewportGeometry(index: threeDayIndex(), width: 600, itemsPerRow: 3,
                                               groupsByDay: false, contentOrigin: 180)
        geometry.reconcile(pages: try threeDayPages())
        XCTAssertEqual(try XCTUnwrap(geometry.frame(forItem: 1)).minY, 180, accuracy: 0.001)
        XCTAssertNil(geometry.anchor(at: 100))
        XCTAssertNil(geometry.firstOrdinal(inVerticalRange: 0...179))
        XCTAssertEqual(geometry.firstOrdinal(inVerticalRange: 180...200), 0)
    }

    func testStatusFrameStartsAtSliceFirstSlot() throws {
        let continuous = LibraryViewportGeometry(index: threeDayIndex(), width: 600, itemsPerRow: 3, groupsByDay: false)
        let status = continuous.statusFrame(forSlice: 1)
        let slot = try XCTUnwrap(continuous.slotFrame(for: 2))
        XCTAssertEqual(status.minX, slot.minX, accuracy: 0.001)
        XCTAssertEqual(status.minY, slot.minY, accuracy: 0.001)
        XCTAssertEqual(status.maxX, 600, accuracy: 0.001)
        let grouped = LibraryViewportGeometry(index: threeDayIndex(), width: 600, itemsPerRow: 3)
        XCTAssertEqual(grouped.statusFrame(forSlice: 1).minY, grouped.slices[1].y + 38, accuracy: 0.001)
        XCTAssertEqual(grouped.statusFrame(forSlice: 1).minX, 0)
    }
}
