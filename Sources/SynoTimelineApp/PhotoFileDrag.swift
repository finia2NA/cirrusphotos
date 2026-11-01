import AppKit
import Foundation
import PhotoCache
import SynologyAPI
import UniformTypeIdentifiers

struct PhotoDragPayload: Sendable {
    let repository: CachedPhotosRepository
    let item: PhotoItem?
    let selection: BrowserCommandSnapshot?
    let snapshot: TimelineSnapshot?
    let count: Int
    let filename: String
    let capturedSelection: PhotoSelectionSnapshot?

    init(repository: CachedPhotosRepository, item: PhotoItem?, selection: BrowserCommandSnapshot?,
         snapshot: TimelineSnapshot?, count: Int, filename: String) {
        self.repository = repository
        self.item = item
        self.selection = selection
        self.snapshot = snapshot
        self.count = count
        self.filename = filename
        self.capturedSelection = selection?.captureSelection(timeline: snapshot)
    }
}

private final class PromiseCompletion: @unchecked Sendable {
    let callback: (Error?) -> Void
    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
}

@MainActor
final class PhotoPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let payload: PhotoDragPayload
    init(payload: PhotoDragPayload) { self.payload = payload }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        payload.filename
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        let completion = PromiseCompletion(completionHandler)
        Task { @MainActor in
            PhotoDownloadManager.shared.fulfillPromise(payload, destination: url) { error in
                completion.callback(error)
            }
        }
    }
}

@MainActor
final class PhotoFileDragSource: NSObject, NSDraggingSource {
    private static var active: [UUID: PhotoFileDragSource] = [:]
    private let id = UUID()

    static func begin(payload: PhotoDragPayload, previews: [NSImage], cropsToSquare: Bool,
                      from view: NSView, event: NSEvent) -> Bool {
        guard payload.count > 0, !payload.filename.isEmpty else { return false }
        let source = PhotoFileDragSource()
        let fileType: UTType = payload.count > 1 ? .zip :
            (UTType(filenameExtension: URL(fileURLWithPath: payload.filename).pathExtension) ?? .data)
        let delegate = PhotoPromiseDelegate(payload: payload)
        let provider = NSFilePromiseProvider(fileType: fileType.identifier, delegate: delegate)
        provider.userInfo = delegate
        let item = NSDraggingItem(pasteboardWriter: provider)
        let image = dragPreview(images: Array(previews.prefix(20)), count: payload.count,
                                cropsToSquare: cropsToSquare)
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 30, y: point.y - 30,
                                     width: image.size.width, height: image.size.height), contents: image)
        active[source.id] = source
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.active[id] = nil
    }

    static func sourceRect(for size: NSSize, cropsToSquare: Bool) -> NSRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        guard cropsToSquare else { return NSRect(origin: .zero, size: size) }
        let side = min(size.width, size.height)
        return NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                      width: side, height: side)
    }

    static func thumbnailSize(for size: NSSize, cropsToSquare: Bool) -> NSSize {
        let source = sourceRect(for: size, cropsToSquare: cropsToSquare)
        guard source.width > 0, source.height > 0 else { return NSSize(width: 60, height: 60) }
        let scale = 60 / max(source.width, source.height)
        return NSSize(width: source.width * scale, height: source.height * scale)
    }

    static func dragPreview(images: [NSImage], count: Int, cropsToSquare: Bool) -> NSImage {
        let fallback = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let chosen = images.isEmpty ? [fallback].compactMap { $0 } : Array(images.prefix(20))
        let sizes = chosen.map { thumbnailSize(for: $0.size, cropsToSquare: cropsToSquare) }
        let width = sizes.map(\.width).max() ?? 60
        let height = sizes.map(\.height).max() ?? 60
        let badgeText = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]
        let textSize = badgeText.size(withAttributes: attributes)
        let badgeWidth = count > 1 ? min(96, max(27, textSize.width + 12)) : 0
        let size = NSSize(width: max(width + 26, badgeWidth + 4), height: height + 26 + (count > 1 ? 13 : 0))
        let image = NSImage(size: size)
        image.lockFocus()
        for (index, photo) in chosen.reversed().enumerated() {
            let shift = CGFloat(min(index, 8)) * 2
            let inner = thumbnailSize(for: photo.size, cropsToSquare: cropsToSquare)
            let rect = NSRect(x: 6 + shift, y: 6 + shift, width: inner.width + 4, height: inner.height + 4)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            photo.draw(in: rect.insetBy(dx: 2, dy: 2),
                       from: sourceRect(for: photo.size, cropsToSquare: cropsToSquare),
                       operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
        }
        if count > 1 {
            let badge = NSRect(x: size.width - badgeWidth - 2, y: size.height - 23,
                               width: badgeWidth, height: 21)
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 10.5, yRadius: 10.5).fill()
            badgeText.draw(at: NSPoint(x: badge.midX - textSize.width / 2,
                                       y: badge.midY - textSize.height / 2), withAttributes: attributes)
        }
        image.unlockFocus()
        return image
    }
}
