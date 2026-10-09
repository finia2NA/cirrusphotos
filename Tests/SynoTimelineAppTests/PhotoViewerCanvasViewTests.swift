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

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint,
                            in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                        timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func makeCanvas(zoom: CGFloat = 1) -> (PhotoViewerCanvasView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = PhotoViewerCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        canvas.setImage(NSImage(size: NSSize(width: 400, height: 300)),
                        selectionGeneration: 1, openingSourceRectInWindow: nil)
        if zoom != 1 { canvas.setZoom(zoom) }
        return (canvas, window)
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

    func testDownwardTwoFingerSwipeBeginsAndCommitsInteractiveDismissal() async {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -80), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        XCTAssertTrue(canvas.isInteractivelyDismissing)
        XCTAssertLessThan(canvas.backdropOpacity, 1)
        let midFrame = canvas.presentedImageFrame
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -140), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)
        XCTAssertNotEqual(canvas.presentedImageFrame, midFrame,
                          "The gesture must keep following the swipe until it ends")
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.05)
        XCTAssertTrue(canvas.isAwaitingInteractiveDismissal)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(dismisses, 1)
    }

    func testSmallDownwardSwipeReturnsWithoutDismissal() async {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -30), phase: .changed,
                                  momentumPhase: [], timestamp: 0.05)
        XCTAssertTrue(canvas.isInteractivelyDismissing)

        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.1)
        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)
        XCTAssertFalse(canvas.isInteractivelyDismissing)

        // While springing back, further samples are ignored rather than restarting dismissal.
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -400), phase: .changed,
                                  momentumPhase: [], timestamp: 0.2)
        XCTAssertFalse(canvas.isInteractivelyDismissing)
        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(dismisses, 0)
    }

    func testHorizontalAndUpwardAndSmallScrollsNeverDismiss() async {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 120, height: -10), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)
        canvas.routePreciseScroll(delta: CGSize(width: 40, height: -400), phase: .changed,
                                  momentumPhase: [], timestamp: 0.04)
        XCTAssertFalse(canvas.isInteractivelyDismissing,
                       "A gesture locked to horizontal scrolling must not become dismissal")
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.05)
        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)

        // Upward swipe in a fresh gesture.
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 1)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: 300), phase: .changed,
                                  momentumPhase: [], timestamp: 1.02)
        XCTAssertFalse(canvas.isInteractivelyDismissing)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 1.03)

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(dismisses, 0)
    }

    func testPreciseScrollPansWhenZoomedAndNeverDismisses() {
        let (canvas, window) = makeCanvas(zoom: 2)
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }
        let before = canvas.presentedImageFrame

        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -80), phase: .began,
                                  momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -80), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)

        XCTAssertEqual(canvas.currentZoom, 2)
        XCTAssertFalse(canvas.isInteractivelyDismissing)
        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)
        XCTAssertLessThan(canvas.presentedImageFrame.minY, before.minY)
        XCTAssertEqual(dismisses, 0)
    }

    func testClickDragDoesNotDismissAtFitZoom() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }
        let start = CGPoint(x: 400, y: 400)

        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: window))
        canvas.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                                 at: CGPoint(x: 400, y: 100), in: window))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp,
                                            at: CGPoint(x: 400, y: 100), in: window))

        XCTAssertFalse(canvas.isInteractivelyDismissing)
        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)
        XCTAssertEqual(dismisses, 0)
    }

    func testReduceMotionAndDisabledDisableInteractiveDismissal() async {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }

        canvas.reduceMotion = true
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -400), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.03)
        XCTAssertFalse(canvas.isInteractivelyDismissing)
        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)

        canvas.reduceMotion = false
        canvas.interactiveDismissalEnabled = false
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 1)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -400), phase: .changed,
                                  momentumPhase: [], timestamp: 1.02)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 1.03)
        XCTAssertFalse(canvas.isInteractivelyDismissing)

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(dismisses, 0)
    }

    func testMomentumAfterReleaseIsIgnored() async {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        var dismisses = 0
        canvas.onInteractiveDismiss = { dismisses += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -30), phase: .changed,
                                  momentumPhase: [], timestamp: 0.05)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.1)
        // Momentum continues downward after a spring-back decision.
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -200), phase: [],
                                  momentumPhase: .changed, timestamp: 0.12)

        XCTAssertFalse(canvas.isAwaitingInteractiveDismissal)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(dismisses, 0)
    }
}
