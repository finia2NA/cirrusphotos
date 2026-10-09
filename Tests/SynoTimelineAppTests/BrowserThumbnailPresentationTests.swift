import XCTest
@testable import SynoTimelineApp

final class BrowserThumbnailPresentationTests: XCTestCase {
    @MainActor
    func testFillsFrameReflectsRestMode() {
        let presentation = BrowserThumbnailPresentation(cropsToSquare: false)
        XCTAssertFalse(presentation.cropsToSquare)
        XCTAssertFalse(presentation.fillsFrame)

        presentation.setCropsToSquare(true, animated: false)
        XCTAssertTrue(presentation.cropsToSquare)
        XCTAssertTrue(presentation.fillsFrame)
        XCTAssertFalse(presentation.isTransitioning)
    }

    @MainActor
    func testNonAnimatedApplySnapsWithoutTransition() {
        let presentation = BrowserThumbnailPresentation(cropsToSquare: false)
        presentation.setCropsToSquare(true, animated: false)
        XCTAssertTrue(presentation.cropsToSquare)
        XCTAssertFalse(presentation.isTransitioning)
        XCTAssertTrue(presentation.fillsFrame)
    }

    @MainActor
    func testRapidTogglesSettleOnLatestTarget() async {
        let presentation = BrowserThumbnailPresentation(cropsToSquare: false, transitionDuration: 0.08)
        presentation.setCropsToSquare(true, animated: true)
        presentation.setCropsToSquare(false, animated: true)
        presentation.setCropsToSquare(true, animated: true)
        XCTAssertTrue(presentation.cropsToSquare)
        XCTAssertTrue(presentation.isTransitioning)
        XCTAssertTrue(presentation.fillsFrame)

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(presentation.cropsToSquare)
        XCTAssertFalse(presentation.isTransitioning)
        XCTAssertTrue(presentation.fillsFrame)
    }
}
