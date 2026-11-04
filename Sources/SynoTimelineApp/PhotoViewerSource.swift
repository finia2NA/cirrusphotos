import AppKit
import PhotoCache

@MainActor
protocol PhotoViewerSourceActivating: AnyObject {
    func activateViewerSource(_ anchor: PhotoViewerSourceAnchor)
}

@MainActor
protocol PhotoViewerSourceProviding: AnyObject {
    func viewerSourceAnchor(for itemID: Int64) -> PhotoViewerSourceAnchor?
}

@MainActor
func findViewerSourceAnchor(for itemID: Int64, in view: NSView) -> PhotoViewerSourceAnchor? {
    if let provider = view as? PhotoViewerSourceProviding,
       let anchor = provider.viewerSourceAnchor(for: itemID) { return anchor }
    for subview in view.subviews {
        if let anchor = findViewerSourceAnchor(for: itemID, in: subview) { return anchor }
    }
    return nil
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

    /// Detaches the anchor from any item, for a recycled cell.
    func clear() {
        itemID = nil
        image = nil
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
