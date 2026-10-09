import Foundation
import XCTest
@testable import TimelineCore

final class FixedPhotoGridTests: XCTestCase {
    func testColumnCountClampsToSupportedRange() {
        XCTAssertEqual(FixedPhotoGrid.columns(1), 3)
        XCTAssertEqual(FixedPhotoGrid.columns(6), 6)
        XCTAssertEqual(FixedPhotoGrid.columns(12), 10)
    }

    func testRowsUseEqualSquareCellsAtThreeAndTenColumns() {
        let three = FixedPhotoGrid.row(itemCount: 3, availableWidth: 620, columns: 3)
        XCTAssertEqual(three.cells.count, 3)
        XCTAssertEqual(three.height, 201.3333333333, accuracy: 0.0001)
        XCTAssertEqual(three.width, 620, accuracy: 0.0001)
        XCTAssertTrue(three.cells.allSatisfy { abs($0.width - three.height) < 0.0001 })

        let partialTen = FixedPhotoGrid.row(itemCount: 4, availableWidth: 620, columns: 10)
        XCTAssertEqual(partialTen.cells.count, 4)
        XCTAssertEqual(partialTen.height, 54.8, accuracy: 0.0001)
        XCTAssertEqual(partialTen.width, 243.2, accuracy: 0.0001)
    }

    func testAspectFitCentersWithoutCroppingAndInvalidRatioFallsBackToSquare() {
        let slot = CGRect(x: 10, y: 20, width: 100, height: 100)
        XCTAssertEqual(FixedPhotoGrid.fittedFrame(in: slot, aspectRatio: 4),
                       CGRect(x: 10, y: 57.5, width: 100, height: 25))
        XCTAssertEqual(FixedPhotoGrid.fittedFrame(in: slot, aspectRatio: 0.25),
                       CGRect(x: 47.5, y: 20, width: 25, height: 100))
        XCTAssertEqual(FixedPhotoGrid.fittedFrame(in: slot, aspectRatio: .nan), slot)
    }

    func testEmptyAndPartialRowsNeverCreatePaddingCells() {
        XCTAssertTrue(FixedPhotoGrid.row(itemCount: 0, availableWidth: 500, columns: 6).cells.isEmpty)
        XCTAssertEqual(FixedPhotoGrid.row(itemCount: 2, availableWidth: 500, columns: 6).cells.count, 2)
        XCTAssertEqual(FixedPhotoGrid.row(itemCount: 20, availableWidth: 500, columns: 6).cells.count, 6)
    }

    func testCropPreferenceSelectsSlotOrFittedVisibleFrame() {
        let slot = CGRect(x: 10, y: 20, width: 100, height: 100)
        XCTAssertEqual(FixedPhotoGrid.visibleFrame(in: slot, aspectRatio: 4, cropsToSquare: true), slot)
        XCTAssertEqual(FixedPhotoGrid.visibleFrame(in: slot, aspectRatio: 0.25, cropsToSquare: true), slot)
        XCTAssertEqual(FixedPhotoGrid.visibleFrame(in: slot, aspectRatio: 4, cropsToSquare: false),
                       FixedPhotoGrid.fittedFrame(in: slot, aspectRatio: 4))
        XCTAssertEqual(FixedPhotoGrid.visibleFrame(in: slot, aspectRatio: .nan, cropsToSquare: false),
                       FixedPhotoGrid.fittedFrame(in: slot, aspectRatio: .nan))
    }

    func testFillDuringTransitionCoversMorphInBothDirections() {
        // Rest states use the true presentation.
        XCTAssertTrue(FixedPhotoGrid.fillsFrame(cropsToSquare: true, isTransitioning: false))
        XCTAssertFalse(FixedPhotoGrid.fillsFrame(cropsToSquare: false, isTransitioning: false))
        // Both directions fill while the inner frame morphs, so a shrinking frame never
        // flashes letterbox bars.
        XCTAssertTrue(FixedPhotoGrid.fillsFrame(cropsToSquare: true, isTransitioning: true))
        XCTAssertTrue(FixedPhotoGrid.fillsFrame(cropsToSquare: false, isTransitioning: true))
    }
}
