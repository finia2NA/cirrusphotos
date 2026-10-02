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

    func testTargetHeightReflowsRowsAndPreservesItemAnchor() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 8, count: 8)]))
        let items = try (1...8).map { try item(Int64($0)) }
        let pages = [0: LibraryPage(sectionIndex: 0, items: items, verified: true)]
        var geometry = LibraryViewportGeometry(index: index, width: 500, targetRowHeight: 100)
        geometry.reconcile(pages: pages)
        let oldRows = geometry.rows(in: 0)
        let anchoredRow = try XCTUnwrap(oldRows.last)
        let anchor = try XCTUnwrap(geometry.anchor(at: anchoredRow.y + 11))

        XCTAssertTrue(geometry.setLayout(width: 420, targetRowHeight: 240, pages: pages))
        XCTAssertEqual(geometry.targetRowHeight, 240)
        XCTAssertNotEqual(geometry.rows(in: 0).map(\.itemIDs), oldRows.map(\.itemIDs))
        let itemID = try XCTUnwrap(anchor.itemID)
        let newRow = try XCTUnwrap(geometry.rows(in: 0).first { $0.itemIDs.contains(itemID) })
        XCTAssertEqual(try XCTUnwrap(geometry.y(for: anchor)),
                       geometry.slices[0].y + newRow.y + 11,
                       accuracy: 0.001)
    }

    func testShrinkingTargetHeightKeepsAnchorInsideItsPhotoRow() throws {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 8, count: 8)]))
        let items = try (1...8).map { try item(Int64($0)) }
        let pages = [0: LibraryPage(sectionIndex: 0, items: items, verified: true)]
        var geometry = LibraryViewportGeometry(index: index, width: 420, targetRowHeight: 300)
        geometry.reconcile(pages: pages)
        let oldRow = try XCTUnwrap(geometry.rows(in: 0).first)
        let anchor = try XCTUnwrap(geometry.anchor(at: oldRow.y + oldRow.layout.height - 5))

        XCTAssertTrue(geometry.setLayout(width: 420, targetRowHeight: 100, pages: pages))
        let itemID = try XCTUnwrap(anchor.itemID)
        let newRow = try XCTUnwrap(geometry.rows(in: 0).first { $0.itemIDs.contains(itemID) })
        let restored = try XCTUnwrap(geometry.y(for: anchor))

        XCTAssertEqual(restored, geometry.slices[0].y + newRow.y + newRow.layout.height - 1,
                       accuracy: 0.001)
        XCTAssertLessThan(restored, geometry.slices[0].y + newRow.y + newRow.layout.height)
    }

    func testTargetHeightInvalidatesUnloadedEstimates() {
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [section(day: 3, limit: 12, count: 12)]))
        var geometry = LibraryViewportGeometry(index: index, width: 500, targetRowHeight: 100)
        let compactHeight = geometry.totalHeight

        XCTAssertTrue(geometry.setLayout(width: 500, targetRowHeight: 300, pages: [:]))
        XCTAssertGreaterThan(geometry.totalHeight, compactHeight)
        XCTAssertFalse(geometry.setLayout(width: 500.2, targetRowHeight: 300.2, pages: [:]))
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

    func testSplitDayFlowsLikeUnsplitAndKeepsBoundaryCarry() throws {
        let splitSnapshot = TimelineSnapshot(sections: [
            section(day: 3, offset: 0, limit: 2, count: 4),
            section(day: 3, offset: 2, limit: 2, count: 4)
        ])
        let splitPages = [
            0: LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true),
            1: LibraryPage(sectionIndex: 1, items: [try item(3), try item(4)], verified: true)
        ]
        var split = LibraryViewportGeometry(index: LibraryIndex(snapshot: splitSnapshot), width: 500)
        split.reconcile(pages: splitPages)

        let unsplitSnapshot = TimelineSnapshot(sections: [section(day: 3, limit: 4, count: 4)])
        var unsplit = LibraryViewportGeometry(index: LibraryIndex(snapshot: unsplitSnapshot), width: 500)
        unsplit.reconcile(pages: [
            0: LibraryPage(sectionIndex: 0,
                           items: [try item(1), try item(2), try item(3), try item(4)], verified: true)
        ])

        let splitRows = split.slices.indices.flatMap { split.rows(in: $0) }
        let unsplitRows = unsplit.slices.indices.flatMap { unsplit.rows(in: $0) }
        XCTAssertEqual(splitRows.map(\.layout), unsplitRows.map(\.layout))
        XCTAssertEqual(splitRows.flatMap(\.itemIDs), [1, 2, 3, 4])
        XCTAssertEqual(splitRows.last?.layout.cells.first?.x, 0)
        XCTAssertEqual(try XCTUnwrap(splitRows.last?.layout.width), 180, accuracy: 0.001)

        // Dropping the look-behind page retains only its incomplete boundary row,
        // so the still-loaded page neither reshuffles nor duplicates its first items.
        split.reconcile(pages: [1: splitPages[1]!])
        let carriedRows = split.slices.indices.flatMap { split.rows(in: $0) }
        XCTAssertEqual(carriedRows.map(\.layout), unsplitRows.map(\.layout))
        XCTAssertEqual(carriedRows.flatMap(\.itemIDs), [1, 2, 3, 4])
        XCTAssertEqual(carriedRows.flatMap(\.items).map(\.sectionIndex), [0, 0, 1, 1])
        XCTAssertEqual(carriedRows.flatMap(\.items).map(\.pageOffset), [0, 1, 0, 1])
    }

    func testTargetHeightChangeRebuildsCrossPageCarry() throws {
        let splitSnapshot = TimelineSnapshot(sections: [
            section(day: 3, offset: 0, limit: 2, count: 4),
            section(day: 3, offset: 2, limit: 2, count: 4)
        ])
        let splitPages = [
            0: LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true),
            1: LibraryPage(sectionIndex: 1, items: [try item(3), try item(4)], verified: true)
        ]
        var split = LibraryViewportGeometry(index: LibraryIndex(snapshot: splitSnapshot),
                                            width: 500, targetRowHeight: 100)
        split.reconcile(pages: splitPages)
        XCTAssertTrue(split.setLayout(width: 500, targetRowHeight: 200, pages: splitPages))
        split.reconcile(pages: [1: splitPages[1]!])

        let unsplitSnapshot = TimelineSnapshot(sections: [section(day: 3, limit: 4, count: 4)])
        var unsplit = LibraryViewportGeometry(index: LibraryIndex(snapshot: unsplitSnapshot),
                                              width: 500, targetRowHeight: 200)
        unsplit.reconcile(pages: [
            0: LibraryPage(sectionIndex: 0,
                           items: [try item(1), try item(2), try item(3), try item(4)], verified: true)
        ])

        let splitRows = split.slices.indices.flatMap { split.rows(in: $0) }
        let unsplitRows = unsplit.slices.indices.flatMap { unsplit.rows(in: $0) }
        XCTAssertEqual(splitRows.map(\.layout), unsplitRows.map(\.layout))
        XCTAssertEqual(splitRows.flatMap(\.itemIDs), [1, 2, 3, 4])
    }

    func testThreePageFlowKeepsLoadedSuffixStableAsPrefixPagesEvict() throws {
        let snapshot = TimelineSnapshot(sections: [
            section(day: 3, offset: 0, limit: 2, count: 6),
            section(day: 3, offset: 2, limit: 2, count: 6),
            section(day: 3, offset: 4, limit: 2, count: 6)
        ])
        let pages = Dictionary(uniqueKeysWithValues: try (0..<3).map { sectionIndex in
            let firstID = Int64(sectionIndex * 2 + 1)
            return (sectionIndex, LibraryPage(sectionIndex: sectionIndex,
                items: [try item(firstID), try item(firstID + 1)], verified: true))
        })
        var geometry = LibraryViewportGeometry(index: LibraryIndex(snapshot: snapshot), width: 500)
        geometry.reconcile(pages: pages)
        let finalSliceY = geometry.slices[2].y
        XCTAssertEqual(geometry.slices.indices.flatMap { geometry.rows(in: $0) }
            .flatMap(\.itemIDs), [1, 2, 3, 4, 5, 6])

        geometry.reconcile(pages: [1: pages[1]!, 2: pages[2]!])
        XCTAssertEqual(geometry.slices[2].y, finalSliceY, accuracy: 0.001)
        XCTAssertEqual(geometry.slices.indices.flatMap { geometry.rows(in: $0) }
            .flatMap(\.itemIDs), [1, 2, 3, 4, 5, 6])

        geometry.reconcile(pages: [2: pages[2]!])
        XCTAssertEqual(geometry.slices[2].y, finalSliceY, accuracy: 0.001)
        XCTAssertEqual(geometry.rows(in: 2).flatMap(\.itemIDs), [4, 5, 6])
    }
}
