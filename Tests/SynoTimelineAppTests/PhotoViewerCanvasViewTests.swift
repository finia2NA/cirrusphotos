import AppKit
import XCTest
import PhotoCache
import SynologyAPI
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

    private func bitmapImage(width: Int, height: Int) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    func testFilmstripDividerTracksDragAndClampsHeight() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let divider = FilmstripDivider.DividerView(frame: CGRect(x: 0, y: 0, width: 800, height: 10))
        window.contentView = divider
        divider.height = 100
        var updated: CGFloat = 0
        divider.onChange = { updated = $0 }
        divider.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 100), in: window))
        divider.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 20, y: 150), in: window))
        XCTAssertEqual(updated, 150)
        divider.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 20, y: 500), in: window))
        XCTAssertEqual(updated, 220)
    }

    func testViewportUsesFullDetailWidthAndReservesToolbarHeight() {
        let canvas = PhotoViewerCanvasView(frame: CGRect(x: 0, y: 0, width: 840, height: 560))
        canvas.toolbarInset = 72

        XCTAssertEqual(canvas.viewportRect(), CGRect(x: 0, y: 0, width: 840, height: 488))
    }

    func testSelectionResetInstallsProvidedImageWithoutClearing() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let next = NSImage(size: NSSize(width: 20, height: 10))
        next.addRepresentation(bitmap)

        canvas.resetForSelection(2, image: next, itemID: nil)

        XCTAssertTrue(canvas.hasImageContents)
        XCTAssertTrue(canvas.presentedImage === next)
        XCTAssertEqual(canvas.currentZoom, 1)
    }

    func testReattachedCanvasInstallsLastPresentedImage() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let controller = PhotoViewerCanvasController()
        let first = PhotoViewerCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = first
        first.layoutSubtreeIfNeeded()
        first.setImage(try bitmapImage(width: 400, height: 300),
                       selectionGeneration: 1, openingSourceRectInWindow: nil)
        controller.attach(first)
        let presented = try bitmapImage(width: 600, height: 400)
        controller.resetForSelection(2, image: presented, itemID: 3)
        XCTAssertTrue(first.presentedImage === presented)

        let second = PhotoViewerCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = second
        second.layoutSubtreeIfNeeded()
        controller.attach(second)

        XCTAssertTrue(second.presentedImage === presented)
        XCTAssertTrue(second.hasImageContents)
        XCTAssertEqual(second.currentZoom, 1)
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

    func testImageOverlayFollowsDismissalAndReportsBackdropFade() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let image = try bitmapImage(width: 20, height: 10)
        canvas.setInspectionOverlay(try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let container = try XCTUnwrap(canvas.currentImageLayer.sublayers?.first)
        XCTAssertEqual(container.frame, canvas.currentImageLayer.bounds)
        var opacity: CGFloat = 1
        canvas.onBackdropOpacityChanged = { value, _ in opacity = value }
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 0, height: -80), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        XCTAssertEqual(container.frame, canvas.currentImageLayer.bounds)
        XCTAssertEqual(opacity, canvas.backdropOpacity, accuracy: 0.001)
        canvas.collapse(to: CGRect(x: 40, y: 40, width: 100, height: 75), reduceMotion: false) {}
        XCTAssertNotNil(canvas.currentImageLayer.animation(forKey: "transition.transform"))
        XCTAssertEqual(container.frame, canvas.currentImageLayer.bounds)
    }

    func testLiveIndicatorTracksDismissalWithoutImplicitLayerAnimations() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.setLivePhoto(nil, visible: true)
        let container = try XCTUnwrap(canvas.currentImageLayer.sublayers?.first)
        let indicator = try XCTUnwrap(container.sublayers?.first { $0.name == "livePhotoIndicator" })
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        for (index, distance) in [40.0, 80.0, 120.0].enumerated() {
            canvas.routePreciseScroll(delta: CGSize(width: 0, height: -distance), phase: .changed,
                                      momentumPhase: [], timestamp: Double(index + 1) * 0.01)
            XCTAssertEqual(container.frame, canvas.currentImageLayer.bounds)
            XCTAssertEqual(indicator.frame.maxY, max(32, container.bounds.height - 12), accuracy: 0.01)
            XCTAssertNil(container.animation(forKey: "position"))
            XCTAssertNil(container.animation(forKey: "bounds"))
            XCTAssertNil(indicator.animation(forKey: "position"))
            XCTAssertNil(indicator.animation(forKey: "bounds"))
        }
    }

    func testLiveIndicatorsFollowBothPagingNeighborsAndPromotedLayer() throws {
        for next in [false, true] {
            let (canvas, window) = makeCanvas()
            defer { window.orderOut(nil) }
            canvas.setLivePhoto(nil, visible: false, generation: 1)
            canvas.previousImage = try bitmapImage(width: 200, height: 300)
            canvas.nextImage = try bitmapImage(width: 300, height: 200)
            canvas.previousItemID = 2
            canvas.nextItemID = 3
            canvas.previousIsLivePhoto = true
            canvas.nextIsLivePhoto = true
            canvas.syncNeighbors(generation: 1)
            let incoming = next ? canvas.nextImageLayer : canvas.previousImageLayer
            XCTAssertNotNil(incoming.sublayers?.flatMap { $0.sublayers ?? [] }.first { $0.name == "neighborLiveIndicator" })
            canvas.pagingAnimationDuration = 0
            canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
            canvas.routePreciseScroll(delta: CGSize(width: next ? -350 : 350, height: 0), phase: .changed,
                                      momentumPhase: [], timestamp: 0.01)
            // An update for the outgoing selection must not relabel the incoming photo.
            canvas.setLivePhoto(nil, visible: false, generation: 1)
            XCTAssertNotNil(incoming.sublayers?.flatMap { $0.sublayers ?? [] }.first { $0.name == "neighborLiveIndicator" })
            canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
            canvas.resetForSelection(2, image: next ? canvas.nextImage : canvas.previousImage, itemID: next ? 3 : 2)
            let indicator = canvas.currentImageLayer.sublayers?.flatMap { $0.sublayers ?? [] }
                .first { $0.name == "livePhotoIndicator" }
            XCTAssertNotNil(indicator)
            XCTAssertEqual(indicator?.isHidden, false)
            XCTAssertNil(canvas.currentImageLayer.sublayers?.first { $0.name == "neighborImageOverlay" })
        }
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

    func testFileDragStartsAtFitZoomAndZoomedDragStillPans() throws {
        let (fit, fitWindow) = makeCanvas()
        defer { fitWindow.orderOut(nil) }
        var starts = 0
        fit.startFileDrag = { _, _ in starts += 1; return true }
        let point = CGPoint(x: 400, y: 300)
        fit.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: fitWindow))
        fit.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 403, y: 300), in: fitWindow))
        XCTAssertEqual(starts, 0)
        fit.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 420, y: 300), in: fitWindow))
        XCTAssertEqual(starts, 1)

        let (zoomed, zoomWindow) = makeCanvas(zoom: 2)
        defer { zoomWindow.orderOut(nil) }
        zoomed.startFileDrag = { _, _ in starts += 1; return true }
        let before = zoomed.presentedImageFrame
        zoomed.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: zoomWindow))
        zoomed.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 450, y: 300), in: zoomWindow))
        XCTAssertEqual(starts, 1)
        XCTAssertNotEqual(zoomed.presentedImageFrame, before)
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

    func testHorizontalTwoFingerSwipeFollowsFingersAndCommitsToNext() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let restFrame = canvas.presentedImageFrame
        let neighbor = try bitmapImage(width: 200, height: 100)
        canvas.nextImage = neighbor
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0
        var nextCalls = 0
        canvas.onNext = { nextCalls += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -50, height: -4), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)

        XCTAssertTrue(canvas.isInteractivelyPaging)
        XCTAssertTrue(canvas.hasPagingContents)
        let distance = canvas.presentedPagingFrame.midX - canvas.presentedImageFrame.midX
        XCTAssertEqual(distance, 824, accuracy: 0.5)
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX - 67.5, accuracy: 0.5)
        XCTAssertEqual(canvas.presentedPagingFrame.midX, restFrame.midX + distance - 67.5,
                       accuracy: 0.5)

        canvas.routePreciseScroll(delta: CGSize(width: -300, height: -4), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.3)

        XCTAssertTrue(canvas.isAwaitingPage)
        XCTAssertEqual(canvas.presentedPagingFrame.midX, restFrame.midX, accuracy: 0.5)
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX - distance, accuracy: 0.5)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(nextCalls, 1)

        let confirmed = try bitmapImage(width: 400, height: 300)
        let incomingLayer = canvas.nextImageLayer
        canvas.resetForSelection(2, image: confirmed, itemID: 3)

        XCTAssertTrue(canvas.presentedImage === confirmed)
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer,
                      "The visible neighbor layer becomes the current layer")
        XCTAssertFalse(canvas.isAwaitingPage)
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX, accuracy: 0.5)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(canvas.hasPagingContents)
    }

    func testLivePhotoForcePressAndIndicatorClick() async throws {
        let root = temporaryTestRoot("LivePhotoHold")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "test", otpSecret: ""),
            budget: 100_000_000, cacheRoot: root, transport: LivePhotoCanvasTransport())
        let (canvas, window) = makeCanvas()
        defer { window.contentView = nil; window.orderOut(nil) }
        canvas.setLivePhoto(LivePhotoConfiguration(repository: repository, itemID: 12,
                                                   generation: 1, isMuted: true))
        let point = CGPoint(x: 400, y: 300)
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: window))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(canvas.livePhotoLoading, "Ordinary hold is reserved for other interactions")
        canvas.handlePressure(stage: 2, at: point)
        XCTAssertTrue(canvas.livePhotoLoading)
        canvas.handlePressure(stage: 1, at: point)
        XCTAssertFalse(canvas.livePhotoLoading)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(canvas.subviews.contains { $0 is VideoPlayerContainerView })
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: window))

        let frame = canvas.presentedImageFrame
        let icon = CGPoint(x: frame.minX + 28, y: frame.maxY - 28)
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: icon, in: window))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: icon, in: window))
        XCTAssertTrue(canvas.livePhotoLoading, "Click playback persists after mouse release")
        let started = await waitUntil { canvas.subviews.contains { $0 is VideoPlayerContainerView } }
        XCTAssertTrue(started)
        let video = try XCTUnwrap(canvas.subviews.first as? VideoPlayerContainerView)
        XCTAssertTrue(video.isMotionPlayback)
        XCTAssertNil(video.hitTest(.zero))
        video.onFirstFrame?()
        XCTAssertFalse(canvas.livePhotoLoading)
        video.onPlaybackFinished?()
        XCTAssertNil(video.superview)
        XCTAssertNil(video.player)

        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: icon, in: window))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: icon, in: window))
        XCTAssertTrue(canvas.livePhotoLoading)
        canvas.resetForSelection(2, image: canvas.presentedImage, itemID: 13)
        XCTAssertFalse(canvas.livePhotoLoading)
    }

    func testVideoMuteChangesFollowPlayerAndCarryToNextVideo() async throws {
        let root = temporaryTestRoot("VideoMute")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "test", otpSecret: ""),
            budget: 100_000_000, cacheRoot: root, transport: AppMockTransport())
        let view = VideoPlayerContainerView()
        var muted = false
        let first = VideoPlaybackResource(unitID: 1, cacheKey: "key", filename: "one.mp4", variant: .original)
        view.configure(repository: repository, resource: first, generation: 1, allowNetwork: false,
                       poster: nil, isMuted: muted, onMuteChanged: { muted = $0 })
        let player = try XCTUnwrap(view.player)
        XCTAssertFalse(player.isMuted)
        player.isMuted = true
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(muted)
        let second = VideoPlaybackResource(unitID: 2, cacheKey: "key2", filename: "two.mp4", variant: .original)
        view.configure(repository: repository, resource: second, generation: 2, allowNetwork: false,
                       poster: nil, isMuted: muted, onMuteChanged: { muted = $0 })
        XCTAssertTrue(try XCTUnwrap(view.player).isMuted)
        view.configure(repository: repository, resource: second, generation: 2, allowNetwork: false,
                       poster: nil, isMuted: false, onMuteChanged: { muted = $0 })
        XCTAssertFalse(try XCTUnwrap(view.player).isMuted)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(muted)
        view.stop()
    }

    func testVideoFollowsPagingAndRemainsUntilCommitCompletes() async throws {
        let root = temporaryTestRoot("VideoCanvasPaging")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "test", otpSecret: ""),
            budget: 100_000_000, cacheRoot: root, transport: AppMockTransport())
        let (canvas, window) = makeCanvas()
        defer { window.contentView = nil; window.orderOut(nil) }
        let poster = try bitmapImage(width: 400, height: 300)
        canvas.setVideo(VideoConfiguration(repository: repository,
            resource: VideoPlaybackResource(unitID: 1, cacheKey: "key", filename: "video.mp4", variant: .original),
            generation: 1, allowNetwork: false, poster: poster))
        let video = try XCTUnwrap(canvas.subviews.first as? VideoPlayerContainerView)
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -350, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        XCTAssertEqual(video.frame, canvas.presentedImageFrame)
        canvas.setVideo(nil)
        XCTAssertTrue(video.superview === canvas)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        XCTAssertTrue(video.superview === canvas)
        canvas.resetForSelection(2, image: canvas.nextImage, itemID: 3)
        XCTAssertNil(video.superview)
    }

    func testVideoAnimationGeometryMatchesPhotoWithDifferentAnchors() async throws {
        let root = temporaryTestRoot("VideoAnimationAnchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "test", otpSecret: ""),
            budget: 100_000_000, cacheRoot: root, transport: AppMockTransport())
        let (canvas, window) = makeCanvas()
        defer { window.contentView = nil; window.orderOut(nil) }
        canvas.setVideo(VideoConfiguration(repository: repository,
            resource: VideoPlaybackResource(unitID: 1, cacheKey: "key", filename: "video.mp4", variant: .original),
            generation: 1, allowNetwork: false, poster: canvas.presentedImage))
        let video = try XCTUnwrap(canvas.subviews.first as? VideoPlayerContainerView)
        let videoLayer = try XCTUnwrap(video.layer)
        XCTAssertNotEqual(videoLayer.anchorPoint, canvas.currentImageLayer.anchorPoint)
        func assertMatchingFrames(file: StaticString = #filePath, line: UInt = #line) throws {
            let photoPosition = try XCTUnwrap(canvas.currentImageLayer.animation(forKey: "transition.position") as? CABasicAnimation)
            let photoTransform = canvas.currentImageLayer.animation(forKey: "transition.transform") as? CABasicAnimation
            let videoPosition = try XCTUnwrap(videoLayer.animation(forKey: "transition.position") as? CABasicAnimation)
            let videoBounds = try XCTUnwrap(videoLayer.animation(forKey: "transition.bounds") as? CABasicAnimation)
            for start in [true, false] {
                let photoPoint = try XCTUnwrap((start ? photoPosition.fromValue : photoPosition.toValue) as? NSValue).pointValue
                let scale = ((start ? photoTransform?.fromValue : photoTransform?.toValue) as? NSValue)?.caTransform3DValue ?? CATransform3DIdentity
                let photoSize = CGSize(width: canvas.currentImageLayer.bounds.width * scale.m11,
                                       height: canvas.currentImageLayer.bounds.height * scale.m22)
                let videoPoint = try XCTUnwrap((start ? videoPosition.fromValue : videoPosition.toValue) as? NSValue).pointValue
                let videoSize = try XCTUnwrap((start ? videoBounds.fromValue : videoBounds.toValue) as? NSValue).rectValue.size
                let photoOrigin = CGPoint(x: photoPoint.x - photoSize.width * 0.5, y: photoPoint.y - photoSize.height * 0.5)
                let videoOrigin = CGPoint(x: videoPoint.x - videoSize.width * videoLayer.anchorPoint.x,
                                          y: videoPoint.y - videoSize.height * videoLayer.anchorPoint.y)
                XCTAssertEqual(videoOrigin.x, photoOrigin.x, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(videoOrigin.y, photoOrigin.y, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(videoSize, photoSize, file: file, line: line)
            }
        }
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0.5
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        try assertMatchingFrames()
        canvas.collapse(to: CGRect(x: 40, y: 40, width: 100, height: 75), reduceMotion: false) {}
        try assertMatchingFrames()
    }

    func testSmallHorizontalSwipeReturnsWithoutPaging() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let restFrame = canvas.presentedImageFrame
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0
        var nextCalls = 0
        canvas.onNext = { nextCalls += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -40, height: -2), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: CGSize(width: -40, height: -2), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)
        XCTAssertTrue(canvas.isInteractivelyPaging)

        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.3)

        XCTAssertFalse(canvas.isInteractivelyPaging)
        XCTAssertFalse(canvas.isAwaitingPage)
        XCTAssertTrue(canvas.hasPagingContents, "The neighbor remains prepared offscreen")
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX, accuracy: 0.5)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(nextCalls, 0)
    }

    func testHorizontalSwipeRightUsesPreviousNeighbor() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.previousImage = try bitmapImage(width: 200, height: 100)
        canvas.previousItemID = 1
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0
        var previousCalls = 0
        canvas.onPrevious = { previousCalls += 1 }

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: 300, height: 4), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)

        XCTAssertTrue(canvas.isAwaitingPage)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(previousCalls, 1)

        let confirmed = try bitmapImage(width: 400, height: 300)
        let incomingLayer = canvas.previousImageLayer
        canvas.resetForSelection(2, image: confirmed, itemID: 1)
        XCTAssertTrue(canvas.presentedImage === confirmed)
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(canvas.hasPagingContents)
    }

    func testHorizontalSwipeWithoutNeighborImageDoesNotPage() {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let restFrame = canvas.presentedImageFrame
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 2), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)

        XCTAssertFalse(canvas.isInteractivelyPaging)
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX, accuracy: 0.5)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.02)
    }

    func testPagingConfirmationKeepsPredecodedImageWhenSelectionImageIsUnavailable() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let restFrame = canvas.presentedImageFrame
        let neighbor = try bitmapImage(width: 200, height: 100)
        canvas.nextImage = neighbor
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 2), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        XCTAssertTrue(canvas.isAwaitingPage)
        let pending = try XCTUnwrap(canvas.presentedPagingImage)

        canvas.resetForSelection(2, image: nil, itemID: 3)

        XCTAssertTrue(canvas.presentedImage === pending)
        XCTAssertTrue(canvas.hasImageContents)
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX, accuracy: 0.5)

        canvas.setImage(nil, selectionGeneration: 2, openingSourceRectInWindow: nil)
        XCTAssertTrue(canvas.presentedImage === pending,
                      "A late nil selection image must not clear a committed page")

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(canvas.hasImageContents,
                      "The promoted neighbor remains visible")
        XCTAssertTrue(canvas.presentedImage === pending)
        XCTAssertTrue(canvas.hasImageContents)

        let upgraded = try bitmapImage(width: 600, height: 400)
        canvas.setImage(upgraded, selectionGeneration: 2, openingSourceRectInWindow: nil)
        XCTAssertTrue(canvas.presentedImage === upgraded)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(canvas.hasPagingContents)
        XCTAssertTrue(canvas.hasImageContents)
    }

    func testMatchingCommittedLayerRemainsCurrentDuringInteraction() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 2), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        let pending = try XCTUnwrap(canvas.presentedPagingImage)

        let incomingLayer = canvas.nextImageLayer
        canvas.resetForSelection(2, image: pending, itemID: 3)

        XCTAssertTrue(canvas.presentedImage === pending)
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer)

        canvas.setZoom(1.5)
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer)
        XCTAssertEqual(canvas.currentZoom, 1.5, accuracy: 0.001)
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testBothNeighborsArePreparedAndLayersRotateInBothDirections() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let previous = try bitmapImage(width: 160, height: 100)
        let next = try bitmapImage(width: 200, height: 100)
        canvas.previousImage = previous
        canvas.previousItemID = 1
        canvas.nextImage = next
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        let initialCurrent = canvas.currentImageLayer
        let initialPrevious = canvas.previousImageLayer
        let initialNext = canvas.nextImageLayer
        XCTAssertNotNil(initialPrevious.contents)
        XCTAssertNotNil(initialNext.contents)
        XCTAssertLessThan(initialPrevious.frame.maxX, canvas.bounds.minX)
        XCTAssertGreaterThan(initialNext.frame.minX, canvas.bounds.maxX)
        canvas.pagingAnimationDuration = 0
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        canvas.resetForSelection(2, image: next, itemID: 3)
        XCTAssertTrue(canvas.currentImageLayer === initialNext)
        XCTAssertTrue(canvas.previousImageLayer === initialCurrent)
        XCTAssertTrue(canvas.nextImageLayer === initialPrevious)

        canvas.previousImage = previous
        canvas.previousItemID = 2
        canvas.nextImage = nil
        canvas.nextItemID = nil
        canvas.syncNeighbors(generation: 2)
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 1)
        canvas.routePreciseScroll(delta: CGSize(width: 300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 1.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 1.2)
        canvas.resetForSelection(3, image: previous, itemID: 2)
        XCTAssertTrue(canvas.currentImageLayer === initialCurrent)
        XCTAssertTrue(canvas.nextImageLayer === initialNext)
        XCTAssertTrue(canvas.previousImageLayer === initialPrevious)
    }

    func testSelectionConfirmationDuringAnimationPromotesIncomingLayer() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let next = try bitmapImage(width: 200, height: 100)
        canvas.nextImage = next
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        let incomingLayer = canvas.nextImageLayer
        canvas.pagingAnimationDuration = 0.05
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        canvas.resetForSelection(2, image: next, itemID: 3)
        XCTAssertTrue(canvas.isAwaitingPage)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(canvas.isAwaitingPage)
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer)
        XCTAssertNotNil(canvas.currentImageLayer.contents)
    }

    func testConfirmedPageStaysInFlightUntilSettleAnimationFinishes() async throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let next = try bitmapImage(width: 200, height: 100)
        canvas.nextImage = next
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0.5
        let incomingLayer = canvas.nextImageLayer
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -250, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        canvas.resetForSelection(2, image: next, itemID: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(canvas.isAwaitingPage, "Selection confirmation must not end an active animation")
        XCTAssertFalse(canvas.currentImageLayer === incomingLayer)
        if let presentation = incomingLayer.presentation() {
            XCTAssertGreaterThan(presentation.frame.midX, incomingLayer.frame.midX + 1)
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(canvas.isAwaitingPage)
        XCTAssertTrue(canvas.currentImageLayer === incomingLayer)
    }

    func testCommittedPageUsesSmoothBrakingAnimation() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        let incoming = canvas.nextImageLayer
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        let animation = try XCTUnwrap(incoming.animation(forKey: "transition.position"))
        XCTAssertEqual(animation.duration, 0.2, accuracy: 0.001)
        let timing = try XCTUnwrap(animation.timingFunction)
        var controlPoint: [Float] = [0, 0]
        timing.getControlPoint(at: 2, values: &controlPoint)
        XCTAssertEqual(controlPoint[1], 1, accuracy: 0.001, "The animation ends at zero velocity")
    }

    func testNewSwipeInterruptsConfirmedPageAnimation() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        let second = try bitmapImage(width: 200, height: 100)
        let third = try bitmapImage(width: 100, height: 200)
        canvas.nextImage = second
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 1
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        canvas.resetForSelection(2, image: second, itemID: 3)
        canvas.previousImage = second
        canvas.previousItemID = 2
        canvas.nextImage = third
        canvas.nextItemID = 4
        canvas.syncNeighbors(generation: 2)

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0.3)
        canvas.routePreciseScroll(delta: CGSize(width: -50, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.31)
        XCTAssertTrue(canvas.isInteractivelyPaging, "A new gesture should take over while the prior page settles")
        XCTAssertTrue(canvas.presentedPagingImage === third)
    }

    func testIncomingNeighborCanBecomeAvailableDuringGesture() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -40, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        XCTAssertFalse(canvas.isInteractivelyPaging)
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.syncNeighbors(generation: 1)
        canvas.routePreciseScroll(delta: CGSize(width: -30, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.02)
        XCTAssertTrue(canvas.isInteractivelyPaging)
    }

    func testCommitKeepsSpacingWhenNeighborHasDifferentAspectRatio() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.nextImage = try bitmapImage(width: 100, height: 300)
        canvas.nextItemID = 3
        canvas.syncNeighbors(generation: 1)
        canvas.pagingAnimationDuration = 0
        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 0), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        let separation = canvas.presentedPagingFrame.midX - canvas.presentedImageFrame.midX
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.2)
        XCTAssertEqual(canvas.presentedPagingFrame.midX - canvas.presentedImageFrame.midX,
                       separation, accuracy: 0.5)
        XCTAssertLessThan(canvas.presentedImageFrame.maxX, canvas.bounds.minX)
    }

    func testDisabledPagingDoesNotPageHorizontally() throws {
        let (canvas, window) = makeCanvas()
        defer { window.orderOut(nil) }
        canvas.nextImage = try bitmapImage(width: 200, height: 100)
        canvas.nextItemID = 3
        canvas.interactivePagingEnabled = false
        let restFrame = canvas.presentedImageFrame

        canvas.routePreciseScroll(delta: .zero, phase: .began, momentumPhase: [], timestamp: 0)
        canvas.routePreciseScroll(delta: CGSize(width: -300, height: 2), phase: .changed,
                                  momentumPhase: [], timestamp: 0.01)
        canvas.routePreciseScroll(delta: .zero, phase: .ended, momentumPhase: [], timestamp: 0.02)

        XCTAssertFalse(canvas.isInteractivelyPaging)
        XCTAssertFalse(canvas.isAwaitingPage)
        XCTAssertEqual(canvas.presentedImageFrame.midX, restFrame.midX, accuracy: 0.5)
    }
}

private actor LivePhotoCanvasTransport: PhotosTransport {
    func livePhotoMotion(itemID: Int64) async throws -> VideoPlaybackResource? {
        // Ignore cancellation to exercise the canvas's stale-result fence.
        try? await Task.sleep(for: .milliseconds(150))
        return VideoPlaybackResource(unitID: 2, cacheKey: "key", filename: "motion.mp4", variant: .converted(.high))
    }
}
