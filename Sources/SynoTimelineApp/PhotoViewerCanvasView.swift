import AppKit
import QuartzCore
import TimelineCore

/// Full-window media canvas.
///
/// Rendering is compositor-backed: an appearance-matched backdrop layer and a separate image layer
/// hold the displayed bitmap, and all transitions animate only layer geometry and
/// opacity. The `NSImage` is uploaded to the image layer's `contents` once per identity
/// change, so no animation frame resamples it.
///
/// At fit zoom a predominantly downward two-finger trackpad swipe interacts with the
/// photo and can dismiss the viewer, while a predominantly horizontal swipe pages to
/// the adjacent photo using three reusable image layers. Above fit zoom precise scrolling pans
/// instead. Click-drag never dismisses or pages.
final class PhotoViewerCanvasView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    /// Invoked once when a fit-zoom downward swipe is released past the dismissal
    /// threshold. The canvas holds the dragged visual state until the shell calls
    /// `collapse(to:reduceMotion:completion:)`.
    var onInteractiveDismiss: (() -> Void)?
    var toolbarInset: CGFloat = 0 {
        didSet { if toolbarInset != oldValue { updateGeometry() } }
    }
    var reduceMotion = false
    /// Reduce Motion disables the spatial interactive gestures.
    var interactiveDismissalEnabled = true
    var interactivePagingEnabled = true
    var previousImage: NSImage?
    var nextImage: NSImage?
    var previousItemID: Int64?
    var nextItemID: Int64?
    var pagingAnimationDuration: TimeInterval = 0.2
    var interpolation: NSImageInterpolation = .none {
        didSet { if interpolation != oldValue { applyInterpolation() } }
    }
    var pagingInterpolation: NSImageInterpolation = .high {
        didSet {
            if pagingInterpolation != oldValue { applyPagingInterpolation() }
        }
    }

    private enum Phase: Equatable {
        case resting
        case opening
        case interactiveDismissal
        case awaitingDismissal
        case interactivePaging
        case pagingCommit
        case awaitingPage
        case pagingReturning
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
    private var imageLayer = CALayer()
    private let inspectionLayer = CALayer()
    private var previousLayer = CALayer()
    private var nextLayer = CALayer()
    private var previousLayerImage: NSImage?
    private var nextLayerImage: NSImage?
    private var neighborConfigurationGeneration: UInt64?
    private var pagingLayer: CALayer { pageDirection == .previous ? previousLayer : nextLayer }
    private var videoView: VideoPlayerContainerView?
    private var pendingVideo: VideoConfiguration?
    private var scrollMonitor: Any?
    private var image: NSImage?
    private var selectionGeneration: UInt64 = 0
    private var transform = PhotoViewportTransform(imageSize: CGSize(width: 1, height: 1), viewport: .zero)
    private var pagingTransform = PhotoViewportTransform(imageSize: CGSize(width: 1, height: 1), viewport: .zero)

    private var phase: Phase = .resting
    private var dragLocation: CGPoint?

    private var scrollGestureActive = false
    private var scrollDirectionLocked = false
    private var lockedPagingDirection: PhotoViewerPaging.Direction?
    private var scrollTranslation: CGSize = .zero
    private var scrollVelocitySample: (delta: CGSize, time: TimeInterval)?
    private var lastScrollVelocity: CGSize = .zero
    private var dismissTranslation: CGSize = .zero

    private var pendingPagingImage: NSImage?
    private var pendingPagingItemID: Int64?
    private var pageDirection: PhotoViewerPaging.Direction?
    private var pagingDistance: CGFloat = 0
    private var pagingInitialOffset: CGFloat = 0
    private var pagingRestFrame: CGRect = .zero
    private var pagingViewport: CGRect = .zero
    private var committedPageImage: NSImage?
    private var committedPageGeneration: UInt64?
    private var committedPageShownGeneration: UInt64?
    private var pageSlideFinished = false

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
        for neighbor in [previousLayer, nextLayer] where neighbor.superlayer == nil {
            neighbor.contentsGravity = .resize
            neighbor.magnificationFilter = .linear
            neighbor.minificationFilter = .linear
            neighbor.opacity = 0
            root.addSublayer(neighbor)
        }
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        backdropLayer.contentsScale = scale
        imageLayer.contentsScale = scale
        previousLayer.contentsScale = scale
        nextLayer.contentsScale = scale
    }

    // MARK: - View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
            videoView?.stop()
            cancelTransition()
            return
        }
        configureLayersIfNeeded()
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.videoView != nil, event.window === self.window,
                      event.hasPreciseScrollingDeltas,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.scrollWheel(with: event)
                return nil
            }
        }
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
        syncVideoFrame()
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

    func setVideo(_ configuration: VideoConfiguration?) {
        pendingVideo = configuration
        guard !isPagingPhase, phase != .closing else { return }
        reconcileVideo()
    }

    private func reconcileVideo() {
        guard !isPagingPhase, phase != .closing else { return }
        guard let configuration = pendingVideo else {
            videoView?.stop()
            videoView?.removeFromSuperview()
            videoView = nil
            return
        }
        let view: VideoPlayerContainerView
        if let existing = videoView { view = existing }
        else {
            view = VideoPlayerContainerView()
            videoView = view
            addSubview(view)
        }
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        view.toolbarInset = 0
        view.configure(repository: configuration.repository, resource: configuration.resource,
                       generation: configuration.generation, allowNetwork: configuration.allowNetwork,
                       poster: configuration.poster, isMuted: configuration.isMuted,
                       onMuteChanged: configuration.onMuteChanged)
        syncVideoFrame()
    }

    private func syncVideoFrame() {
        guard let view = videoView else { return }
        view.frame = imageLayer.frame
        view.layer?.opacity = imageLayer.opacity
    }

    // MARK: - Image

    func setImage(_ next: NSImage?, selectionGeneration: UInt64,
                  openingSourceRectInWindow: CGRect?) {
        guard phase != .closing else { return }
        if committedPageShownGeneration == selectionGeneration, next == nil {
            return
        }
        if isPagingPhase {
            if selectionGeneration != self.selectionGeneration { return }
            if committedPageGeneration != nil {
                if let next { committedPageImage = next }
            } else if let next, image !== next {
                image = next
            }
            return
        }
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
            syncVideoFrame()
            CATransaction.commit()
            clearNeighborLayers()
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
        case .interactivePaging, .pagingCommit, .awaitingPage, .pagingReturning:
            break
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

    func installPresentedImage(_ next: NSImage?, generation: UInt64) {
        guard phase != .closing else { return }
        selectionGeneration = generation
        committedPageShownGeneration = nil
        image = next
        transform.configure(imageSize: next?.size ?? CGSize(width: 1, height: 1),
                            viewport: viewportRect())
        transform.reset()
        cancelTransition()
        phase = .resting
        dismissTranslation = .zero
        resetScrollGesture()
        dragLocation = nil
        let contents = next.flatMap(Self.cgImage)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = contents
        imageLayer.frame = next == nil ? .zero : transform.imageFrame
        imageLayer.opacity = 1
        backdropLayer.opacity = 1
        syncVideoFrame()
        CATransaction.commit()
        clearNeighborLayers()
        hasOpened = true
    }

    func resetForSelection(_ generation: UInt64, image next: NSImage?, itemID: Int64?) {
        guard generation != selectionGeneration else { return }
        if (phase == .pagingCommit || phase == .awaitingPage),
           let itemID, itemID == pendingPagingItemID {
            selectionGeneration = generation
            committedPageGeneration = generation
            committedPageImage = next ?? pendingPagingImage
            if phase == .awaitingPage || pageSlideFinished {
                finishPagingCommit()
            }
            return
        }
        if isPagingPhase {
            cancelPaging()
        }
        selectionGeneration = generation
        committedPageShownGeneration = nil
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
            syncVideoFrame()
            CATransaction.commit()
        } else {
            image = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = nil
            imageLayer.frame = .zero
            imageLayer.opacity = 1
            backdropLayer.opacity = 1
            syncVideoFrame()
            CATransaction.commit()
        }
        clearNeighborLayers()
        onZoomChanged?(1)
    }

    /// Collapses the photo into the window-content destination rect. A `nil` destination,
    /// or Reduce Motion, uses a compositor opacity fade instead of a spatial transform.
    /// Reads the current presentation geometry, so it works from a resting, opening, or
    /// interactively dragged state without a jump.
    func collapse(to rectInWindow: CGRect?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard phase != .closing else { return }
        if phase == .interactivePaging || phase == .pagingReturning {
            cancelPaging()
        } else if phase == .pagingCommit || phase == .awaitingPage {
            if committedPageGeneration != nil {
                finishPagingCommit()
            } else {
                cancelPaging()
            }
        }
        if pendingPagingImage == nil {
            clearNeighborLayers()
        }
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
        if phase == .began || phase == .mayBegin {
            interruptPagingAnimationIfPossible()
        }
        guard self.phase == .resting || self.phase == .opening
            || self.phase == .interactiveDismissal
            || self.phase == .interactivePaging else { return }
        guard transform.zoom <= PhotoViewerCanvasView.fitZoomTolerance else {
            // Above fit zoom, precise scrolling always pans and never dismisses or pages.
            resetScrollGesture()
            transform.translate(by: delta)
            snapLayerToRest()
            return
        }
        guard (interactiveDismissalEnabled || interactivePagingEnabled), !reduceMotion else {
            transform.translate(by: delta)
            snapLayerToRest()
            return
        }
        handleGestureScroll(delta: delta, phase: phase, momentumPhase: momentumPhase,
                            timestamp: timestamp)
    }

    private func handleGestureScroll(delta: CGSize, phase: NSEvent.Phase,
                                     momentumPhase: NSEvent.Phase, timestamp: TimeInterval) {
        if phase == .began || phase == .mayBegin {
            beginGestureTracking()
        }
        guard scrollGestureActive else { return }

        if phase.isEmpty, !momentumPhase.isEmpty {
            return
        }

        recordScrollVelocity(delta: delta, timestamp: timestamp)
        scrollTranslation.width += delta.width
        scrollTranslation.height += delta.height
        applyGestureProgress()

        if phase == .ended || phase == .cancelled {
            finishScrollGesture(cancelled: phase == .cancelled, timestamp: timestamp)
        }
    }

    private func beginGestureTracking() {
        scrollGestureActive = true
        scrollDirectionLocked = false
        lockedPagingDirection = nil
        scrollTranslation = .zero
        scrollVelocitySample = nil
        lastScrollVelocity = .zero
    }

    private func applyGestureProgress() {
        if !scrollDirectionLocked {
            switch PhotoViewerDismissal.scrollIntent(translation: scrollTranslation) {
            case .dismiss:
                scrollDirectionLocked = true
                guard interactiveDismissalEnabled else { return }
                phase = .interactiveDismissal
            case .scroll:
                scrollDirectionLocked = true
                if interactivePagingEnabled {
                    lockedPagingDirection = PhotoViewerPaging.direction(translation: scrollTranslation)
                }
            case .undecided:
                return
            }
        }
        if phase == .resting, let direction = lockedPagingDirection,
           neighborConfigurationGeneration == selectionGeneration,
           let image = pagingImage(for: direction), let itemID = pagingItemID(for: direction) {
            beginPaging(direction: direction, image: image, itemID: itemID)
        }
        switch phase {
        case .interactiveDismissal:
            dismissTranslation = scrollTranslation
            applyDraggedFrame()
        case .interactivePaging:
            applyPagingFrame()
        default:
            break
        }
    }

    private func finishScrollGesture(cancelled: Bool, timestamp: TimeInterval) {
        let translation = scrollTranslation
        // A pause before release must not carry a stale flick velocity.
        let idle = timestamp - (scrollVelocitySample?.time ?? timestamp)
        let velocity = idle > 0.1 ? .zero : lastScrollVelocity
        resetScrollGesture()
        switch phase {
        case .interactiveDismissal:
            if !cancelled,
               PhotoViewerDismissal.shouldDismiss(translation: translation, velocity: velocity,
                                                   viewport: viewportRect()) {
                phase = .awaitingDismissal
                let dismiss = onInteractiveDismiss
                DispatchQueue.main.async { dismiss?() }
            } else {
                animateReturnToFit()
            }
        case .interactivePaging:
            guard let direction = pageDirection else {
                cancelPaging()
                return
            }
            if !cancelled,
               PhotoViewerPaging.shouldCommit(direction: direction,
                                              translation: PhotoViewerPaging.scaledHorizontal(translation),
                                              velocity: PhotoViewerPaging.scaledHorizontal(velocity),
                                              distance: pagingDistance) {
                commitPage(direction)
            } else {
                animatePageReturn()
            }
        default:
            if phase == .resting, abs(pagingInitialOffset) > 0.5 {
                pagingInitialOffset = 0
                animateReturnToFit()
            }
        }
    }

    /// Start a fresh gesture from the actual on-screen position of a settling photo.
    /// A committed selection is promoted only once the session has confirmed it.
    private func interruptPagingAnimationIfPossible() {
        guard phase == .pagingReturning || (phase == .pagingCommit && committedPageGeneration != nil) else { return }
        let isCommit = phase == .pagingCommit
        let visibleFrame = (isCommit ? pagingLayer : imageLayer).presentation()?.frame
            ?? (isCommit ? pagingLayer : imageLayer).frame
        cancelTransition()
        if isCommit { finishPagingCommit() } else { finishPagingReturn() }
        pagingInitialOffset = visibleFrame.midX - transform.imageFrame.midX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = transform.imageFrame.offsetBy(dx: pagingInitialOffset, dy: 0)
        syncVideoFrame()
        CATransaction.commit()
    }

    private var isPagingPhase: Bool {
        phase == .interactivePaging || phase == .pagingCommit
            || phase == .awaitingPage || phase == .pagingReturning
    }

    private func pagingImage(for direction: PhotoViewerPaging.Direction) -> NSImage? {
        direction == .next ? nextImage : previousImage
    }

    private func pagingItemID(for direction: PhotoViewerPaging.Direction) -> Int64? {
        direction == .next ? nextItemID : previousItemID
    }

    private var pagingDistanceForLayout: CGFloat {
        max(PhotoViewerPaging.pageDistance(viewport: viewportRect(),
                                           neighborFrame: pagingTransform.imageFrame),
            PhotoViewerPaging.exitDistance(currentFrame: transform.imageFrame,
                                          viewport: viewportRect()))
    }

    private func pagingViewportChanged() -> Bool {
        let current = viewportRect()
        return abs(current.width - pagingViewport.width) > 0.5 ||
            abs(current.height - pagingViewport.height) > 0.5
    }

    private func beginPaging(direction: PhotoViewerPaging.Direction,
                             image: NSImage, itemID: Int64) {
        syncNeighborLayers()
        pendingPagingImage = image
        pendingPagingItemID = itemID
        pageDirection = direction
        committedPageGeneration = nil
        committedPageShownGeneration = nil
        pageSlideFinished = false
        transform.reset()
        pagingTransform.configure(imageSize: image.size, viewport: viewportRect())
        pagingViewport = viewportRect()
        pagingDistance = pagingDistanceForLayout
        let offset = direction == .next ? pagingDistance : -pagingDistance
        pagingRestFrame = pagingTransform.imageFrame.offsetBy(dx: offset, dy: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pagingLayer.frame = pagingRestFrame
        pagingLayer.opacity = 1
        syncVideoFrame()
        CATransaction.commit()
        phase = .interactivePaging
        applyPagingFrame()
    }

    private func applyPagingFrame() {
        guard let direction = pageDirection else { return }
        let metrics = PhotoViewerPaging.metrics(translation: PhotoViewerPaging.scaledHorizontal(scrollTranslation),
                                                direction: direction,
                                                distance: pagingDistance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let offset = pagingInitialOffset + metrics.translation.width
        imageLayer.frame = transform.imageFrame.offsetBy(dx: offset, dy: 0)
        pagingLayer.frame = pagingRestFrame.offsetBy(dx: offset, dy: 0)
        imageLayer.opacity = 1
        pagingLayer.opacity = 1
        backdropLayer.opacity = 1
        syncVideoFrame()
        CATransaction.commit()
    }

    private func commitPage(_ direction: PhotoViewerPaging.Direction) {
        guard pendingPagingImage != nil, pendingPagingItemID != nil else {
            cancelPaging()
            return
        }
        phase = .pagingCommit
        let currentTarget = transform.imageFrame.offsetBy(
            dx: direction == .next ? -pagingDistance : pagingDistance, dy: 0)
        let pagingTarget = pagingTransform.imageFrame
        let navigate = direction == .next ? onNext : onPrevious
        DispatchQueue.main.async { navigate?() }
        startPagingAnimation(currentTarget: currentTarget, pagingTarget: pagingTarget,
                             duration: pagingAnimationDuration, committing: true) { [weak self] in
            guard let self, self.phase == .pagingCommit else { return }
            self.pageSlideFinished = true
            if self.committedPageGeneration != nil {
                self.finishPagingCommit()
            } else {
                self.phase = .awaitingPage
            }
        }
    }

    private func animatePageReturn() {
        phase = .pagingReturning
        startPagingAnimation(currentTarget: transform.imageFrame, pagingTarget: pagingRestFrame,
                             duration: min(pagingAnimationDuration, 0.24), committing: false) { [weak self] in
            guard let self, self.phase == .pagingReturning else { return }
            self.finishPagingReturn()
        }
    }

    private func finishPagingCommit() {
        guard let direction = pageDirection, let incoming = pendingPagingImage else { return }
        let finalImage = committedPageImage ?? incoming
        // Promote the layer that is already on screen. No contents or layer is removed
        // from the visible photo during the handoff.
        let outgoing = imageLayer
        if direction == .next {
            imageLayer = nextLayer
            nextLayer = previousLayer
            previousLayer = outgoing
            nextLayerImage = previousLayerImage
            previousLayerImage = nil
        } else {
            imageLayer = previousLayer
            previousLayer = nextLayer
            nextLayer = outgoing
            previousLayerImage = nextLayerImage
            nextLayerImage = nil
        }
        image = finalImage
        transform.configure(imageSize: incoming.size, viewport: viewportRect())
        transform.reset()
        resetPagingState()
        phase = .resting
        committedPageShownGeneration = selectionGeneration
        applyInterpolation()
        applyPagingInterpolation()
        if finalImage !== incoming {
            updateImageContents()
            transform.configure(imageSize: finalImage.size, viewport: viewportRect())
            snapLayerToRest()
        }
        syncNeighborLayers()
        reconcileVideo()
        onZoomChanged?(1)
    }

    private func finishPagingReturn() {
        updateImageContents()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = transform.imageFrame
        imageLayer.opacity = 1
        backdropLayer.opacity = 1
        syncVideoFrame()
        CATransaction.commit()
        resetPagingState()
        phase = .resting
        syncNeighborLayers()
        reconcileVideo()
    }

    private func cancelPaging() {
        imageLayer.removeAllAnimations()
        pagingLayer.removeAllAnimations()
        updateImageContents()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = transform.imageFrame
        imageLayer.opacity = 1
        backdropLayer.opacity = 1
        syncVideoFrame()
        CATransaction.commit()
        resetPagingState()
        phase = .resting
        syncNeighborLayers()
        reconcileVideo()
    }

    private func clearNeighborLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for neighbor in [previousLayer, nextLayer] {
            neighbor.removeAllAnimations()
            neighbor.contents = nil
            neighbor.frame = .zero
            neighbor.opacity = 0
        }
        previousLayerImage = nil
        nextLayerImage = nil
        syncVideoFrame()
        CATransaction.commit()
    }

    /// Update offscreen slots only for the selection represented by this canvas.
    func syncNeighbors(generation: UInt64) {
        neighborConfigurationGeneration = generation
        syncNeighborLayers()
    }

    private func syncNeighborLayers() {
        guard !isPagingPhase, neighborConfigurationGeneration == selectionGeneration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateNeighbor(previousLayer, image: previousImage, cached: &previousLayerImage, previous: true)
        updateNeighbor(nextLayer, image: nextImage, cached: &nextLayerImage, previous: false)
        syncVideoFrame()
        CATransaction.commit()
    }

    private func updateNeighbor(_ target: CALayer, image: NSImage?, cached: inout NSImage?, previous: Bool) {
        if cached !== image {
            target.contents = image.flatMap(Self.cgImage)
            cached = image
        }
        guard let image else { target.opacity = 0; return }
        let neighborTransform = PhotoViewportTransform(imageSize: image.size, viewport: viewportRect())
        let frame = neighborTransform.imageFrame
        let distance = max(PhotoViewerPaging.pageDistance(viewport: viewportRect(), neighborFrame: frame),
                           PhotoViewerPaging.exitDistance(currentFrame: transform.imageFrame, viewport: viewportRect()))
        target.frame = frame.offsetBy(dx: previous ? -distance : distance, dy: 0)
        target.opacity = 1
    }

    private func resetPagingState() {
        pendingPagingImage = nil
        pendingPagingItemID = nil
        pageDirection = nil
        pagingDistance = 0
        pagingInitialOffset = 0
        pagingRestFrame = .zero
        pagingViewport = .zero
        committedPageGeneration = nil
        committedPageImage = nil
        pageSlideFinished = false
        resetScrollGesture()
    }

    private func startPagingAnimation(currentTarget: CGRect, pagingTarget: CGRect,
                                      duration: TimeInterval, committing: Bool,
                                      completion: @escaping () -> Void) {
        animationGeneration &+= 1
        let generation = animationGeneration
        let currentFrom = imageLayer.presentation()?.frame ?? imageLayer.frame
        let pagingFrom = pagingLayer.presentation()?.frame ?? pagingLayer.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if duration > 0 {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                completion()
            }
            let timing = committing
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.65, 0.45, 1)
                : CAMediaTimingFunction(name: .easeOut)
            addAnimation(keyPath: "position",
                         from: NSValue(point: CGPoint(x: currentFrom.midX, y: currentFrom.midY)),
                         to: NSValue(point: CGPoint(x: currentTarget.midX, y: currentTarget.midY)),
                         duration: duration, timing: timing, to: imageLayer)
            addAnimation(keyPath: "position",
                         from: NSValue(point: CGPoint(x: pagingFrom.midX, y: pagingFrom.midY)),
                         to: NSValue(point: CGPoint(x: pagingTarget.midX, y: pagingTarget.midY)),
                         duration: duration, timing: timing, to: pagingLayer)
            animateVideoGeometry(from: currentFrom, to: currentTarget, duration: duration, timing: timing)
        } else {
            imageLayer.removeAllAnimations()
            pagingLayer.removeAllAnimations()
        }
        imageLayer.frame = currentTarget
        pagingLayer.frame = pagingTarget
        if duration <= 0 {
            syncVideoFrame()
            CATransaction.commit()
            completion()
            return
        }
        syncVideoFrame()
        CATransaction.commit()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onClose?()
        case 123, 124:
            guard phase == .resting || phase == .opening else { return }
            event.keyCode == 123 ? onPrevious?() : onNext?()
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Geometry

    func setInspectionOverlay(_ overlay: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if inspectionLayer.superlayer !== imageLayer {
            inspectionLayer.removeFromSuperlayer()
            imageLayer.addSublayer(inspectionLayer)
        }
        inspectionLayer.frame = imageLayer.bounds
        inspectionLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        inspectionLayer.contentsGravity = .resize
        inspectionLayer.magnificationFilter = .nearest
        inspectionLayer.contents = overlay
        CATransaction.commit()
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

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        syncVideoFrame()
        CATransaction.commit()
        transform.configure(imageSize: image?.size ?? CGSize(width: 1, height: 1), viewport: viewportRect())
        switch phase {
        case .resting:
            snapLayerToRest()
            syncNeighborLayers()
        case .interactiveDismissal, .awaitingDismissal:
            applyDraggedFrame()
        case .interactivePaging:
            if let image = pendingPagingImage, let direction = pageDirection {
                pagingTransform.configure(imageSize: image.size, viewport: viewportRect())
                pagingViewport = viewportRect()
                pagingDistance = pagingDistanceForLayout
                let offset = direction == .next ? pagingDistance : -pagingDistance
                pagingRestFrame = pagingTransform.imageFrame.offsetBy(dx: offset, dy: 0)
                applyPagingFrame()
            }
        case .pagingCommit, .awaitingPage:
            guard pagingViewportChanged() else { break }
            pagingViewport = viewportRect()
            cancelTransition()
            pageSlideFinished = true
            if committedPageGeneration != nil {
                finishPagingCommit()
            } else if let image = pendingPagingImage, let direction = pageDirection {
                pagingTransform.configure(imageSize: image.size, viewport: viewportRect())
                pagingLayer.frame = pagingTransform.imageFrame
                pagingDistance = pagingDistanceForLayout
                let offset = direction == .next ? -pagingDistance : pagingDistance
                imageLayer.frame = transform.imageFrame.offsetBy(dx: offset, dy: 0)
                phase = .awaitingPage
            }
        case .pagingReturning:
            guard pagingViewportChanged() else { break }
            pagingViewport = viewportRect()
            cancelTransition()
            finishPagingReturn()
        case .opening, .returning:
            retargetActiveTransition(to: transform.imageFrame)
        case .closing:
            if activeTransition?.fadeOnly != true, let rect = activeTransition?.destinationInWindow,
               let target = convertWindowContentRect(rect) {
                retargetActiveTransition(to: target)
            }
        }
        syncVideoFrame()
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
            syncVideoFrame()
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
            syncVideoFrame()
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
        syncVideoFrame()
        CATransaction.commit()
    }

    private func applyInterpolation() {
        let filter: CALayerContentsFilter = interpolation == .none ? .nearest : .linear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.magnificationFilter = filter
        imageLayer.minificationFilter = filter
        syncVideoFrame()
        CATransaction.commit()
    }

    private func applyPagingInterpolation() {
        let filter: CALayerContentsFilter = pagingInterpolation == .none ? .nearest : .linear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for neighbor in [previousLayer, nextLayer] {
            neighbor.magnificationFilter = filter
            neighbor.minificationFilter = filter
        }
        syncVideoFrame()
        CATransaction.commit()
    }

    private func snapLayerToRest() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = transform.imageFrame
        imageLayer.opacity = 1
        backdropLayer.opacity = 1
        syncVideoFrame()
        CATransaction.commit()
    }

    private func applyDraggedFrame() {
        let metrics = PhotoViewerDismissal.metrics(translation: dismissTranslation, viewport: viewportRect())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = draggedFrame()
        imageLayer.opacity = 1
        backdropLayer.opacity = Float(metrics.backdropOpacity)
        syncVideoFrame()
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
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            let completion = transition.completion
            self.activeTransition = nil
            completion?()
        }
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
            animateVideoGeometry(from: frame, to: transition.targetFrame, duration: duration, timing: timing)
        } else {
            imageLayer.removeAllAnimations()
            backdropLayer.removeAllAnimations()
        }
        imageLayer.frame = transition.targetFrame
        imageLayer.opacity = Float(transition.imageTo)
        backdropLayer.opacity = Float(transition.backdropTo)
        syncVideoFrame()
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

    /// AppKit owns the view layer's anchor point. Convert frame endpoints explicitly
    /// rather than copying the centered bitmap layer's position animation.
    private func animateVideoGeometry(from: CGRect, to: CGRect, duration: TimeInterval,
                                      timing: CAMediaTimingFunction) {
        guard let videoLayer = videoView?.layer else { return }
        let anchor = videoLayer.anchorPoint
        func position(in frame: CGRect) -> CGPoint {
            CGPoint(x: frame.minX + frame.width * anchor.x,
                    y: frame.minY + frame.height * anchor.y)
        }
        addAnimation(keyPath: "position", from: NSValue(point: position(in: from)),
                     to: NSValue(point: position(in: to)), duration: duration, timing: timing, to: videoLayer)
        addAnimation(keyPath: "bounds", from: NSValue(rect: CGRect(origin: .zero, size: from.size)),
                     to: NSValue(rect: CGRect(origin: .zero, size: to.size)),
                     duration: duration, timing: timing, to: videoLayer)
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
        if layer === imageLayer { videoView?.layer?.add(animation, forKey: "transition.\(keyPath)") }
    }

    private func cancelTransition() {
        animationGeneration &+= 1
        imageLayer.removeAllAnimations()
        videoView?.layer?.removeAllAnimations()
        backdropLayer.removeAllAnimations()
        previousLayer.removeAllAnimations()
        nextLayer.removeAllAnimations()
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
        lockedPagingDirection = nil
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
    var isInteractivelyPaging: Bool { phase == .interactivePaging }
    var isAwaitingPage: Bool { phase == .pagingCommit || phase == .awaitingPage }
    var backdropOpacity: CGFloat { CGFloat(backdropLayer.opacity) }
    var presentedImageFrame: CGRect { imageLayer.frame }
    var presentedPagingFrame: CGRect { pagingLayer.frame }
    var presentedPagingImage: NSImage? { pendingPagingImage }
    var hasPagingContents: Bool { pagingLayer.contents != nil && pagingLayer.opacity > 0 }
    var presentedImage: NSImage? { image }
    var hasImageContents: Bool { imageLayer.contents != nil }
    var currentZoom: CGFloat { transform.zoom }
    var currentImageLayer: CALayer { imageLayer }
    var previousImageLayer: CALayer { previousLayer }
    var nextImageLayer: CALayer { nextLayer }
}
