import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var interaction: ((InteractionPhase) -> Void)?
    var commandHandler: ((BrowserSelectionCommand) -> Void)?
    var contextMenuHandler: ((CGPoint) -> NSMenu?)?
    var fileDragHandler: ((CGPoint, NSEvent) -> Bool)?
    var fileDragHitTest: ((CGPoint) -> Bool)?
    var cancelFileDrag: (() -> Void)?
    weak var timelineScrollView: TimelineScrollView?
    weak var overlay: SelectionOverlayView?
    var selectionFrames: [CGRect] = [] { didSet { overlay?.selectionFrames = selectionFrames } }
    var marquee: CGRect? { didSet { overlay?.marquee = marquee } }
    private var downPoint: CGPoint?
    private var beginsOnItem = false
    private var suppressPointerUp = false

    enum InteractionPhase {
        case down(CGPoint, clickCount: Int, shift: Bool, option: Bool)
        case drag(CGPoint)
        case up(CGPoint)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        beginsOnItem = event.clickCount == 1 && (fileDragHitTest?(point) ?? false)
        suppressPointerUp = false
        interaction?(.down(point, clickCount: event.clickCount,
                           shift: event.modifierFlags.contains(.shift),
                           option: event.modifierFlags.contains(.option)))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if beginsOnItem, let origin = downPoint {
            guard hypot(point.x - origin.x, point.y - origin.y) >= 5 else { return }
            let started = fileDragHandler?(origin, event) ?? false
            if !started { cancelFileDrag?() }
            downPoint = nil
            beginsOnItem = false
            suppressPointerUp = true
            return
        }
        if !suppressPointerUp { interaction?(.drag(point)) }
    }
    override func mouseUp(with event: NSEvent) {
        if !suppressPointerUp { interaction?(.up(convert(event.locationInWindow, from: nil))) }
        downPoint = nil
        beginsOnItem = false
        suppressPointerUp = false
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { timelineScrollView?.publishFocusState() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { timelineScrollView?.focusChanged?(false) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard let command = event.browserSelectionCommand else {
            super.keyDown(with: event)
            return
        }
        commandHandler?(command)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift) { commandHandler?(.endExtension) }
        super.flagsChanged(with: event)
    }
}

extension NSEvent {
    var browserSelectionCommand: BrowserSelectionCommand? {
        let relevant = modifierFlags.intersection([.command, .option, .control, .shift])
        if keyCode == 0, relevant == .command { return .selectAll }
        let disallowed = modifierFlags.intersection([.command, .option, .control])
        guard disallowed.isEmpty else { return nil }
        switch keyCode {
        case 123: return .move(.left, extending: modifierFlags.contains(.shift))
        case 124: return .move(.right, extending: modifierFlags.contains(.shift))
        case 126: return .move(.up, extending: modifierFlags.contains(.shift))
        case 125: return .move(.down, extending: modifierFlags.contains(.shift))
        case 49 where !modifierFlags.contains(.shift): return .openSelected
        default: return nil
        }
    }
}

final class SelectionOverlayView: NSView {
    override var isFlipped: Bool { true }
    /// Only the changed frames are invalidated; the overlay spans the whole document.
    var selectionFrames: [CGRect] = [] {
        didSet {
            guard oldValue != selectionFrames else { return }
            for frame in oldValue + selectionFrames { setNeedsDisplay(frame.insetBy(dx: -4, dy: -4)) }
        }
    }
    var marquee: CGRect? {
        didSet {
            guard oldValue != marquee else { return }
            for rect in [oldValue, marquee].compactMap({ $0 }) { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemBlue.setStroke()
        for frame in selectionFrames {
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
            path.lineWidth = 3
            path.stroke()
        }
        if let marquee {
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: marquee).fill()
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: marquee); path.lineWidth = 1; path.stroke()
        }
    }
}

final class PassThroughSourceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shared presentation state for the square/aspect-fit thumbnail morph. Cells read
/// `fillsFrame` from it, so a mode change animates the visible frames of attached cells
/// without reconfiguring them or reissuing media work.
@MainActor
final class BrowserThumbnailPresentation: ObservableObject {
    static let transitionDuration: TimeInterval = 0.22

    @Published private(set) var cropsToSquare: Bool
    @Published private(set) var isTransitioning = false
    private let transitionDuration: TimeInterval
    private var transitionTask: Task<Void, Never>?

    init(cropsToSquare: Bool, transitionDuration: TimeInterval = BrowserThumbnailPresentation.transitionDuration) {
        self.cropsToSquare = cropsToSquare
        self.transitionDuration = transitionDuration
    }

    /// Whether the current frame should aspect-fill. Filling is used at rest in square
    /// mode and for the whole morph in either direction.
    var fillsFrame: Bool {
        FixedPhotoGrid.fillsFrame(cropsToSquare: cropsToSquare, isTransitioning: isTransitioning)
    }

    /// Applies the requested presentation and, when animated, marks a transition in flight
    /// for a fixed duration. Rapid toggles supersede earlier completions, so the state
    /// always settles on the latest target.
    func setCropsToSquare(_ newValue: Bool, animated: Bool) {
        transitionTask?.cancel()
        transitionTask = nil
        cropsToSquare = newValue
        guard animated else {
            isTransitioning = false
            return
        }
        isTransitioning = true
        transitionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.transitionDuration))
            guard !Task.isCancelled else { return }
            self.isTransitioning = false
            self.transitionTask = nil
        }
    }
}

struct LibraryFilterEdgeDemandGeometry {
    static func resolve(direction: LibraryFilterScanDirection, top: CGFloat,
                        viewportHeight: CGFloat, documentHeight: CGFloat) -> LibraryFilterScanDirection? {
        switch direction {
        case .newer:
            return top <= viewportHeight * 2 ? direction : nil
        case .older:
            return top + viewportHeight >= max(0, documentHeight - viewportHeight * 2) ? direction : nil
        }
    }
}

/// Owns timeline scrolling and tracks whether its document or an accessibility item has focus.
final class TimelineScrollView: NSScrollView {
    var upload: PhotoUploadDrop?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { upload?.operation(for: sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { upload?.perform(sender) ?? false }
    var focusChanged: ((Bool) -> Void)?
    var userScroll: ((LibraryFilterScanDirection, UInt64) -> Void)?
    weak var keyboardResponder: NSView?
    private var scrollGeneration: UInt64 = 0
    private var lastScrollDirection: LibraryFilterScanDirection?

    var browserCommandContextActive: Bool {
        guard let window, window.isKeyWindow else { return false }
        if window.firstResponder === keyboardResponder { return true }
        return (window.firstResponder as? BrowserPhotoCellView)?.enclosingScrollView === self
    }

    @discardableResult
    func focusTimeline() -> Bool {
        guard let keyboardResponder else { return false }
        return window?.makeFirstResponder(keyboardResponder) == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateChanged(_:)),
                                                   name: name, object: window)
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if window.isKeyWindow,
               window.firstResponder == nil || window.firstResponder === window {
                self.focusTimeline()
            }
            self.publishFocusState()
        }
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        if notification.name == NSWindow.didBecomeKeyNotification, let window,
           window.firstResponder == nil || window.firstResponder === window {
            focusTimeline()
        }
        publishFocusState()
    }

    func publishFocusState() { focusChanged?(browserCommandContextActive) }

    override func mouseDown(with event: NSEvent) {
        focusTimeline()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        focusTimeline()
        let oldY = contentView.bounds.minY
        super.scrollWheel(with: event)
        let newY = contentView.bounds.minY
        let direction: LibraryFilterScanDirection?
        if newY < oldY || (newY == oldY && event.scrollingDeltaY > 0) { direction = .newer }
        else if newY > oldY || (newY == oldY && event.scrollingDeltaY < 0) { direction = .older }
        else { direction = nil }
        guard let direction else { return }
        let isDiscreteWheelEvent = event.phase.isEmpty && event.momentumPhase.isEmpty
        if event.phase == .began || isDiscreteWheelEvent || lastScrollDirection != direction {
            scrollGeneration &+= 1
        }
        lastScrollDirection = direction
        userScroll?(direction, scrollGeneration)
    }

}

struct HostedPlaceholder: View {
    let message: String
    var body: some View {
        Text(message).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
    }
}
