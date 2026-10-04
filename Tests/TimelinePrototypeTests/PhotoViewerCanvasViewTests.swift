import AppKit
import XCTest
@testable import TimelinePrototype

@MainActor
final class PhotoViewerCanvasViewTests: XCTestCase {
    func testViewportUsesFullDetailWidthAndReservesToolbarHeight() {
        let canvas = PhotoViewerCanvasView(frame: CGRect(x: 0, y: 0, width: 840, height: 560))
        canvas.toolbarInset = 72

        XCTAssertEqual(canvas.viewportRect(), CGRect(x: 0, y: 0, width: 840, height: 488))
    }
}
