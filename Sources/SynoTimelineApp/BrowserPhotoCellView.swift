import AppKit
import OSLog
import PhotoCache
import SynologyAPI

/// What a browser cell shows and how it loads; the coordinator supplies one per visible item.
@MainActor
struct BrowserPhotoCellContent {
    let item: PhotoItem
    let ordinal: Int
    let repository: CachedPhotosRepository
    let size: ThumbnailSize
    let allowNetwork: Bool
    let collection: PhotoCollectionDescriptor
    let failures: ThumbnailFailureRegistry
}

/// One reusable photo cell of the browser grid: a layer-backed view whose frame is the
/// item's visible (fitted or square) frame in the document. The coordinator keeps a pool
/// of these and reassigns them while scrolling, so scrolling never builds views.
///
/// The decoded thumbnail is the backing layer's contents; badges and the placeholder symbol
/// are sublayers. Pointer input passes through to the document, which owns selection,
/// marquee, drag and menus; only the retry control receives clicks. The view still takes
/// keyboard focus and is the accessibility element and viewer-transition source for its item.
@MainActor
final class BrowserPhotoCellView: NSView, PhotoViewerSourceActivating, PhotoViewerSourceProviding {
    nonisolated static let maxPixel = 520

    let anchor = PhotoViewerSourceAnchor()
    var onSelect: (() -> Void)?
    var onCommand: ((BrowserSelectionCommand) -> Void)?
    var onActivate: ((PhotoViewerSourceAnchor) -> Void)?
    var selected = false
    private(set) var itemID: Int64?
    private var accessibilityTitle = "Open photo"

    /// Aspect-fill during the square morph and at rest in square mode.
    var fillsFrame = false {
        didSet { if oldValue != fillsFrame { needsDisplay = true } }
    }

    private var image: CGImage?
    private var quarterTurns = 0
    private var failed = false { didSet { if oldValue != failed { updatePlaceholder() } } }
    private let rotatedImageLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let favoriteBadge = CALayer()
    private let durationBadge = CATextLayer()
    private var retryButton: ThumbnailRetryControl?
    private var retryAction: (() -> Void)?

    private var content: BrowserPhotoCellContent?
    private var renditionIdentity: String?
    private var familyIdentity: String?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var loadInterval: OSSignpostIntervalState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        anchor.attach(self)
        guard let layer else { return }
        layer.cornerRadius = 4
        layer.masksToBounds = true
        rotatedImageLayer.isHidden = true
        rotatedImageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        placeholderLayer.autoresizingMask = [.layerMinXMargin, .layerMaxXMargin, .layerMinYMargin, .layerMaxYMargin]
        placeholderLayer.contentsGravity = .center
        favoriteBadge.isHidden = true
        favoriteBadge.cornerRadius = 4
        favoriteBadge.contentsGravity = .center
        durationBadge.isHidden = true
        durationBadge.cornerRadius = 3
        durationBadge.alignmentMode = .center
        durationBadge.autoresizingMask = [.layerMinXMargin]
        for sublayer in [rotatedImageLayer, placeholderLayer, favoriteBadge, durationBadge] {
            sublayer.actions = Self.noActions
            layer.addSublayer(sublayer)
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Implicit sublayer animations would trail behind cell reuse.
    private static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
        "string": NSNull(), "transform": NSNull(), "backgroundColor": NSNull()
    ]

    // MARK: Content

    /// Shows `content`. Loading restarts only when the rendition identity changes; badges,
    /// rotation, labels and selection update in place.
    func configure(_ content: BrowserPhotoCellContent, selected: Bool) {
        let item = content.item
        let descriptor = item.additional?.thumbnail
        let family = "\(content.collection.rawValue):\(item.id):\(descriptor?.unitID ?? 0):\(descriptor?.cacheKey ?? "missing")"
        let rendition = "\(family):\(content.size.rawValue):\(content.allowNetwork)"
        let repositoryChanged = self.content.map { $0.repository !== content.repository } ?? true
        self.content = content
        self.selected = selected
        itemID = item.id
        accessibilityTitle = "\(item.isVideo ? "Video" : "Photo"): \(item.filename ?? "Untitled")" +
            (item.isFavorite ? ", favorite" : "")
        setQuarterTurns(item.pendingRotationQuarterTurns)
        updateBadges(item)
        guard rendition != renditionIdentity || repositoryChanged else { return }
        if family != familyIdentity { setImage(nil, ns: nil) }
        familyIdentity = family
        renditionIdentity = rendition
        startLoad(content, family: family)
    }

    /// Returns the cell to the pool: no item, no image, no pending work.
    func resetForReuse() {
        cancelLoad()
        content = nil
        renditionIdentity = nil
        familyIdentity = nil
        itemID = nil
        selected = false
        failed = false
        setRetry(nil)
        setImage(nil, ns: nil)
        anchor.clear()
        favoriteBadge.isHidden = true
        durationBadge.isHidden = true
    }

    private func setImage(_ cgImage: CGImage?, ns: NSImage?) {
        image = cgImage
        if let itemID { anchor.update(itemID: itemID, image: ns) }
        updatePlaceholder()
        applyImage()
    }

    private func setQuarterTurns(_ turns: Int) {
        guard quarterTurns != turns else { return }
        quarterTurns = turns
        applyImage()
    }

    /// Unrotated images are the backing layer's contents, so they follow the view's own
    /// (possibly animated) frame; a pending rotation uses a transformed sublayer instead.
    private func applyImage() {
        needsDisplay = true
        let rotated = quarterTurns % 4 != 0 && image != nil
        rotatedImageLayer.isHidden = !rotated
        rotatedImageLayer.contents = rotated ? image : nil
        rotatedImageLayer.frame = bounds
        // SwiftUI's rotationEffect turns clockwise; Core Animation's positive angle is counterclockwise.
        rotatedImageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let rotated = quarterTurns % 4 != 0
        layer.contents = rotated ? nil : image
        let gravity: CALayerContentsGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        layer.contentsGravity = gravity
        rotatedImageLayer.contentsGravity = gravity
        layer.backgroundColor = resolved(NSColor.secondaryLabelColor.withAlphaComponent(0.08))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateAppearance()
    }

    private func updateAppearance() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for sublayer in [rotatedImageLayer, placeholderLayer, favoriteBadge, durationBadge] as [CALayer] {
            sublayer.contentsScale = scale
        }
        favoriteBadge.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        durationBadge.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        durationBadge.foregroundColor = NSColor.white.cgColor
        favoriteBadge.contents = Self.symbol("heart.fill", pointSize: 10, weight: .semibold, color: .white,
                                             appearance: effectiveAppearance, scale: scale)
        updatePlaceholder()
        needsDisplay = true
    }

    private func updatePlaceholder() {
        let visible = image == nil
        placeholderLayer.isHidden = !visible
        guard visible else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let name = failed ? "photo.badge.exclamationmark" : "photo"
        let color: NSColor = failed ? .secondaryLabelColor : .tertiaryLabelColor
        let symbol = Self.symbol(name, pointSize: 13, weight: .regular, color: color,
                                 appearance: effectiveAppearance, scale: scale)
        placeholderLayer.contents = symbol
        let size = symbol.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) } ?? .zero
        placeholderLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                        width: size.width, height: size.height)
    }

    private func updateBadges(_ item: PhotoItem) {
        favoriteBadge.isHidden = !item.isFavorite
        if item.isFavorite { favoriteBadge.frame = CGRect(x: 5, y: 5, width: 21, height: 19) }
        if item.type == "video", let duration = item.additional?.videoMeta?.duration, duration.isFinite, duration > 0 {
            let text = ThumbnailBadgeOverlay.formattedDuration(duration)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            if durationBadge.string as? String != text {
                durationBadge.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            }
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: ceil(textSize.width) + 10, height: ceil(textSize.height) + 4)
            durationBadge.frame = CGRect(x: bounds.width - size.width - 5, y: 5, width: size.width, height: size.height)
            durationBadge.isHidden = false
        } else {
            durationBadge.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotatedImageLayer.frame = bounds
        updatePlaceholder()
        if !durationBadge.isHidden {
            durationBadge.frame.origin.x = bounds.width - durationBadge.frame.width - 5
        }
        retryButton?.frame = CGRect(x: bounds.width - 32, y: bounds.height - 32, width: 28, height: 28)
        CATransaction.commit()
    }

    private func resolved(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
        return cgColor
    }

    private static var symbolCache: [String: CGImage] = [:]

    /// A tinted SF Symbol rendered once per appearance and scale.
    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor,
                               appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(appearance.name.rawValue)|\(scale)|\(color.description)"
        if let cached = symbolCache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        var result: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let size = base.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                base.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            var rect = CGRect(origin: .zero, size: size)
            result = tinted.cgImage(forProposedRect: &rect, context: nil,
                                    hints: [.ctm: AffineTransform(scale: scale)])
        }
        if let result { symbolCache[key] = result }
        return result
    }

    // MARK: Loading

    private func decodedKey(family: String, size: ThumbnailSize, repository: CachedPhotosRepository) -> String {
        "\(repository.namespace):\(family):\(size.rawValue):\(Self.maxPixel)"
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        endLoadInterval("ended")
    }

    private func endLoadInterval(_ outcome: StaticString) {
        guard let state = loadInterval else { return }
        loadInterval = nil
        SynologyDiagnostics.browserSignposts.endInterval("Thumbnail load", state, "\(outcome)")
    }

    /// Memory hits display synchronously; everything else reads, decodes and validates off
    /// the main thread and returns here only to show the decoded image.
    private func startLoad(_ content: BrowserPhotoCellContent, family: String) {
        cancelLoad()
        let generation = loadGeneration
        let signposter = SynologyDiagnostics.browserSignposts
        loadInterval = signposter.beginInterval("Thumbnail load", id: signposter.makeSignpostID())
        let identity = "\(family):\(content.size.rawValue)"
        let priorFailure = content.failures.contains(identity)
        failed = priorFailure
        setRetry(nil)
        let network = content.allowNetwork && !priorFailure
        let repository = content.repository
        if let hit = DecodedImages.shared.rendition(decodedKey(family: family, size: content.size, repository: repository)) {
            setImage(hit.cgImage, ns: hit.image)
            endLoadInterval("memory")
            if hit.verified || !network {
                updateRetry(content, identity: identity)
                return
            }
        }
        guard let descriptor = content.item.additional?.thumbnail else {
            failed = true
            endLoadInterval("ended")
            return
        }
        let size = content.size, collection = content.collection
        let keyPrefix = "\(repository.namespace):\(family)"
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Start to first repository result: repository actor wait plus "Cache lookup".
            var firstResult: OSSignpostIntervalState? = signposter.beginInterval("Thumbnail first result",
                                                                                 id: signposter.makeSignpostID())
            defer { if let firstResult { signposter.endInterval("Thumbnail first result", firstResult, "none") } }
            for await event in await repository.thumbnailWithFallback(descriptor, size: size,
                                                                      allowNetwork: network, collection: collection) {
                if let state = firstResult {
                    signposter.endInterval("Thumbnail first result", state)
                    firstResult = nil
                }
                guard !Task.isCancelled else { return }
                switch event {
                case .value(let value, let verified):
                    let key = "\(keyPrefix):\(value.size.rawValue):\(BrowserPhotoCellView.maxPixel)"
                    let rendition = await DecodedImages.shared.renditionImage(
                        key: key, data: value.data, verified: verified, maxPixel: BrowserPhotoCellView.maxPixel)
                    guard !Task.isCancelled else { return }
                    await self?.deliver(rendition, generation: generation)
                case .failure:
                    await self?.deliverFailure(generation: generation, identity: identity)
                }
            }
        }
    }

    private func deliver(_ rendition: DecodedImages.Rendition?, generation: UInt64) {
        guard generation == loadGeneration else { return }
        guard let rendition else { failed = true; return }
        setImage(rendition.cgImage, ns: rendition.image)
        endLoadInterval("displayed")
    }

    private func deliverFailure(generation: UInt64, identity: String) {
        guard generation == loadGeneration, let content else { return }
        failed = true
        content.failures.record(identity)
        updateRetry(content, identity: identity)
    }

    /// Mirrors the previous rule: a failed, network-eligible rendition offers a retry.
    private func updateRetry(_ content: BrowserPhotoCellContent, identity: String) {
        guard failed, content.allowNetwork, content.item.additional?.thumbnail?.isReady(content.size) == true else {
            setRetry(nil)
            return
        }
        setRetry { [weak self] in
            guard let self, let content = self.content, let family = self.familyIdentity else { return }
            content.failures.clear(identity)
            self.startLoad(content, family: family)
        }
    }

    /// Shows a retry control in the top trailing corner, or removes it.
    func setRetry(_ action: (() -> Void)?) {
        retryAction = action
        guard action != nil else {
            retryButton?.removeFromSuperview()
            retryButton = nil
            return
        }
        if retryButton == nil {
            let button = ThumbnailRetryControl()
            button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            button.bezelStyle = .roundRect
            button.isBordered = true
            button.toolTip = "Retry thumbnail"
            button.setAccessibilityLabel("Retry thumbnail")
            button.target = self
            button.action = #selector(retry)
            addSubview(button)
            retryButton = button
        }
        retryButton?.frame = CGRect(x: bounds.width - 32, y: bounds.height - 32, width: 28, height: 28)
    }

    @objc private func retry() { retryAction?() }

    // MARK: Input, focus and accessibility

    /// Pointer input belongs to the document; only the retry control is hit-testable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let retryButton, !isHidden else { return nil }
        let local = convert(point, from: superview)
        return retryButton.frame.contains(local) ? retryButton.hitTest(convert(local, to: retryButton.superview)) ?? retryButton : nil
    }

    override var acceptsFirstResponder: Bool { !isHidden }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { publishFocus() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { publishFocus() }
        return result
    }

    private func publishFocus() {
        DispatchQueue.main.async { [weak self] in
            (self?.enclosingScrollView as? TimelineScrollView)?.publishFocusState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        let disallowed = event.modifierFlags.intersection([.command, .option, .control])
        if event.keyCode == 36, disallowed.isEmpty {
            onSelect?()
        } else if let command = event.browserSelectionCommand {
            onCommand?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { !isHidden && itemID != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityTitle }
    override func accessibilityValue() -> Any? { selected ? "selected" : "not selected" }
    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Open") { [weak self] in
            guard let self else { return false }
            self.anchor.activate()
            return true
        }]
    }

    func activateViewerSource(_ anchor: PhotoViewerSourceAnchor) {
        onActivate?(anchor)
    }

    func viewerSourceAnchor(for itemID: Int64) -> PhotoViewerSourceAnchor? {
        !isHidden && anchor.itemID == itemID ? anchor : nil
    }

    override func resetCursorRects() {
        if !isHidden { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
