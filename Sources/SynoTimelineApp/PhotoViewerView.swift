import PhotoCache
import SwiftUI

struct PhotoViewerView: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    let toolbarInset: CGFloat
    let reduceMotion: Bool
    let pixelInterpolation: PixelInterpolationPreference
    let onSelectionChanged: (PhotoViewerState) -> Void
    let onClose: () -> Void
    let onInteractiveDismiss: () -> Void

    var body: some View {
        ZStack {
            PhotoViewerCanvas(image: viewer.image,
                              selectionGeneration: viewer.state?.selection.generation ?? 1,
                              zoom: viewer.zoom,
                              toolbarInset: toolbarInset,
                              openingSourceRect: viewer.source.rectInWindowContent(),
                              reduceMotion: reduceMotion,
                              interactiveDismissalEnabled: !reduceMotion
                                && viewer.state?.item?.isVideo != true,
                              interactivePagingEnabled: !reduceMotion
                                && viewer.state?.item?.isVideo != true,
                              previousImage: viewer.previousNeighborImage,
                              nextImage: viewer.nextNeighborImage,
                              previousItemID: viewer.previousNeighborItemID,
                              nextItemID: viewer.nextNeighborItemID,
                              interpolation: pixelInterpolation.imageInterpolation(
                                isFullResolution: viewer.isDisplayingFullResolution
                              ),
                              pagingInterpolation: pixelInterpolation.imageInterpolation(
                                isFullResolution: false
                              ),
                              controller: viewer.canvasController,
                              onPrevious: viewer.navigatePrevious,
                              onNext: viewer.navigateNext,
                              onClose: onClose,
                              onInteractiveDismiss: onInteractiveDismiss) { viewer.zoom = Double($0) }
                .accessibilityLabel(viewer.filename)

            if let state = viewer.state, let resource = state.videoResource {
                VideoPlayerView(repository: viewer.repository, resource: resource,
                                selectionGeneration: state.selection.generation,
                                allowNetwork: state.allowNetwork && state.metadataVerified,
                                poster: viewer.image, toolbarInset: toolbarInset,
                                onPrevious: viewer.navigatePrevious,
                                onNext: viewer.navigateNext, onClose: onClose)
                    .accessibilityLabel(viewer.filename)
            }

            if viewer.image == nil, viewer.state?.item?.isVideo != true,
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

            if viewer.state?.item?.isVideo == true, viewer.state?.videoResource == nil {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                    Text("This video has no playable resource.")
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
