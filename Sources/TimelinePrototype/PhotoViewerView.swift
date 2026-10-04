import PhotoCache
import SwiftUI

struct PhotoViewerView: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    let toolbarInset: CGFloat
    let reduceMotion: Bool
    let onSelectionChanged: (PhotoViewerState) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            PhotoViewerCanvas(image: viewer.image,
                              selectionGeneration: viewer.state?.selection.generation ?? 1,
                              zoom: viewer.zoom,
                              toolbarInset: toolbarInset,
                              openingSourceRect: viewer.source.rectInWindowContent(),
                              reduceMotion: reduceMotion,
                              controller: viewer.canvasController,
                              onPrevious: viewer.navigatePrevious,
                              onNext: viewer.navigateNext,
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
        .onAppear {
            if let state = viewer.state { onSelectionChanged(state) }
        }
        .onChange(of: viewer.state?.selection) { _, _ in
            if let state = viewer.state { onSelectionChanged(state) }
        }
        .onChange(of: viewer.canToggleFavorite) { _, _ in
            if let state = viewer.state { onSelectionChanged(state) }
        }
    }
}
