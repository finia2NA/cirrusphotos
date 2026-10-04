import AppKit
import XCTest
@testable import SynoTimelineApp

@MainActor
final class PhotoViewerCanvasViewTests: XCTestCase {
    private func keyEvent(_ keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: keyCode))
    }

    func testViewportUsesFullDetailWidthAndReservesToolbarHeight() {
        let canvas = PhotoViewerCanvasView(frame: CGRect(x: 0, y: 0, width: 840, height: 560))
        canvas.toolbarInset = 72

        XCTAssertEqual(canvas.viewportRect(), CGRect(x: 0, y: 0, width: 840, height: 488))
    }

    func testSpaceAndEscapeRequestTheSameCloseAction() throws {
        let canvas = PhotoViewerCanvasView()
        var closes = 0
        canvas.onClose = { closes += 1 }

        canvas.keyDown(with: try keyEvent(49))
        canvas.keyDown(with: try keyEvent(53))

        XCTAssertEqual(closes, 2)
    }
}
