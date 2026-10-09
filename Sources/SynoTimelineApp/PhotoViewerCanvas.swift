import AppKit
import SwiftUI

@MainActor
final class PhotoViewerCanvasController {
    weak var view: PhotoViewerCanvasView?
    private var pendingGeneration: UInt64?
    private var pendingFocus = false

    func attach(_ view: PhotoViewerCanvasView) {
        self.view = view
        if let pendingGeneration {
            view.resetForSelection(pendingGeneration)
            self.pendingGeneration = nil
        }
        if pendingFocus {
            pendingFocus = false
            view.requestKeyboardFocus()
        }
    }

    func resetForSelection(_ generation: UInt64) {
        if let view { view.resetForSelection(generation) }
        else { pendingGeneration = generation }
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
    let zoom: Double
    let toolbarInset: CGFloat
    let openingSourceRect: CGRect?
    let reduceMotion: Bool
    let interactiveDismissalEnabled: Bool
    let interpolation: NSImageInterpolation
    let controller: PhotoViewerCanvasController
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    let onInteractiveDismiss: () -> Void
    let onZoomChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> PhotoViewerCanvasView {
        let view = PhotoViewerCanvasView()
        view.onZoomChanged = onZoomChanged
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        view.onInteractiveDismiss = onInteractiveDismiss
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: PhotoViewerCanvasView, context: Context) {
        view.onZoomChanged = onZoomChanged
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        view.onInteractiveDismiss = onInteractiveDismiss
        view.toolbarInset = toolbarInset
        view.reduceMotion = reduceMotion
        view.interactiveDismissalEnabled = interactiveDismissalEnabled
        view.interpolation = interpolation
        view.configureOpeningSource(openingSourceRect)
        view.setImage(image, selectionGeneration: selectionGeneration,
                      openingSourceRectInWindow: openingSourceRect)
        view.setZoom(CGFloat(zoom))
    }
}
