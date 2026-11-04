import AppKit
import CryptoKit
import ImageIO
import PhotoCache
import SwiftUI
import SynologyAPI

/// A reusable, demand-loaded thumbnail for a frame supplied by its parent row.
struct ThumbnailCell: View {
    let item: PhotoItem
    let repository: CachedPhotosRepository?
    let size: ThumbnailSize
    let allowNetwork: Bool
    var collection: PhotoCollectionDescriptor
    let failures: ThumbnailFailureRegistry
    var fillsFrame = false
    var isSelected = false
    var onSelect: (() -> Void)? = nil
    var onCommand: ((BrowserSelectionCommand) -> Void)? = nil
    var onActivate: ((PhotoViewerSourceAnchor) -> Void)? = nil
    @State private var image: NSImage?
    @State private var displayedRendition: String?
    @State private var failed = false
    @State private var retryID = UUID()

    private var descriptor: ThumbnailInfo? { item.additional?.thumbnail }
    private var familyIdentity: String {
        "\(collection.rawValue):\(item.id):\(descriptor?.unitID ?? 0):\(descriptor?.cacheKey ?? "missing")"
    }
    private var renditionIdentity: String {
        "\(familyIdentity):\(size.rawValue)"
    }
    private var taskIdentity: String { "\(renditionIdentity):\(allowNetwork):\(retryID)" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
            if let image, displayedRendition?.hasPrefix(familyIdentity) == true {
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                    .rotationEffect(.degrees(Double(item.pendingRotationQuarterTurns * 90)))
            } else if failed, displayedRendition == renditionIdentity {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
            if let onActivate {
                ThumbnailActivationSurface(itemID: item.id, image: image,
                                           isSelected: isSelected,
                                           label: "\(item.isVideo ? "Video" : "Photo"): \(item.filename ?? "Untitled")" +
                                               (item.isFavorite ? ", favorite" : ""),
                                           onSelect: onSelect ?? {},
                                           onCommand: onCommand ?? { _ in },
                                           onActivate: onActivate)
            }
            if failed, allowNetwork, descriptor?.isReady(size) == true, repository != nil {
                ThumbnailRetryButton {
                    failures.clear(renditionIdentity)
                    retryID = UUID()
                }
                    .frame(width: 28, height: 28)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .task(id: taskIdentity) { await load() }
    }

    private static let maxPixel = 520

    /// Memory key for one decoded rendition. The repository identity keeps a later
    /// account's run from inheriting an earlier run's validation state.
    private func decodedKey(_ rendition: ThumbnailSize, repository: CachedPhotosRepository) -> String {
        "\(ObjectIdentifier(repository).hashValue):\(familyIdentity):\(rendition.rawValue):\(Self.maxPixel)"
    }

    private func load() async {
        if displayedRendition?.hasPrefix(familyIdentity) != true {
            image = nil
        }
        displayedRendition = renditionIdentity
        guard let descriptor, let repository else {
            failed = true; return
        }
        let priorFailure = failures.contains(renditionIdentity)
        failed = priorFailure
        let network = allowNetwork && !priorFailure
        // A decoded exact rendition already validated this run needs no disk or network work.
        if let hit = DecodedImages.shared.rendition(decodedKey(size, repository: repository)) {
            image = hit.image
            if hit.verified || !network { return }
        }
        for await event in await repository.thumbnailWithFallback(descriptor, size: size,
                                                                  allowNetwork: network, collection: collection) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let value, let verified):
                if let decoded = await DecodedImages.shared.renditionImage(
                    key: decodedKey(value.size, repository: repository), data: value.data,
                    verified: verified, maxPixel: Self.maxPixel) {
                    guard !Task.isCancelled, displayedRendition == renditionIdentity else { return }
                    if image !== decoded { image = decoded }
                } else if !Task.isCancelled { failed = true }
            case .failure:
                failed = true
                failures.record(renditionIdentity)
            }
        }
    }

}

/// Retains recent failed requests when virtualized rows are recycled. Bounded
/// storage avoids retaining an entry for every item in a large offline library.
@MainActor
final class ThumbnailFailureRegistry {
    private var entries: Set<String> = []
    private var order: [String] = []
    private let limit = 1_024

    func contains(_ key: String) -> Bool { entries.contains(key) }
    func record(_ key: String) {
        guard entries.insert(key).inserted else { return }
        order.append(key)
        if order.count > limit { entries.remove(order.removeFirst()) }
    }
    func clear(_ key: String) {
        guard entries.remove(key) != nil else { return }
        order.removeAll { $0 == key }
    }
}

/// The row hosting view passes ordinary pointer events through to the document's
/// selection handler, but allows this explicit control to receive its own clicks.
struct ThumbnailRetryButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ThumbnailRetryControl {
        let button = ThumbnailRetryControl()
        button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        button.bezelStyle = .roundRect
        button.isBordered = true
        button.toolTip = "Retry thumbnail"
        button.setAccessibilityLabel("Retry thumbnail")
        button.target = context.coordinator
        button.action = #selector(Coordinator.retry)
        return button
    }

    func updateNSView(_ button: ThumbnailRetryControl, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func retry() { action?() }
    }
}

final class ThumbnailRetryControl: NSButton {}

/// Badges belong to the stable grid slot rather than the thumbnail's animated, clipped frame.
struct ThumbnailBadgeOverlay: View {
    let item: PhotoItem

    var body: some View {
        ZStack {
            if let duration = item.additional?.videoMeta?.duration,
               item.type == "video", duration.isFinite, duration > 0 {
                Text(Self.formattedDuration(duration))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 3))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .accessibilityLabel("Video duration \(Self.formattedDuration(duration))")
            }
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .accessibilityLabel("Favorite")
            }
        }
        .allowsHitTesting(false)
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// The AppKit surface supplies a source rectangle in window-content coordinates. A SwiftUI
/// global frame is not reliable here because every virtualized row owns a detached hosting view.
struct ThumbnailActivationSurface: NSViewRepresentable {
    let itemID: Int64
    let image: NSImage?
    let isSelected: Bool
    let label: String
    let onSelect: () -> Void
    let onCommand: (BrowserSelectionCommand) -> Void
    let onActivate: (PhotoViewerSourceAnchor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ActivationView {
        let view = ActivationView()
        context.coordinator.anchor.attach(view)
        view.anchor = context.coordinator.anchor
        return view
    }

    func updateNSView(_ view: ActivationView, context: Context) {
        context.coordinator.anchor.update(itemID: itemID, image: image)
        view.anchor = context.coordinator.anchor
        view.onActivate = onActivate
        view.onSelect = onSelect
        view.onCommand = onCommand
        view.accessibilityTitle = label
        view.selected = isSelected
    }

    @MainActor
    final class Coordinator {
        let anchor = PhotoViewerSourceAnchor()
    }

    final class ActivationView: NSView, PhotoViewerSourceActivating, PhotoViewerSourceProviding {
        weak var anchor: PhotoViewerSourceAnchor?
        var onActivate: ((PhotoViewerSourceAnchor) -> Void)?
        var onSelect: (() -> Void)?
        var onCommand: ((BrowserSelectionCommand) -> Void)?
        var accessibilityTitle = "Open photo"
        var selected = false
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                DispatchQueue.main.async { [weak self] in
                    (self?.enclosingScrollView as? TimelineScrollView)?.publishFocusState()
                }
            }
            return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                DispatchQueue.main.async { [weak self] in
                    (self?.enclosingScrollView as? TimelineScrollView)?.publishFocusState()
                }
            }
            return result
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
        override func isAccessibilityElement() -> Bool { true }
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
                self.anchor?.activate()
                return true
            }]
        }
        func activateViewerSource(_ anchor: PhotoViewerSourceAnchor) {
            onActivate?(anchor)
        }
        func viewerSourceAnchor(for itemID: Int64) -> PhotoViewerSourceAnchor? {
            anchor?.itemID == itemID ? anchor : nil
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

private final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Decoded images shared by browser cells, the viewer, Map and album cards.
@MainActor
final class DecodedImages {
    static let shared = DecodedImages()

    final class Rendition {
        let image: NSImage
        let digest: String
        var verified: Bool
        init(image: NSImage, digest: String, verified: Bool) {
            self.image = image; self.digest = digest; self.verified = verified
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let renditions = NSCache<NSString, Rendition>()
    private let gate = DecodeGate()
    private init() {
        cache.totalCostLimit = 128 * 1_000_000
        renditions.totalCostLimit = 384 * 1_000_000
    }

    func clear() {
        cache.removeAllObjects()
        renditions.removeAllObjects()
    }

    /// A decoded rendition by its caller-defined identity, without touching its bytes.
    func rendition(_ key: String) -> Rendition? { renditions.object(forKey: key as NSString) }

    /// Decodes bytes for an identified rendition. Identical bytes reuse the existing
    /// decoded image and only update its validation state.
    func renditionImage(key: String, data: Data, verified: Bool, maxPixel: Int) async -> NSImage? {
        let digest = await Self.digest(data)
        let cacheKey = key as NSString
        if let existing = renditions.object(forKey: cacheKey), existing.digest == digest {
            existing.verified = existing.verified || verified
            return existing.image
        }
        guard let box = await decode(data, maxPixel: maxPixel) else { return nil }
        let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
        renditions.setObject(Rendition(image: image, digest: digest, verified: verified), forKey: cacheKey,
                             cost: box.image.bytesPerRow * box.image.height)
        return image
    }

    func image(from data: Data, maxPixel: Int) async -> NSImage? {
        let key = "\(await Self.digest(data)):\(maxPixel)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let box = await decode(data, maxPixel: maxPixel) else { return nil }
        let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
        cache.setObject(image, forKey: key, cost: box.image.bytesPerRow * box.image.height)
        return image
    }

    private static func digest(_ data: Data) async -> String {
        await Task.detached(priority: .userInitiated) {
            let hex = Array("0123456789abcdef".utf8)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(64)
            for byte in SHA256.hash(data: data) {
                bytes.append(hex[Int(byte >> 4)]); bytes.append(hex[Int(byte & 0x0f)])
            }
            return String(decoding: bytes, as: UTF8.self)
        }.value
    }

    private func decode(_ data: Data, maxPixel: Int) async -> CGImageBox? {
        do { try await gate.acquire() } catch { return nil }
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        let box = await Task.detached(priority: .userInitiated) { Self.decodeImage(data, maxPixel: maxPixel) }.value
        guard !Task.isCancelled else { return nil }
        return box
    }

    /// Images that already fit and need no orientation transform are decoded directly,
    /// which is about twice as fast as ImageIO's thumbnail path for cached thumbnails.
    nonisolated private static func decodeImage(_ data: Data, maxPixel: Int) -> CGImageBox? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(width, height) <= maxPixel,
           ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1,
           let image = CGImageSourceCreateImageAtIndex(source, 0, [
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            return CGImageBox(image)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary) else { return nil }
        return CGImageBox(image)
    }
}

/// Bounds concurrent decodes. The newest request runs first, so cells that just
/// scrolled into view are not stuck behind work for cells that already left it.
private actor DecodeGate {
    private let limit = 4
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if Task.isCancelled { release(); throw CancellationError() }
    }

    func release() {
        if !waiting.isEmpty {
            let (_, continuation) = waiting.removeLast()
            continuation.resume()
        } else { active = max(0, active - 1) }
    }

    private func cancel(_ id: UUID) {
        if let position = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: position).1.resume(throwing: CancellationError())
        }
    }
}
