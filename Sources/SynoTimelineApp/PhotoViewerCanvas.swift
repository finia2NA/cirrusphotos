import AppKit
import SwiftUI

@MainActor
final class PhotoViewerCanvasController {
    weak var view: PhotoViewerCanvasView?
    private var pendingGeneration: UInt64?
    private var pendingImage: NSImage?
    private var pendingItemID: Int64?
    private var pendingFocus = false
    private var lastGeneration: UInt64?
    private var lastImage: NSImage?
    private var hasAttachedView = false

    func attach(_ view: PhotoViewerCanvasView) {
        self.view = view
        if let pendingGeneration {
            view.resetForSelection(pendingGeneration, image: pendingImage, itemID: pendingItemID)
            self.pendingGeneration = nil
            self.pendingImage = nil
            self.pendingItemID = nil
        } else if hasAttachedView, let lastGeneration {
            view.installPresentedImage(lastImage, generation: lastGeneration)
        }
        hasAttachedView = true
        if pendingFocus {
            pendingFocus = false
            view.requestKeyboardFocus()
        }
    }

    func resetForSelection(_ generation: UInt64, image: NSImage?, itemID: Int64?) {
        lastGeneration = generation
        lastImage = image
        if let view { view.resetForSelection(generation, image: image, itemID: itemID) }
        else {
            pendingGeneration = generation
            pendingImage = image
            pendingItemID = itemID
        }
    }

    func requestKeyboardFocus() {
        if let view { view.requestKeyboardFocus() }
        else { pendingFocus = true }
    }

    func collapse(to rectInWindow: CGRect?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard let view else { completion(); return }
        view.collapse(to: rectInWindow, reduceMotion: reduceMotion, completion: completion)
    }
}

struct PhotoViewerCanvas: NSViewRepresentable {
    let image: NSImage?
    let selectionGeneration: UInt64
    var inspectionOverlay: CGImage? = nil
    let zoom: Double
    let toolbarInset: CGFloat
    let openingSourceRect: CGRect?
    let reduceMotion: Bool
    let interactiveDismissalEnabled: Bool
    let interactivePagingEnabled: Bool
    let previousImage: NSImage?
    let nextImage: NSImage?
    let previousItemID: Int64?
    let nextItemID: Int64?
    let interpolation: NSImageInterpolation
    let pagingInterpolation: NSImageInterpolation
    let videoConfiguration: VideoConfiguration?
    var livePhotoConfiguration: LivePhotoConfiguration? = nil
    let controller: PhotoViewerCanvasController
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    let onInteractiveDismiss: () -> Void
    let onZoomChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> PhotoViewerCanvasView {
        let view = PhotoViewerCanvasView()
        configure(view)
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: PhotoViewerCanvasView, context: Context) {
        configure(view)
        view.configureOpeningSource(openingSourceRect)
        view.setImage(image, selectionGeneration: selectionGeneration,
                      openingSourceRectInWindow: openingSourceRect)
        view.setInspectionOverlay(inspectionOverlay)
        view.syncNeighbors(generation: selectionGeneration)
        view.setZoom(CGFloat(zoom))
        view.setVideo(videoConfiguration)
        view.setLivePhoto(livePhotoConfiguration)
    }

    private func configure(_ view: PhotoViewerCanvasView) {
        view.onZoomChanged = onZoomChanged
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        view.onInteractiveDismiss = onInteractiveDismiss
        view.toolbarInset = toolbarInset
        view.reduceMotion = reduceMotion
        view.interactiveDismissalEnabled = interactiveDismissalEnabled
        view.interactivePagingEnabled = interactivePagingEnabled
        view.previousImage = previousImage
        view.nextImage = nextImage
        view.previousItemID = previousItemID
        view.nextItemID = nextItemID
        view.interpolation = interpolation
        view.pagingInterpolation = pagingInterpolation
    }
}
