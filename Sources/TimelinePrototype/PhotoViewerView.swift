import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

@MainActor
protocol PhotoViewerSourceActivating: AnyObject {
    func activateViewerSource(_ anchor: PhotoViewerSourceAnchor)
}

@MainActor
final class PhotoViewerSourceAnchor {
    private weak var view: NSView?
    private(set) var itemID: Int64?
    private(set) var image: NSImage?

    func attach(_ view: NSView) { self.view = view }

    func update(itemID: Int64, image: NSImage?) {
        self.itemID = itemID
        self.image = image
    }

    func activate() {
        (view as? PhotoViewerSourceActivating)?.activateViewerSource(self)
    }

    func rectInWindowContent() -> CGRect? {
        guard let view, let window = view.window, let content = window.contentView,
              !view.isHidden, view.alphaValue > 0, !view.visibleRect.isEmpty else { return nil }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alphaValue == 0 { return nil }
            ancestor = current.superview
        }
        let rect = view.convert(view.bounds, to: content)
        guard rect.width > 0, rect.height > 0, content.bounds.intersects(rect) else { return nil }
        return rect
    }
}

struct PhotoViewerOpenRequest {
    let seed: PhotoViewerSeed
    let source: PhotoViewerSourceAnchor
}

struct WindowChromeMetrics: Equatable {
    var top: CGFloat = 0
    var trafficLightTrailing: CGFloat = 78
}

struct WindowChromeMetricsReader: NSViewRepresentable {
    let onChange: (WindowChromeMetrics) -> Void

    func makeNSView(context: Context) -> MetricsView {
        let view = MetricsView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MetricsView, context: Context) {
        view.onChange = onChange
        view.reportSoon()
    }

    final class MetricsView: NSView {
        var onChange: ((WindowChromeMetrics) -> Void)?
        private var last = WindowChromeMetrics(top: -1, trafficLightTrailing: -1)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            // Keep the native toolbar material across the whole window. The content
            // still extends behind it through fullSizeContentView.
            window.titlebarAppearsTransparent = false
            reportSoon()
        }

        override func layout() {
            super.layout()
            reportSoon()
        }

        func reportSoon() {
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window, let content = window.contentView else { return }
            let layout = convert(window.contentLayoutRect, from: nil)
            let contentBounds = convert(content.bounds, from: content)
            let top = isFlipped
                ? max(0, layout.minY - contentBounds.minY)
                : max(0, contentBounds.maxY - layout.maxY)
            let trafficLightTrailing = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
                .map { $0.convert($0.bounds, to: content).maxX }
                .max() ?? 0
            let metrics = WindowChromeMetrics(top: top, trafficLightTrailing: trafficLightTrailing)
            guard abs(metrics.top - last.top) > 0.5 ||
                    abs(metrics.trafficLightTrailing - last.trafficLightTrailing) > 0.5 else { return }
            last = metrics
            onChange?(metrics)
        }
    }
}

@MainActor
final class PhotoViewerPresentation: ObservableObject {
    @Published private(set) var state: PhotoViewerState?
    @Published private(set) var image: NSImage?
    @Published private(set) var decodeFailure: String?
    @Published private(set) var isDecodingFullImage = false
    @Published private(set) var invalidationMessage: String?
    @Published private(set) var isClosing = false
    @Published var zoom: Double = 1

    let session: PhotoViewerSession
    let source: PhotoViewerSourceAnchor
    let originalItemID: Int64
    let snapshotRevision: Int
    let canvasController = PhotoViewerCanvasController()
    private let initialItem: PhotoItem

    private var stateTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var thumbnailDecodeTask: Task<Void, Never>?
    private var currentGeneration: UInt64?
    private var lastThumbnailData: Data?
    private var lastFullData: Data?
    private var hasDisplayedFullImage = false

    init(repository: CachedPhotosRepository, index: LibraryIndex, request: PhotoViewerOpenRequest,
         thumbnailSize: ThumbnailSize, allowNetwork: Bool, snapshotRevision: Int) {
        source = request.source
        originalItemID = request.seed.item.id
        initialItem = request.seed.item
        self.snapshotRevision = snapshotRevision
        image = request.source.image
        session = PhotoViewerSession(repository: repository, index: index, seed: request.seed,
                                     thumbnailSize: thumbnailSize, allowNetwork: allowNetwork,
                                     maximumPages: 3)
        let session = session
        stateTask = Task { [weak self] in
            for await next in await session.states() {
                guard !Task.isCancelled else { return }
                self?.receive(next)
            }
        }
    }

    deinit {
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        let session = session
        Task { await session.close() }
    }

    var filename: String {
        if let state { return state.item?.filename ?? "Loading photo…" }
        return initialItem.filename ?? "Untitled"
    }

    var detailLine: String {
        guard let state else {
            let date = Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(initialItem.time)))
            return "\(date) · Opening…"
        }
        let date = state.item.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0.time))) }
        let status: String
        if let invalidationMessage { status = invalidationMessage }
        else if let failure = state.favoriteFailure { status = "Favorite change failed: \(failure)" }
        else if state.favoriteUpdating { status = "Updating favorite…" }
        else if let decodeFailure { status = decodeFailure }
        else if state.item == nil, case .failure(let message) = state.metadataStatus { status = message }
        else {
            switch state.fullImageStatus {
            case .idle: status = "Waiting for full resolution"
            case .loading: status = "Loading full resolution…"
            case .ready(let verified, let validationFailure):
                if isDecodingFullImage { status = "Decoding full resolution…" }
                else if let validationFailure { status = "Full resolution cached · \(validationFailure)" }
                else { status = verified ? "Full resolution" : "Full resolution cached" }
            case .failure(let message): status = message
            case .unsupported(let message): status = message
            }
        }
        return [date, status].compactMap { $0 }.joined(separator: " · ")
    }

    var showsLoadingIndicator: Bool {
        guard let state else { return true }
        if isDecodingFullImage { return true }
        if case .loading = state.fullImageStatus { return true }
        return false
    }

    var canRetry: Bool {
        guard invalidationMessage == nil, let state else { return false }
        if decodeFailure != nil { return true }
        if case .failure = state.fullImageStatus { return true }
        return false
    }

    var showsUnsupportedVideo: Bool { state?.item?.isVideo == true }

    var canToggleFavorite: Bool {
        invalidationMessage == nil && !isClosing && state?.item != nil &&
            state?.metadataVerified == true && state?.allowNetwork == true &&
            state?.favoriteUpdating == false
    }

    func toggleFavorite() {
        guard canToggleFavorite else { return }
        Task { await session.toggleFavorite() }
    }

    var emptyStateMessage: String? {
        guard image == nil, let state else { return nil }
        if let decodeFailure { return decodeFailure }
        if state.item == nil, case .failure(let message) = state.metadataStatus { return message }
        let thumbnailFailure: String?
        switch state.thumbnailStatus {
        case .failure(let message), .unsupported(let message): thumbnailFailure = message
        default: thumbnailFailure = nil
        }
        guard let thumbnailFailure else { return nil }
        switch state.fullImageStatus {
        case .failure(let message), .unsupported(let message): return message
        case .idle: return thumbnailFailure
        case .loading, .ready: return nil
        }
    }

    func navigatePrevious() {
        guard invalidationMessage == nil, !isClosing else { return }
        Task { await session.navigatePrevious() }
    }

    func navigateNext() {
        guard invalidationMessage == nil, !isClosing else { return }
        Task { await session.navigateNext() }
    }

    func updateAllowNetwork(_ allow: Bool) { Task { await session.updateAllowNetwork(allow) } }

    func retry() {
        guard !isClosing else { return }
        decodeFailure = nil
        lastFullData = nil
        Task { await session.retry() }
    }

    func invalidateForNewIndex() {
        guard invalidationMessage == nil else { return }
        invalidationMessage = "Library changed. Return to the library and reopen this photo."
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        Task { await session.close() }
    }

    @discardableResult
    func close() -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        Task { await session.close() }
        return true
    }

    private func receive(_ next: PhotoViewerState) {
        guard !next.isClosed else { return }
        if currentGeneration != next.selection.generation {
            currentGeneration = next.selection.generation
            lastThumbnailData = nil
            lastFullData = nil
            hasDisplayedFullImage = false
            decodeTask?.cancel()
            thumbnailDecodeTask?.cancel()
            decodeFailure = nil
            isDecodingFullImage = false
            image = next.selection.itemID == originalItemID ? source.image : nil
            zoom = 1
            canvasController.resetForSelection(next.selection.generation)
        }
        state = next
        if let data = next.fullImageData, lastFullData != data {
            lastFullData = data
            decodeFull(data, selection: next.selection)
        }
        if let data = next.thumbnailData, lastThumbnailData != data,
           !hasDisplayedFullImage, next.selection == state?.selection {
            lastThumbnailData = data
            decodeThumbnail(data, selection: next.selection)
        }
    }

    private func decodeThumbnail(_ data: Data, selection: PhotoViewerSelection) {
        thumbnailDecodeTask?.cancel()
        thumbnailDecodeTask = Task { [weak self] in
            guard let decoded = await DecodedImages.shared.image(from: data, maxPixel: 1600),
                  !Task.isCancelled, self?.state?.selection == selection,
                  self?.hasDisplayedFullImage == false else { return }
            self?.image = decoded
        }
    }

    private func decodeFull(_ data: Data, selection: PhotoViewerSelection) {
        decodeTask?.cancel()
        isDecodingFullImage = true
        decodeTask = Task { [weak self] in
            do {
                let bitmap = try await FullImageDecoder.shared.decode(data)
                guard !Task.isCancelled, self?.state?.selection == selection else { return }
                self?.image = NSImage(cgImage: bitmap.image,
                                      size: NSSize(width: bitmap.image.width, height: bitmap.image.height))
                self?.hasDisplayedFullImage = true
                self?.thumbnailDecodeTask?.cancel()
                self?.decodeFailure = nil
                self?.isDecodingFullImage = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.state?.selection == selection else { return }
                self?.decodeFailure = error.localizedDescription
                self?.isDecodingFullImage = false
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct PhotoViewerView: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    let sidebarWidth: CGFloat
    let toolbarInset: CGFloat
    let reduceMotion: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            PhotoViewerCanvas(image: viewer.image,
                              selectionGeneration: viewer.state?.selection.generation ?? 1,
                              zoom: viewer.zoom,
                              sidebarWidth: sidebarWidth,
                              toolbarInset: toolbarInset,
                              openingSourceRect: viewer.source.rectInWindowContent(),
                              reduceMotion: reduceMotion,
                              controller: viewer.canvasController,
                              onPrevious: viewer.navigatePrevious,
                              onNext: viewer.navigateNext,
                              onToggleFavorite: viewer.toggleFavorite,
                              onClose: onClose) { viewer.zoom = Double($0) }
                .accessibilityLabel(viewer.filename)

            if viewer.image == nil, !viewer.showsUnsupportedVideo,
               viewer.invalidationMessage == nil {
                if let message = viewer.emptyStateMessage {
                    Label(message, systemImage: "photo.badge.exclamationmark")
                        .font(.callout)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                } else {
                    ProgressView("Loading preview…")
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }

            if viewer.showsUnsupportedVideo {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                    Text("Video playback is not supported.")
                }
                .font(.callout)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            } else if let message = viewer.invalidationMessage {
                Label(message, systemImage: "arrow.clockwise")
                    .font(.callout)
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            } else if viewer.canRetry {
                Button("Retry Full Resolution") { viewer.retry() }
                    .buttonStyle(.glass)
                    .padding(.bottom, 24)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

@MainActor
final class PhotoViewerCanvasController {
    weak var view: PhotoViewerCanvasView?
    private var pendingGeneration: UInt64?

    func attach(_ view: PhotoViewerCanvasView) {
        self.view = view
        if let pendingGeneration {
            view.resetForSelection(pendingGeneration)
            self.pendingGeneration = nil
        }
    }

    func resetForSelection(_ generation: UInt64) {
        if let view { view.resetForSelection(generation) }
        else { pendingGeneration = generation }
    }

    func collapse(to rectInWindow: CGRect?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard let view else { completion(); return }
        view.collapse(to: rectInWindow, reduceMotion: reduceMotion, completion: completion)
    }
}

private struct PhotoViewerCanvas: NSViewRepresentable {
    let image: NSImage?
    let selectionGeneration: UInt64
    let zoom: Double
    let sidebarWidth: CGFloat
    let toolbarInset: CGFloat
    let openingSourceRect: CGRect?
    let reduceMotion: Bool
    let controller: PhotoViewerCanvasController
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleFavorite: () -> Void
    let onClose: () -> Void
    let onZoomChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> PhotoViewerCanvasView {
        let view = PhotoViewerCanvasView()
        view.onZoomChanged = onZoomChanged
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onToggleFavorite = onToggleFavorite
        view.onClose = onClose
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: PhotoViewerCanvasView, context: Context) {
        view.onZoomChanged = onZoomChanged
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onToggleFavorite = onToggleFavorite
        view.onClose = onClose
        view.sidebarWidth = sidebarWidth
        view.toolbarInset = toolbarInset
        view.reduceMotion = reduceMotion
        view.configureOpeningSource(openingSourceRect)
        view.setImage(image, selectionGeneration: selectionGeneration,
                      openingSourceRectInWindow: openingSourceRect)
        view.setZoom(CGFloat(zoom))
    }
}

final class PhotoViewerCanvasView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onClose: (() -> Void)?
    var sidebarWidth: CGFloat = 0 { didSet { updateGeometry() } }
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
            window?.makeFirstResponder(self)
        }
        updateGeometry()
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
        animationTimer?.invalidate()
        let destination = reduceMotion ? nil : rectInWindow.flatMap(convertWindowContentRect)
        transitionStartFrame = transform.imageFrame
        transitionTargetFrame = destination ?? transform.imageFrame
        transitionProgress = 0
        animate(duration: reduceMotion ? 0.12 : 0.24) { [weak self] value in
            guard let self else { return }
            transitionProgress = value
            backgroundAlpha = 1 - value
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
        if event.charactersIgnoringModifiers == ".",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onToggleFavorite?()
            return
        }
        switch event.keyCode {
        case 53: onClose?()
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

    private func viewportRect() -> CGRect {
        let leading = min(max(0, sidebarWidth), max(0, bounds.width - 1))
        let top = min(max(0, measuredToolbarInset()), max(0, bounds.height - 1))
        return CGRect(x: bounds.minX + leading, y: bounds.minY,
                      width: max(1, bounds.width - leading), height: max(1, bounds.height - top))
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
