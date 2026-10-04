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
    var onActivate: ((PhotoViewerSourceAnchor) -> Void)? = nil
    @State private var image: NSImage?
    @State private var displayedRendition: String?
    @State private var failed = false

    private var descriptor: ThumbnailInfo? { item.additional?.thumbnail }
    private var familyIdentity: String {
        "\(item.id):\(descriptor?.unitID ?? 0):\(descriptor?.cacheKey ?? "missing")"
    }
    private var renditionIdentity: String {
        "\(familyIdentity):\(size.rawValue)"
    }
    private var taskIdentity: String { "\(renditionIdentity):\(allowNetwork)" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
            if let image, displayedRendition?.hasPrefix(familyIdentity) == true {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed, displayedRendition == renditionIdentity {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
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
            if let onActivate {
                ThumbnailActivationSurface(itemID: item.id, image: image,
                                           label: (item.filename.map { "Open \($0)" } ?? "Open photo") +
                                               (item.isFavorite ? ", favorite" : ""),
                                           onActivate: onActivate)
            }
        }
        .clipped()
        .task(id: taskIdentity) { await load() }
    }

    private func load() async {
        if displayedRendition?.hasPrefix(familyIdentity) != true {
            image = nil
        }
        displayedRendition = renditionIdentity
        guard let descriptor, let repository else {
            failed = true; return
        }
        failed = false
        for await event in await repository.thumbnailWithFallback(descriptor, size: size,
                                                                  allowNetwork: allowNetwork) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let value, _):
                if let decoded = await DecodedImages.shared.image(from: value.data, maxPixel: 520) {
                    guard !Task.isCancelled, displayedRendition == renditionIdentity else { return }
                    image = decoded
                } else if !Task.isCancelled { failed = true }
            case .failure:
                if image == nil { failed = true }
            }
        }
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
private struct ThumbnailActivationSurface: NSViewRepresentable {
    let itemID: Int64
    let image: NSImage?
    let label: String
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
        view.accessibilityTitle = label
    }

    @MainActor
    final class Coordinator {
        let anchor = PhotoViewerSourceAnchor()
    }

    final class ActivationView: NSView, PhotoViewerSourceActivating {
        weak var anchor: PhotoViewerSourceAnchor?
        var onActivate: ((PhotoViewerSourceAnchor) -> Void)?
        var accessibilityTitle = "Open photo"
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 1 else { return }
            window?.makeFirstResponder(self)
            anchor?.activate()
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 49 { anchor?.activate() }
            else if event.keyCode == 125 || event.keyCode == 126 { enclosingScrollView?.keyDown(with: event) }
            else { super.keyDown(with: event) }
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { accessibilityTitle }
        override func accessibilityPerformPress() -> Bool {
            anchor?.activate()
            return true
        }
        func activateViewerSource(_ anchor: PhotoViewerSourceAnchor) {
            onActivate?(anchor)
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

@MainActor
final class DecodedImages {
    static let shared = DecodedImages()
    private let cache = NSCache<NSString, NSImage>()
    private let gate = DecodeGate()
    private init() { cache.totalCostLimit = 100 * 1_000_000 }

    func clear() { cache.removeAllObjects() }

    func image(from data: Data, maxPixel: Int) async -> NSImage? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "\(digest):\(maxPixel)" as NSString
        if let image = cache.object(forKey: key) { return image }
        do { try await gate.acquire() } catch { return nil }
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        let box = await Task.detached(priority: .utility) { () -> CGImageBox? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                  ] as CFDictionary) else { return nil }
            return CGImageBox(cg)
        }.value
        guard let box, !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
        cache.setObject(image, forKey: key, cost: box.image.bytesPerRow * box.image.height)
        return image
    }
}

private actor DecodeGate {
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
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
            let (_, continuation) = waiting.removeFirst()
            continuation.resume()
        } else { active = max(0, active - 1) }
    }

    private func cancel(_ id: UUID) {
        if let position = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: position).1.resume(throwing: CancellationError())
        }
    }
}
