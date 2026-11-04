import AppKit
import Combine
import SwiftUI
import XCTest
@testable import SynoTimelineApp
@testable import PhotoCache

final class LibraryInputRoutingTests: XCTestCase {
    private final class KeyStateWindow: NSWindow {
        var reportsKey = true
        var reportedFirstResponder: NSResponder?
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { reportsKey }
        override var firstResponder: NSResponder? { reportedFirstResponder ?? super.firstResponder }
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let accepted = super.makeFirstResponder(responder)
            if accepted { reportedFirstResponder = responder }
            return accepted
        }
    }

    @MainActor
    private func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                       windowNumber: Int = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: windowNumber, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: keyCode))
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow,
                            clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                        clickCount: clickCount, pressure: 1))
    }

    @MainActor
    func testAppKitArrowAndSpaceDispatchMenuCommandIdentities() throws {
        let document = FlippedDocumentView()
        var received: [String] = []
        document.commandHandler = { command in
            switch command {
            case .move(.left, false): received.append("left")
            case .move(.down, true): received.append("shift-down")
            case .selectAll: received.append("select-all")
            case .openSelected: received.append("open")
            default: received.append("other")
            }
        }
        document.keyDown(with: try event(keyCode: 123))
        document.keyDown(with: try event(keyCode: 125, modifiers: .shift))
        document.keyDown(with: try event(keyCode: 49))
        document.keyDown(with: try event(keyCode: 0, modifiers: .command))
        document.keyDown(with: try event(keyCode: 123, modifiers: .option))
        document.keyDown(with: try event(keyCode: 49, modifiers: .control))
        XCTAssertEqual(received, ["left", "shift-down", "open", "select-all"])
    }

    @MainActor
    func testFileDragTakesPointerGestureAfterThreshold() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = document
        defer { window.orderOut(nil) }
        var starts = 0
        var phases: [String] = []
        document.fileDragHitTest = { _ in true }
        document.fileDragHandler = { _, _ in starts += 1; return true }
        document.interaction = { phase in
            switch phase { case .down: phases.append("down"); case .drag: phases.append("drag"); case .up: phases.append("up") }
        }
        document.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: window))
        document.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 100), in: window))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(phases, ["down"])
    }

    @MainActor
    func testPhotoDragNeverFallsBackToMarqueeWithModifiersOrFailedStart() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = document
        defer { window.orderOut(nil) }
        var starts = 0, cancellations = 0
        var phases: [String] = []
        document.fileDragHitTest = { _ in true }
        document.fileDragHandler = { _, _ in starts += 1; return false }
        document.cancelFileDrag = { cancellations += 1 }
        document.interaction = { phase in
            switch phase { case .down: phases.append("down"); case .drag: phases.append("drag"); case .up: phases.append("up") }
        }
        document.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: window, modifiers: .shift))
        document.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 103, y: 100), in: window, modifiers: .shift))
        document.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 100), in: window, modifiers: .shift))
        document.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 100), in: window, modifiers: .shift))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(phases, ["down"])
    }

    @MainActor
    func testEmptySpaceDragStillRoutesToMarquee() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = document
        defer { window.orderOut(nil) }
        var starts = 0
        var phases: [String] = []
        document.fileDragHitTest = { _ in false }
        document.fileDragHandler = { _, _ in starts += 1; return true }
        document.interaction = { phase in
            switch phase { case .down: phases.append("down"); case .drag: phases.append("drag"); case .up: phases.append("up") }
        }
        document.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: window, modifiers: .shift))
        document.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 100), in: window, modifiers: .shift))
        document.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 100), in: window, modifiers: .shift))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(phases, ["down", "drag", "up"])
    }

    @MainActor
    func testProductionHierarchyDispatchesPointerAndKeyboardInput() throws {
        let window = KeyStateWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let overlay = SelectionOverlayView(frame: document.bounds)
        document.overlay = overlay
        document.addSubview(overlay)
        let row = BrowserPhotoCellView(frame: CGRect(x: 0, y: 40, width: 320, height: 180))
        document.addSubview(row, positioned: .below, relativeTo: overlay)
        scroll.documentView = document
        scroll.keyboardResponder = document
        document.timelineScrollView = scroll
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        scroll.layoutSubtreeIfNeeded()

        var phases: [String] = []
        document.interaction = { phase in
            switch phase {
            case .down: phases.append("down")
            case .drag: phases.append("drag")
            case .up: phases.append("up")
            }
        }
        let documentPoint = CGPoint(x: 80, y: 100)
        let windowPoint = document.convert(documentPoint, to: nil)
        let contentPoint = window.contentView!.convert(windowPoint, from: nil)
        let receiver = try XCTUnwrap(window.contentView?.hitTest(contentPoint))
        XCTAssertTrue(receiver === document)
        receiver.mouseDown(with: try mouseEvent(.leftMouseDown, at: windowPoint, in: window))
        XCTAssertTrue(window.firstResponder === document)
        receiver.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                                    at: CGPoint(x: windowPoint.x + 70, y: windowPoint.y - 50),
                                                    in: window))
        receiver.mouseUp(with: try mouseEvent(.leftMouseUp,
                                              at: CGPoint(x: windowPoint.x + 35, y: windowPoint.y - 20),
                                              in: window))
        XCTAssertEqual(phases, ["down", "drag", "up"])

        var commands: [String] = []
        document.commandHandler = { command in
            switch command {
            case .openSelected: commands.append("open")
            case .move(.right, false): commands.append("right")
            default: commands.append("other")
            }
        }
        XCTAssertTrue(window.makeFirstResponder(document))
        window.reportedFirstResponder = document
        window.sendEvent(try event(keyCode: 124, windowNumber: window.windowNumber))
        window.sendEvent(try event(keyCode: 49, windowNumber: window.windowNumber))
        XCTAssertEqual(commands, ["right", "open"])
    }

    @MainActor
    func testMenuCommandsAreScopedByBrowserActiveState() {
        let model = LibraryModel()
        var calls = 0
        let owner = UUID()
        model.installBrowserCommands(owner: owner, active: false, canOpen: true, collection: .library(.personal)) { _ in calls += 1 }
        model.performBrowserCommand(.openSelected)
        XCTAssertEqual(calls, 0)
        model.installBrowserCommands(owner: owner, active: true, canOpen: true, collection: .library(.personal)) { _ in calls += 1 }
        model.performBrowserCommand(.openSelected)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testViewerCloseCommandIsEnabledOnlyWhileHandlerIsInstalled() {
        let model = LibraryModel()
        var closes = 0

        model.closeViewer()
        XCTAssertFalse(model.canCloseViewer)
        model.installViewerCloseHandler { closes += 1 }
        XCTAssertTrue(model.canCloseViewer)
        model.closeViewer()
        XCTAssertEqual(closes, 1)
        model.installViewerCloseHandler(nil)
        XCTAssertFalse(model.canCloseViewer)
    }

    @MainActor
    func testSharedBackCommandUsesTheCurrentlyInstalledPageHandler() {
        let model = LibraryModel()
        var destinations: [String] = []
        XCTAssertFalse(model.canNavigateBack)
        model.navigateBack()
        model.installBackHandler { destinations.append("album") }
        XCTAssertTrue(model.canNavigateBack)
        model.navigateBack()
        model.installBackHandler { destinations.append("map") }
        model.navigateBack()
        model.installBackHandler(nil)
        model.navigateBack()
        XCTAssertEqual(destinations, ["album", "map"])
        XCTAssertFalse(model.canNavigateBack)
    }

    @MainActor
    func testCommandAHasASelectionCommandAndRejectsExtraModifiers() throws {
        XCTAssertNotNil(try event(keyCode: 0, modifiers: .command).browserSelectionCommand)
        XCTAssertNil(try event(keyCode: 0, modifiers: [.command, .shift]).browserSelectionCommand)
        XCTAssertNil(try event(keyCode: 0, modifiers: [.command, .option]).browserSelectionCommand)
    }

    @MainActor
    func testRepeatedCommandRegistrationDoesNotPublishAndStaleOwnerCannotDeactivate() {
        let model = LibraryModel()
        var publications = 0, calls = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        let first = UUID(), second = UUID()
        model.installBrowserCommands(owner: first, active: true, canOpen: true, collection: .library(.personal)) { _ in calls += 10 }
        let afterInitial = publications
        model.installBrowserCommands(owner: first, active: true, canOpen: true, collection: .library(.personal)) { _ in calls += 10 }
        XCTAssertEqual(publications, afterInitial)
        model.installBrowserCommands(owner: second, active: true, canOpen: true, collection: .library(.personal)) { _ in calls += 1 }
        model.installBrowserCommands(owner: first, active: false, canOpen: false, collection: .library(.personal), handler: nil)
        XCTAssertTrue(model.browserCommandsActive)
        model.performBrowserCommand(.openSelected)
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testBrowserCommandContextRequiresItsWindowToBeKey() {
        let window = KeyStateWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = TimelineScrollView(frame: window.contentView?.bounds ?? .zero)
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        scroll.documentView = document
        scroll.keyboardResponder = document
        document.timelineScrollView = scroll
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(document))
        window.reportedFirstResponder = document
        var states: [Bool] = []
        scroll.focusChanged = { states.append($0) }

        scroll.publishFocusState()
        XCTAssertTrue(scroll.browserCommandContextActive)
        window.reportsKey = false
        scroll.publishFocusState()

        XCTAssertFalse(scroll.browserCommandContextActive)
        XCTAssertEqual(states, [true, false])
    }

    @MainActor
    func testSelectionOverlayUsesFlippedDocumentCoordinates() {
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 2_000))
        let overlay = SelectionOverlayView(frame: document.bounds)
        document.addSubview(overlay)
        XCTAssertTrue(document.isFlipped)
        XCTAssertTrue(overlay.isFlipped)
        let point = CGPoint(x: 37, y: 1_537)
        XCTAssertEqual(overlay.convert(point, from: document), point)
        overlay.selectionFrames = [CGRect(x: 11, y: 1_421, width: 79, height: 43)]
        overlay.marquee = CGRect(x: 5, y: 1_300, width: 140, height: 210)
        XCTAssertEqual(overlay.selectionFrames[0].minY, 1_421)
        XCTAssertEqual(overlay.marquee?.maxY, 1_510)
    }

    @MainActor
    func testPhotoCellsPassThroughWhileOrdinaryControlsRemainInteractive() {
        let ordinaryHost = NSView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        let retry = NSButton(title: "Retry", target: nil, action: nil)
        retry.frame = ordinaryHost.bounds
        ordinaryHost.addSubview(retry)
        XCTAssertTrue(ordinaryHost.hitTest(CGPoint(x: 60, y: 20)) === retry)

        let cell = BrowserPhotoCellView(frame: ordinaryHost.frame)
        XCTAssertNil(cell.hitTest(CGPoint(x: 60, y: 20)))
    }

    @MainActor
    func testThumbnailRetryControlReceivesClicksInsidePassThroughCell() throws {
        var retries = 0
        let cell = BrowserPhotoCellView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        cell.setRetry { retries += 1 }
        let window = NSWindow(contentRect: cell.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = cell
        defer { window.orderOut(nil) }
        cell.layoutSubtreeIfNeeded()
        let hit = try XCTUnwrap(cell.hitTest(CGPoint(x: 62, y: 62)))
        var view: NSView? = hit
        while view != nil, !(view is ThumbnailRetryControl) { view = view?.superview }
        let retry = try XCTUnwrap(view as? ThumbnailRetryControl)
        retry.performClick(nil)
        XCTAssertEqual(retries, 1)
        XCTAssertNil(cell.hitTest(CGPoint(x: 2, y: 2)))
    }

    @MainActor
    func testThumbnailFailuresSurviveRowReuseAndExplicitRetryClearsThem() {
        let failures = ThumbnailFailureRegistry()
        failures.record("item:medium")
        XCTAssertTrue(failures.contains("item:medium"))
        failures.clear("item:medium")
        XCTAssertFalse(failures.contains("item:medium"))
        for index in 0..<1_025 { failures.record("item:\(index)") }
        XCTAssertFalse(failures.contains("item:0"))
        XCTAssertTrue(failures.contains("item:1024"))
    }

    @MainActor
    func testThumbnailAccessibilityPressSelectsAndOpenIsSeparateAction() {
        let view = BrowserPhotoCellView()
        let anchor = view.anchor
        anchor.update(itemID: 7, image: nil)
        var selections = 0, opens = 0
        view.onSelect = { selections += 1 }
        view.onActivate = { _ in opens += 1 }
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(view.accessibilityCustomActions()?.first?.name, "Open")
        view.activateViewerSource(anchor)
        XCTAssertEqual(opens, 1)
    }

    @MainActor
    func testFocusedThumbnailSpaceAndArrowsUseBrowserCommandsWithExactModifiers() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = TimelineScrollView(frame: window.contentView?.bounds ?? .zero)
        let document = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let thumbnail = BrowserPhotoCellView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        document.addSubview(thumbnail)
        scroll.documentView = document
        window.contentView = scroll
        var commands: [String] = []
        thumbnail.onCommand = { command in
            switch command {
            case .openSelected: commands.append("open")
            case .move(.left, true): commands.append("shift-left")
            default: commands.append("other")
            }
        }
        XCTAssertTrue(window.makeFirstResponder(thumbnail))

        thumbnail.keyDown(with: try event(keyCode: 49))
        thumbnail.keyDown(with: try event(keyCode: 123, modifiers: .shift))
        thumbnail.keyDown(with: try event(keyCode: 123, modifiers: .option))
        thumbnail.keyDown(with: try event(keyCode: 49, modifiers: .command))

        XCTAssertEqual(commands, ["open", "shift-left"])
    }

    func testPointerInteractionCommitsMouseUpEndpoint() {
        var pointer = BrowserPointerInteraction()
        pointer.begin(at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(pointer.drag(to: CGPoint(x: 180, y: 220)),
                       CGRect(x: 10, y: 20, width: 170, height: 200))

        XCTAssertEqual(pointer.finish(at: CGPoint(x: 45, y: 80)),
                       CGRect(x: 10, y: 20, width: 35, height: 60))
        XCTAssertEqual(pointer.current, CGPoint(x: 45, y: 80))
    }

    func testMarqueeRetainsKnownHitsAcrossPageWindowsAndSupportsContraction() {
        let baseline = IndexSet([2, 20])
        var marquee = BrowserMarqueeSelection(baseline: baseline, toggles: true)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        let first = marquee.update(rectangle: large, loadedFrames: [
            1: CGRect(x: 10, y: 10, width: 20, height: 20),
            2: CGRect(x: 40, y: 10, width: 20, height: 20)
        ])
        XCTAssertEqual(first, IndexSet([1, 20]))
        let afterEviction = marquee.update(rectangle: large, loadedFrames: [
            8: CGRect(x: 10, y: 250, width: 20, height: 20)
        ])
        XCTAssertEqual(afterEviction, IndexSet([1, 8, 20]))
        let contracted = marquee.update(rectangle: CGRect(x: 0, y: 200, width: 100, height: 100),
                                         loadedFrames: [:])
        XCTAssertEqual(contracted, IndexSet([2, 8, 20]))
    }

    func testSelectionStatePersistsGenerationAndDetectsReorderAfterRecreation() {
        var state = BrowserSelectionState()
        state.bind(to: "descriptor")
        state.selection.replace(with: 3)
        XCTAssertFalse(state.reconcileMembership([4: 111]))
        let recreated = state
        XCTAssertEqual(recreated.selection.indexes, IndexSet(integer: 3))
        var restored = recreated
        XCTAssertTrue(restored.reconcileMembership([4: 222]))
        XCTAssertTrue(restored.selection.indexes.isEmpty)
        XCTAssertEqual(restored.membershipRevision, 1)
        restored.selection.replace(with: 5)
        let switchedAgain = restored
        XCTAssertEqual(switchedAgain.generation, "descriptor:1")
        XCTAssertEqual(switchedAgain.selection.indexes, IndexSet(integer: 5))
    }

    func testDeferredOpenRejectsABASelectionSequence() {
        var selection = LibrarySelection(); selection.bind(to: "descriptor:0")
        selection.replace(with: 4)
        let request = BrowserPendingOpen(ordinal: 4, generation: "descriptor:0", selectionEpoch: 10)
        XCTAssertTrue(request.matches(selection: selection, generation: "descriptor:0", selectionEpoch: 10))
        selection.replace(with: 8)
        selection.replace(with: 4)
        XCTAssertFalse(request.matches(selection: selection, generation: "descriptor:0", selectionEpoch: 12))
        XCTAssertFalse(request.matches(selection: selection, generation: "descriptor:1", selectionEpoch: 10))
    }
}
