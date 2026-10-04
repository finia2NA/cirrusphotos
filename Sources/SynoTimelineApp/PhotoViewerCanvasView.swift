import AppKit
import TimelineCore

final class PhotoViewerCanvasView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    var toolbarInset: CGFloat = 0 { didSet { updateGeometry() } }
    var reduceMotion = false

    private var image: NSImage?
    private var selectionGeneration: UInt64 = 0
    private var transform = PhotoViewportTransform(imageSize: CGSize(width: 1, height: 1), viewport: .zero)
    private var dragLocation: CGPoint?
    private var openingSourceRect: CGRect?
    private var transitionStartFrame: CGRect?
    private var transitionTargetFrame: CGRect?
    private var transitionProgress: CGFloat = 1
    private var backgroundAlpha: CGFloat = 1
    private var animationTimer: Timer?
    private var animationUpdate: ((CGFloat) -> Void)?
    private var animationCompletion: (() -> Void)?
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0
    private var hasOpened = false
    private var hasAcquiredFocus = false
    private var isClosing = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimation()
            return
        }
        if window != nil, !hasAcquiredFocus {
            hasAcquiredFocus = true
            requestKeyboardFocus()
        }
        updateGeometry()
    }

    /// SwiftUI installs the representable while the thumbnail's mouse/key event is
    /// still unwinding. Deferring the responder change prevents that source control
    /// from remaining the key target underneath the viewer.
    func requestKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isClosing else { return }
            window.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(backgroundAlpha).setFill()
        bounds.fill()
        guard let image else { return }
        let frame: CGRect
        if let start = transitionStartFrame, let target = transitionTargetFrame {
            frame = Self.interpolate(from: start, to: target, progress: transitionProgress)
        } else {
            frame = transform.imageFrame
        }
        image.draw(in: frame, from: .zero, operation: .sourceOver,
                   fraction: min(1, max(0, backgroundAlpha)), respectFlipped: true, hints: [
                    .interpolation: NSImageInterpolation.high
                   ])
    }

    func setImage(_ next: NSImage?, selectionGeneration: UInt64,
                  openingSourceRectInWindow: CGRect?) {
        guard !isClosing else { return }
        let selectionChanged = self.selectionGeneration != selectionGeneration
        if selectionChanged {
            self.selectionGeneration = selectionGeneration
            image = next
            transform.configure(imageSize: next?.size ?? CGSize(width: 1, height: 1), viewport: viewportRect())
            transform.reset()
            transitionStartFrame = nil
            transitionTargetFrame = nil
            transitionProgress = 1
            backgroundAlpha = 1
            if !hasOpened { openingSourceRect = openingSourceRectInWindow }
            if next != nil { beginOpeningIfPossible() }
            needsDisplay = true
            return
        }
        guard image !== next else { return }
        image = next
        if let next {
            transform.configure(imageSize: next.size, viewport: viewportRect())
            if !isClosing, transitionTargetFrame != nil { transitionTargetFrame = transform.imageFrame }
            if !hasOpened { beginOpeningIfPossible() }
        }
        needsDisplay = true
    }

    func configureOpeningSource(_ rect: CGRect?) {
        guard !hasOpened, let rect else { return }
        openingSourceRect = rect
        beginOpeningIfPossible()
    }

    func setZoom(_ value: CGFloat) {
        guard !isClosing else { return }
        guard abs(transform.zoom - value) > 0.001 else { return }
        finishOpeningForInteraction()
        transform.setZoom(value)
        needsDisplay = true
    }

    func resetForSelection(_ generation: UInt64) {
        guard generation != selectionGeneration else { return }
        stopAnimation()
        selectionGeneration = generation
        image = nil
        transform.reset()
        transitionStartFrame = nil
        transitionTargetFrame = nil
        transitionProgress = 1
        backgroundAlpha = 1
        onZoomChanged?(1)
        needsDisplay = true
    }

    func collapse(to rectInWindow: CGRect?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard !isClosing else { return }
        isClosing = true
        let renderedFrame: CGRect
        if let start = transitionStartFrame, let target = transitionTargetFrame {
            renderedFrame = Self.interpolate(from: start, to: target, progress: transitionProgress)
        } else {
            renderedFrame = transform.imageFrame
        }
        let startingAlpha = backgroundAlpha
        stopAnimation()
        let destination = reduceMotion ? nil : rectInWindow.flatMap(convertWindowContentRect)
        transitionStartFrame = renderedFrame
        transitionTargetFrame = destination ?? renderedFrame
        transitionProgress = 0
        animate(duration: reduceMotion ? 0.12 : 0.24) { [weak self] value in
            guard let self else { return }
            transitionProgress = value
            backgroundAlpha = startingAlpha * (1 - value)
            needsDisplay = true
        } completion: { [weak self] in
            self?.animationTimer = nil
            completion()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isClosing else { return }
        window?.makeFirstResponder(self)
        finishOpeningForInteraction()
        guard event.clickCount < 2 else {
            let point = convert(event.locationInWindow, from: nil)
            let target: CGFloat = transform.zoom > 1.01 ? 1 : 2
            transform.setZoom(target, anchoredAt: point)
            onZoomChanged?(transform.zoom)
            needsDisplay = true
            return
        }
        dragLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isClosing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let previous = dragLocation {
            transform.translate(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
            needsDisplay = true
        }
        dragLocation = point
    }

    override func mouseUp(with event: NSEvent) { dragLocation = nil }

    override func magnify(with event: NSEvent) {
        guard !isClosing else { return }
        finishOpeningForInteraction()
        let anchor = convert(event.locationInWindow, from: nil)
        transform.setZoom(transform.zoom * max(0.05, 1 + event.magnification), anchoredAt: anchor)
        onZoomChanged?(transform.zoom)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isClosing else { return }
        finishOpeningForInteraction()
        if event.hasPreciseScrollingDeltas {
            transform.translate(by: CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY))
        } else {
            let anchor = convert(event.locationInWindow, from: nil)
            let factor = exp(-event.scrollingDeltaY * 0.08)
            transform.setZoom(transform.zoom * factor, anchoredAt: anchor)
            onZoomChanged?(transform.zoom)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onClose?()
        case 123: onPrevious?()
        case 124: onNext?()
        default: super.keyDown(with: event)
        }
    }

    private func beginOpeningIfPossible() {
        guard image != nil else { return }
        guard let openingSourceRect else {
            hasOpened = true
            return
        }
        guard let source = convertWindowContentRect(openingSourceRect) else { return }
        hasOpened = true
        self.openingSourceRect = nil
        if reduceMotion {
            backgroundAlpha = 0
            animate(duration: 0.12) { [weak self] value in
                self?.backgroundAlpha = value
                self?.needsDisplay = true
            }
        } else {
            transitionStartFrame = source
            transitionTargetFrame = transform.imageFrame
            transitionProgress = 0
            backgroundAlpha = 0
            animate(duration: 0.26) { [weak self] value in
                self?.transitionProgress = value
                self?.backgroundAlpha = value
                self?.needsDisplay = true
            } completion: { [weak self] in
                self?.transitionStartFrame = nil
                self?.transitionTargetFrame = nil
                self?.needsDisplay = true
            }
        }
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        transform.configure(imageSize: image?.size ?? CGSize(width: 1, height: 1), viewport: viewportRect())
        if !isClosing, transitionTargetFrame != nil { transitionTargetFrame = transform.imageFrame }
        if !hasOpened { beginOpeningIfPossible() }
        needsDisplay = true
    }

    private func finishOpeningForInteraction() {
        guard hasOpened, transitionStartFrame != nil else { return }
        stopAnimation()
        transitionStartFrame = nil
        transitionTargetFrame = nil
        transitionProgress = 1
        backgroundAlpha = 1
        needsDisplay = true
    }

    func viewportRect() -> CGRect {
        let top = min(max(0, measuredToolbarInset()), max(0, bounds.height - 1))
        return CGRect(x: bounds.minX, y: bounds.minY,
                      width: max(1, bounds.width), height: max(1, bounds.height - top))
    }

    private func measuredToolbarInset() -> CGFloat {
        guard let window, let content = window.contentView else { return toolbarInset }
        let layout = convert(window.contentLayoutRect, from: nil)
        let contentRect = convert(content.bounds, from: content)
        let measured = max(0, contentRect.maxY - layout.maxY)
        return max(toolbarInset, measured)
    }

    private func convertWindowContentRect(_ rect: CGRect) -> CGRect? {
        guard let content = window?.contentView else { return nil }
        let local = convert(rect, from: content)
        return bounds.intersection(local).isNull ? nil : local
    }

    private func animate(duration: TimeInterval, update: @escaping (CGFloat) -> Void,
                         completion: @escaping () -> Void = {}) {
        stopAnimation()
        animationUpdate = update
        animationCompletion = completion
        animationStart = CACurrentMediaTime()
        animationDuration = duration
        let timer = Timer(timeInterval: 1 / 60, target: self,
                          selector: #selector(stepAnimation(_:)), userInfo: nil, repeats: true)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        update(0)
    }

    @objc private func stepAnimation(_ timer: Timer) {
        let raw = min(1, max(0, (CACurrentMediaTime() - animationStart) / animationDuration))
        let eased = raw * raw * (3 - 2 * raw)
        animationUpdate?(CGFloat(eased))
        guard raw >= 1 else { return }
        timer.invalidate()
        animationTimer = nil
        animationUpdate = nil
        let completion = animationCompletion
        animationCompletion = nil
        completion?()
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationUpdate = nil
        animationCompletion = nil
    }

    private static func interpolate(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }
}
