import XCTest
import SynologyAPI
@testable import PhotoCache

final class LibrarySelectionTests: XCTestCase {
    private func index(dayCounts: [Int]) -> LibraryIndex {
        LibraryIndex(snapshot: TimelineSnapshot(sections: dayCounts.enumerated().map { i, count in
            TimelineSection(offset: 0, limit: count,
                list: [TimelineDay(year: 2024, month: 4, day: 30 - i, itemCount: count)])
        }))
    }

    func testSuppliedDirectionalExamples() {
        let index = index(dayCounts: [36]), original = IndexSet([9, 14, 22])
        let expectations: [(LibrarySelectionDirection, Int)] = [(.up, 3), (.left, 8), (.down, 28), (.right, 23)]
        for (direction, expected) in expectations {
            var selection = LibrarySelection(); selection.bind(to: "a"); selection.replace(with: original)
            XCTAssertEqual(selection.move(direction, extending: false, in: index, columns: 6, firstVisible: nil), expected)
            XCTAssertEqual(selection.indexes, IndexSet(integer: expected))
        }
    }

    func testNoSelectionStartsAtFirstVisibleAndEdgesCollapseToBorder() {
        let index = index(dayCounts: [6])
        var selection = LibrarySelection(); selection.bind(to: "a")
        XCTAssertEqual(selection.move(.right, extending: false, in: index, columns: 6, firstVisible: 3), 3)
        selection.replace(with: IndexSet([0, 2, 5]))
        XCTAssertEqual(selection.move(.right, extending: false, in: index, columns: 6, firstVisible: nil), 5)
        XCTAssertEqual(selection.indexes, IndexSet(integer: 5))
        selection.replace(with: IndexSet([0, 2, 5]))
        XCTAssertEqual(selection.move(.left, extending: false, in: index, columns: 6, firstVisible: nil), 0)
        XCTAssertEqual(selection.indexes, IndexSet(integer: 0))
    }

    func testDayBreaksWrapHorizontallyAndClampVertically() {
        let index = index(dayCounts: [3, 6])
        XCTAssertEqual(index.destination(from: 2, direction: .right, columns: 6), 3)
        XCTAssertEqual(index.destination(from: 2, direction: .down, columns: 6), 5)
        XCTAssertEqual(index.destination(from: 3, direction: .up, columns: 6), 0)
        XCTAssertNil(index.destination(from: 0, direction: .up, columns: 6))
    }

    func testShiftExtensionTracksCurrentRangeAndReversalRemovesOnlyExtensionItems() {
        let index = index(dayCounts: [24])
        var selection = LibrarySelection(); selection.bind(to: "a")
        selection.replace(with: IndexSet([9, 14]))
        XCTAssertEqual(selection.move(.down, extending: true, in: index, columns: 6, firstVisible: nil), 20)
        XCTAssertTrue(selection.indexes.contains(integersIn: 14...20))
        XCTAssertEqual(selection.move(.up, extending: true, in: index, columns: 6, firstVisible: nil), 14)
        XCTAssertEqual(selection.indexes, IndexSet([9, 14]))
        XCTAssertEqual(selection.extensionBorder, 14)
        XCTAssertEqual(selection.extensionCursor, 14)
        XCTAssertEqual(selection.extensionBaseline, IndexSet([9, 14]))
    }

    func testShiftExtensionShrinksOneStepWithoutRemovingBaselineSelections() {
        let index = index(dayCounts: [18])
        var selection = LibrarySelection(); selection.bind(to: "a")
        selection.replace(with: IndexSet([2, 8, 10]))
        XCTAssertEqual(selection.move(.right, extending: true, in: index, columns: 6, firstVisible: nil), 11)
        XCTAssertEqual(selection.move(.right, extending: true, in: index, columns: 6, firstVisible: nil), 12)
        XCTAssertEqual(selection.indexes, IndexSet([2, 8, 10, 11, 12]))

        XCTAssertEqual(selection.move(.left, extending: true, in: index, columns: 6, firstVisible: nil), 11)
        XCTAssertEqual(selection.indexes, IndexSet([2, 8, 10, 11]))
        XCTAssertTrue(selection.indexes.contains(10))
    }

    func testDragToggleUsesGestureBaselineAndGenerationInvalidates() {
        var selection = LibrarySelection(); selection.bind(to: "a")
        let baseline = IndexSet([1, 2, 8])
        selection.replace(with: baseline)
        selection.toggle(IndexSet(integersIn: 2...4), against: baseline)
        XCTAssertEqual(selection.indexes, IndexSet([1, 3, 4, 8]))
        selection.toggle(IndexSet(integer: 2), against: baseline)
        XCTAssertEqual(selection.indexes, IndexSet([1, 8]))
        selection.bind(to: "b")
        XCTAssertTrue(selection.indexes.isEmpty)
    }
}
