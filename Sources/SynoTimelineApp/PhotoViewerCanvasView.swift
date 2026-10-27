import AppKit
import QuartzCore
import TimelineCore

/// Full-window still-photo canvas.
///
/// Rendering is compositor-backed: an appearance-matched backdrop layer and a separate image layer
/// hold the displayed bitmap, and all transitions animate only layer geometry and
/// opacity. The `NSImage` is uploaded to the image layer's `contents` once per identity
/// change, so no animation frame resamples it.
///
/// At fit zoom a predominantly downward two-finger trackpad swipe interacts with the
/// photo and can dismiss the viewer. Above fit zoom precise scrolling pans instead.
/// Click-drag never dismisses.
final class PhotoViewerCanvasView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    /// Invoked once when a fit-zoom downward swipe is released past the dismissal
    /// threshold. The canvas holds the dragged visual state until the shell calls
    /// `collapse(to:reduceMotion:completion:)`.
    var onInteractiveDismiss: (() -> Void)?
    var toolbarInset: CGFloat = 0 { didSet { updateGeometry() } }
    var reduceMotion = false
    /// Videos and Reduce Motion never offer the spatial interactive gesture.
    var interactiveDismissalEnabled = true
    var interpolation: NSImageInterpolation = .none {
        didSet { if interpolation != oldValue { applyInterpolation() } }
    }

    private enum Phase: Equatable {
        case resting
        case opening
        case interactiveDismissal
        case awaitingDismissal
        case returning
        case closing
    }

    private struct SpatialTransition {
        var targetFrame: CGRect
        var backdropTo: CGFloat
        var imageTo: CGFloat
        var duration: TimeInterval
        var destinationInWindow: CGRect?
        var fadeOnly: Bool
        var completion: (() -> Void)?
    }

    private let backdropLayer = CALayer()
    private let imageLayer = CALayer()
    private var image: NSImage?
    private var selectionGeneration: UInt64 = 0
    private var transform = PhotoViewportTransform(imageSize: CGSize(width: 1, height: 1), viewport: .zero)

    private var phase: Phase = .resting
    private var dragLocation: CGPoint?

    private var scrollGestureActive = false
    private var scrollDirectionLocked = false
    private var scrollTranslation: CGSize = .zero
    private var scrollVelocitySample: (delta: CGSize, time: TimeInterval)?
    private var lastScrollVelocity: CGSize = .zero
    private var dismissTranslation: CGSize = .zero

    private var openingSourceRect: CGRect?
    private var activeTransition: SpatialTransition?
    private var animationGeneration: UInt64 = 0

    private var hasOpened = false
    private var hasAcquiredFocus = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayersIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayersIfNeeded()
    }

    // MARK: - Layer setup

    private func configureLayersIfNeeded() {
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true
        // The root layer stays clear so that fading the backdrop reveals the browser
        // mounted behind the viewer instead of a residual black fill.
        root.backgroundColor = nil
        root.isOpaque = false
        if backdropLayer.superlayer == nil {
            backdropLayer.frame = bounds
            root.addSublayer(backdropLayer)
        }
        updateBackdropColor()
        if imageLayer.superlayer == nil {
            imageLayer.contentsGravity = .resize
            imageLayer.magnificationFilter = .linear
            imageLayer.minificationFilter = .linear
            imageLayer.opacity = 1
            root.addSublayer(imageLayer)
        }
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        backdropLayer.contentsScale = scale
        imageLayer.contentsScale = scale
    }

    // MARK: - View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelTransition()
            return
        }
        configureLayersIfNeeded()
        updateBackingScale()
        if !hasAcquiredFocus {
            hasAcquiredFocus = true
            requestKeyboardFocus()
        }
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackdropColor()
    }

    private func updateBackdropColor() {
        let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.backgroundColor = (match == .darkAqua ? NSColor.black : NSColor.white).cgColor
        CATransaction.commit()
    }

    /// SwiftUI installs the representable while the thumbnail's mouse/key event is
    /// still unwinding. Deferring the responder change prevents that source control
    /// from remaining the key target underneath the viewer.
    func requestKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.phase != .closing else { return }
            window.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    // MARK: - Image

    func setImage(_ next: NSImage?, selectionGeneration: UInt64,
                  openingSourceRectInWindow: CGRect?) {
        guard phase != .closing else { return }
        let selectionChanged = self.selectionGeneration != selectionGeneration
        if selectionChanged {
            self.selectionGeneration = selectionGeneration
            image = next
            transform.configure(imageSize: next?.size ?? CGSize(width: 1, height: 1), viewport: viewportRect())
            transform.reset()
            cancelTransition()
            phase = .resting
            dismissTranslation = .zero
            resetScrollGesture()
            updateImageContents()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.opacity = 1
            imageLayer.opacity = 1
            imageLayer.frame = transform.imageFrame
            CATransaction.commit()
            if !hasOpened { openingSourceRect = openingSourceRectInWindow }
            if next != nil { beginOpeningIfPossible() }
            return
        }
        guard image !== next else { return }
        image = next
        updateImageContents()
        guard next != nil else { return }
        transform.configure(imageSize: next!.size, viewport: viewportRect())
        switch phase {
        case .resting:
            snapLayerToRest()
        case .interactiveDismissal, .awaitingDismissal:
            applyDraggedFrame()
        case .opening, .returning:
            retargetActiveTransition(to: transform.imageFrame)
        case .closing:
            if let rect = activeTransition?.destinationInWindow,
               let target = convertWindowContentRect(rect) {
                retargetActiveTransition(to: target)
            }
        }
        if !hasOpened { beginOpeningIfPossible() }
    }

    func configureOpeningSource(_ rect: CGRect?) {
        guard !hasOpened, let rect else { return }
        openingSourceRect = rect
        beginOpeningIfPossible()
    }

    func setZoom(_ value: CGFloat) {
        guard phase == .resting || phase == .opening else { return }
        guard abs(transform.zoom - value) > 0.001 else { return }
        finishOpeningForInteraction()
        transform.setZoom(value)
        snapLayerToRest()
    }

    func resetForSelection(_ generation: UInt64, image next: NSImage?) {
        guard generation != selectionGeneration else { return }
        selectionGeneration = generation
        cancelTransition()
        phase = .resting
        dismissTranslation = .zero
        resetScrollGesture()
        dragLocation = nil
        transform.configure(imageSize: next?.size ?? CGSize(width: 1, height: 1), viewport: viewportRect())
        transform.reset()
        if hasOpened, let next {
            image = next
            updateImageContents()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = transform.imageFrame
            imageLayer.opacity = 1
            backdropLayer.opacity = 1
            CATransaction.commit()
        } else {
            image = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = nil
            imageLayer.frame = .zero
            imageLayer.opacity = 1
            backdropLayer.opacity = 1
            CATransaction.commit()
        }
        onZoomChanged?(1)
    }

    /// Collapses the photo into the window-content destination rect. A `nil` destination,
    /// or Reduce Motion, uses a compositor opacity fade instead of a spatial transform.
    /// Reads the current presentation geometry, so it works from a resting, opening, or
    /// interactively dragged state without a jump.
    func collapse(to rectInWindow: CGRect?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard phase != .closing else { return }
        let from = currentPresentedFrame()
        let destination = reduceMotion ? nil : rectInWindow.flatMap(convertWindowContentRect)
        phase = .closing
        if let destination {
            startTransition(from: from, to: destination, backdropTo: 0, imageTo: 1,
                            duration: reduceMotion ? 0.12 : 0.24,
                            destinationInWindow: rectInWindow, fadeOnly: false, completion: completion)
        } else {
            startTransition(from: from, to: from, backdropTo: 0, imageTo: 0,
                            duration: reduceMotion ? 0.12 : 0.24,
                            destinationInWindow: nil, fadeOnly: true, completion: completion)
        }
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        guard phase == .resting || phase == .opening else { return }
        window?.makeFirstResponder(self)
        finishOpeningForInteraction()
        guard event.clickCount < 2 else {
            let point = convert(event.locationInWindow, from: nil)
            let target: CGFloat = transform.zoom > 1.01 ? 1 : 2
            transform.setZoom(target, anchoredAt: point)
            onZoomChanged?(transform.zoom)
            snapLayerToRest()
            return
        }
        dragLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase == .resting || phase == .opening else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let previous = dragLocation {
            transform.translate(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
            snapLayerToRest()
        }
        dragLocation = point
    }

    override func mouseUp(with event: NSEvent) { dragLocation = nil }

    override func magnify(with event: NSEvent) {
        guard phase == .resting || phase == .opening else { return }
        finishOpeningForInteraction()
        let anchor = convert(event.locationInWindow, from: nil)
        transform.setZoom(transform.zoom * max(0.05, 1 + event.magnification), anchoredAt: anchor)
        onZoomChanged?(transform.zoom)
        snapLayerToRest()
    }

    // MARK: - Scroll input

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            guard phase == .resting || phase == .opening else { return }
            finishOpeningForInteraction()
            // Preserve ordinary mouse-wheel zoom.
            let anchor = convert(event.locationInWindow, from: nil)
            let factor = exp(-event.scrollingDeltaY * 0.08)
            transform.setZoom(transform.zoom * factor, anchoredAt: anchor)
            onZoomChanged?(transform.zoom)
            snapLayerToRest()
            return
        }

        finishOpeningForInteraction()
        routePreciseScroll(delta: CGSize(width: event.scrollingDeltaX,
                                         height: -event.scrollingDeltaY),
                           phase: event.phase, momentumPhase: event.momentumPhase,
                           timestamp: event.timestamp)
    }

    /// Routes a precise trackpad scroll sample. An in-flight interactive dismissal keeps
    /// receiving samples; closing, awaiting-destination, and returning phases do not.
    /// Above fit zoom it always pans. At fit zoom it may drive interactive dismissal.
    /// Extracted from the event handler so the routing can be exercised without
    /// synthesizing scroll events.
    func routePreciseScroll(delta: CGSize, phase: NSEvent.Phase,
                            momentumPhase: NSEvent.Phase, timestamp: TimeInterval) {
        guard self.phase == .resting || self.phase == .opening
            || self.phase == .interactiveDismissal else { return }
        guard transform.zoom <= PhotoViewerCanvasView.fitZoomTolerance else {
            // Above fit zoom, precise scrolling always pans and never dismisses.
            resetScrollGesture()
            transform.translate(by: delta)
            snapLayerToRest()
            return
        }
        guard interactiveDismissalEnabled, !reduceMotion else {
            // Reduce Motion and videos keep the ordinary constrained scroll behavior.
            transform.translate(by: delta)
            snapLayerToRest()
            return
        }
        handleDismissalScroll(delta: delta, phase: phase, momentumPhase: momentumPhase,
                              timestamp: timestamp)
    }

    private func handleDismissalScroll(delta: CGSize, phase: NSEvent.Phase,
                                       momentumPhase: NSEvent.Phase, timestamp: TimeInterval) {
        if phase == .began || phase == .mayBegin {
            scrollGestureActive = true
            scrollDirectionLocked = false
            scrollTranslation = .zero
            scrollVelocitySample = nil
            lastScrollVelocity = .zero
        }
        guard scrollGestureActive else { return }

        if phase.isEmpty, !momentumPhase.isEmpty {
            // Momentum after release: the gesture decision was already made.
            return
        }

        recordScrollVelocity(delta: delta, timestamp: timestamp)
        scrollTranslation.width += delta.width
        scrollTranslation.height += delta.height
        applyScrollProgress()

        if phase == .ended || phase == .cancelled {
            finishScrollGesture(cancelled: phase == .cancelled, timestamp: timestamp)
        }
    }

    private func applyScrollProgress() {
        if !scrollDirectionLocked {
            switch PhotoViewerDismissal.scrollIntent(translation: scrollTranslation) {
            case .dismiss:
                scrollDirectionLocked = true
                phase = .interactiveDismissal
            case .scroll:
                // Horizontal or upward: stay at rest for the rest of this gesture.
                scrollDirectionLocked = true
                return
            case .undecided:
                return
            }
        }
        guard phase == .interactiveDismissal else { return }
        dismissTranslation = scrollTranslation
        applyDraggedFrame()
    }

    private func finishScrollGesture(cancelled: Bool, timestamp: TimeInterval) {
        let translation = scrollTranslation
        // A pause before release must not carry a stale flick velocity.
        let idle = timestamp - (scrollVelocitySample?.time ?? timestamp)
        let velocity = idle > 0.1 ? .zero : lastScrollVelocity
        resetScrollGesture()
        guard phase == .interactiveDismissal else { return }
        if !cancelled,
           PhotoViewerDismissal.shouldDismiss(translation: translation, velocity: velocity,
                                               viewport: viewportRect()) {
            phase = .awaitingDismissal
            let dismiss = onInteractiveDismiss
            DispatchQueue.main.async { dismiss?() }
        } else {
            animateReturnToFit()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onClose?()
        case 123: onPrevious?()
        case 124: onNext?()
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Geometry

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

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        CATransaction.commit()
        transform.configure(imageSize: image?.size ?? CGSize(width: 1, height: 1), viewport: viewportRect())
        switch phase {
        case .resting:
            snapLayerToRest()
        case .interactiveDismissal, .awaitingDismissal:
            applyDraggedFrame()
        case .opening, .returning:
            retargetActiveTransition(to: transform.imageFrame)
        case .closing:
            if activeTransition?.fadeOnly != true, let rect = activeTransition?.destinationInWindow,
               let target = convertWindowContentRect(rect) {
                retargetActiveTransition(to: target)
            }
        }
        if !hasOpened { beginOpeningIfPossible() }
    }

    private func beginOpeningIfPossible() {
        guard image != nil else { return }
        guard let openingSourceRect else { hasOpened = true; return }
        guard let source = convertWindowContentRect(openingSourceRect) else { return }
        hasOpened = true
        self.openingSourceRect = nil
        updateImageContents()
        if reduceMotion {
            phase = .resting
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = transform.imageFrame
            imageLayer.opacity = 1
            backdropLayer.opacity = 0
            CATransaction.commit()
            startTransition(from: transform.imageFrame, to: transform.imageFrame,
                            backdropTo: 1, imageTo: 1, duration: 0.12,
                            destinationInWindow: nil, fadeOnly: false) { [weak self] in
                guard let self, self.phase == .resting else { return }
                self.activeTransition = nil
            }
        } else {
            phase = .opening
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = source
            imageLayer.opacity = 1
            backdropLayer.opacity = 0
            CATransaction.commit()
            startTransition(from: source, to: transform.imageFrame,
                            backdropTo: 1, imageTo: 1, duration: 0.26,
                            destinationInWindow: nil, fadeOnly: false) { [weak self] in
                guard let self, self.phase == .opening else { return }
                self.phase = .resting
            }
        }
    }

    private func finishOpeningForInteraction() {
        guard phase == .opening else { return }
        cancelTransition()
        phase = .resting
        snapLayerToRest()
    }

    private func animateReturnToFit() {
        phase = .returning
        let from = currentPresentedFrame()
        startTransition(from: from, to: transform.imageFrame, backdropTo: 1, imageTo: 1,
                        duration: 0.3, destinationInWindow: nil, fadeOnly: false) { [weak self] in
            guard let self, self.phase == .returning else { return }
            self.phase = .resting
            self.dismissTranslation = .zero
        }
    }

    /// The frame currently on screen, honoring an in-flight animation.
    private func currentPresentedFrame() -> CGRect {
        if let presented = imageLayer.presentation() { return presented.frame }
        return imageLayer.frame
    }

    private func draggedFrame() -> CGRect {
        let base = transform.imageFrame
        let metrics = PhotoViewerDismissal.metrics(translation: dismissTranslation, viewport: viewportRect())
        let size = CGSize(width: base.width * metrics.scale, height: base.height * metrics.scale)
        return CGRect(x: base.midX + metrics.translation.width - size.width / 2,
                      y: base.midY + metrics.translation.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: - Layer updates

    private func updateImageContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.flatMap(Self.cgImage)
        CATransaction.commit()
    }

    private func applyInterpolation() {
        let filter: CALayerContentsFilter = interpolation == .none ? .nearest : .linear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.magnificationFilter = filter
        imageLayer.minificationFilter = filter
        CATransaction.commit()
    }

    private func snapLayerToRest() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = transform.imageFrame
        imageLayer.opacity = 1
        backdropLayer.opacity = 1
        CATransaction.commit()
    }

    private func applyDraggedFrame() {
        let metrics = PhotoViewerDismissal.metrics(translation: dismissTranslation, viewport: viewportRect())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = draggedFrame()
        imageLayer.opacity = 1
        backdropLayer.opacity = Float(metrics.backdropOpacity)
        CATransaction.commit()
    }

    // MARK: - Animation

    private func startTransition(from frame: CGRect, to target: CGRect, backdropTo: CGFloat,
                                 imageTo: CGFloat, duration: TimeInterval,
                                 destinationInWindow: CGRect?, fadeOnly: Bool,
                                 completion: (() -> Void)?) {
        let transition = SpatialTransition(targetFrame: target, backdropTo: backdropTo,
                                           imageTo: imageTo, duration: duration,
                                           destinationInWindow: destinationInWindow,
                                           fadeOnly: fadeOnly, completion: completion)
        activeTransition = transition
        startAnimation(from: frame, transition: transition)
    }

    private func retargetActiveTransition(to newTarget: CGRect) {
        guard var transition = activeTransition else { return }
        guard !Self.approximatelyEqual(transition.targetFrame, newTarget) else { return }
        transition.targetFrame = newTarget
        activeTransition = transition
        startAnimation(from: currentPresentedFrame(), transition: transition)
    }

    private func startAnimation(from frame: CGRect, transition: SpatialTransition) {
        animationGeneration &+= 1
        let generation = animationGeneration
        let fromImageOpacity = imageLayer.presentation()?.opacity ?? imageLayer.opacity
        let fromBackdropOpacity = backdropLayer.presentation()?.opacity ?? backdropLayer.opacity
        let duration = max(0, transition.duration)
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if duration > 0 {
            addAnimation(keyPath: "position",
                         from: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)),
                         to: NSValue(point: CGPoint(x: transition.targetFrame.midX,
                                                    y: transition.targetFrame.midY)),
                         duration: duration, timing: timing, to: imageLayer)
            addAnimation(keyPath: "bounds",
                         from: NSValue(rect: CGRect(origin: .zero, size: frame.size)),
                         to: NSValue(rect: CGRect(origin: .zero, size: transition.targetFrame.size)),
                         duration: duration, timing: timing, to: imageLayer)
            addAnimation(keyPath: "opacity", from: NSNumber(value: Float(fromImageOpacity)),
                         to: NSNumber(value: Float(transition.imageTo)),
                         duration: duration, timing: timing, to: imageLayer)
            addAnimation(keyPath: "opacity", from: NSNumber(value: Float(fromBackdropOpacity)),
                         to: NSNumber(value: Float(transition.backdropTo)),
                         duration: duration, timing: timing, to: backdropLayer)
        } else {
            imageLayer.removeAllAnimations()
            backdropLayer.removeAllAnimations()
        }
        imageLayer.frame = transition.targetFrame
        imageLayer.opacity = Float(transition.imageTo)
        backdropLayer.opacity = Float(transition.backdropTo)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            let completion = transition.completion
            self.activeTransition = nil
            completion?()
        }
        CATransaction.commit()
    }

    private func addAnimation(keyPath: String, from: NSValue, to: NSValue,
                              duration: TimeInterval, timing: CAMediaTimingFunction,
                              to layer: CALayer) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "transition.\(keyPath)")
    }

    private func addAnimation(keyPath: String, from: NSNumber, to: NSNumber,
                              duration: TimeInterval, timing: CAMediaTimingFunction,
                              to layer: CALayer) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "transition.\(keyPath)")
    }

    private func cancelTransition() {
        animationGeneration &+= 1
        imageLayer.removeAllAnimations()
        backdropLayer.removeAllAnimations()
        activeTransition = nil
    }

    // MARK: - Scroll gesture tracking

    private func recordScrollVelocity(delta: CGSize, timestamp: TimeInterval) {
        // Only actual movement samples define velocity; the terminal phase event
        // carries no motion and would otherwise invert the release direction.
        guard hypot(delta.width, delta.height) > 0.01 else { return }
        defer { scrollVelocitySample = (delta, timestamp) }
        guard let previous = scrollVelocitySample else { return }
        let dt = timestamp - previous.time
        guard dt > 0.0005 else { return }
        lastScrollVelocity = CGSize(width: delta.width / dt, height: delta.height / dt)
    }

    private func resetScrollGesture() {
        scrollGestureActive = false
        scrollDirectionLocked = false
        scrollTranslation = .zero
        scrollVelocitySample = nil
        lastScrollVelocity = .zero
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midX - rhs.midX) < 0.5 && abs(lhs.midY - rhs.midY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    // MARK: - Test observation

    static let fitZoomTolerance: CGFloat = 1.01
    var isInteractivelyDismissing: Bool { phase == .interactiveDismissal }
    var isAwaitingInteractiveDismissal: Bool { phase == .awaitingDismissal }
    var backdropOpacity: CGFloat { CGFloat(backdropLayer.opacity) }
    var presentedImageFrame: CGRect { imageLayer.frame }
    var presentedImage: NSImage? { image }
    var hasImageContents: Bool { imageLayer.contents != nil }
    var currentZoom: CGFloat { transform.zoom }
}
