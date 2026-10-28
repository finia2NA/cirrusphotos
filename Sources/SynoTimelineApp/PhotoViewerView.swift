import PhotoCache
import SwiftUI

struct PhotoViewerView: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    let toolbarInset: CGFloat
    let reduceMotion: Bool
    let pixelInterpolation: PixelInterpolationPreference
    let videoMuted: Bool
    let showsFilmstrip: Bool
    let showsHistogram: Bool
    let showsHighlightPeaking: Bool
    @State private var inspectionOverlay: CGImage?
    @State private var filmstripHeight: CGFloat = 100
    @State private var dragStartHeight: CGFloat?
    let onVideoMuteChanged: (Bool) -> Void
    let onSelectionChanged: (PhotoViewerState) -> Void
    let onClose: () -> Void
    let onInteractiveDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
        ZStack {
            PhotoViewerCanvas(image: viewer.image,
                              selectionGeneration: viewer.state?.selection.generation ?? 1,
                              inspectionOverlay: inspectionOverlay,
                              zoom: viewer.zoom,
                              toolbarInset: toolbarInset,
                              openingSourceRect: viewer.source.rectInWindowContent(),
                              reduceMotion: reduceMotion,
                              interactiveDismissalEnabled: !reduceMotion,
                              interactivePagingEnabled: !reduceMotion,
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
                              videoConfiguration: viewer.state.flatMap { state in
                                state.videoResource.map { resource in
                                    VideoConfiguration(repository: viewer.repository, resource: resource,
                                                       generation: state.selection.generation,
                                                       allowNetwork: state.allowNetwork && state.metadataVerified,
                                                       poster: viewer.image, isMuted: videoMuted,
                                                       onMuteChanged: onVideoMuteChanged)
                                }
                              },
                              livePhotoConfiguration: viewer.state.flatMap { state in
                                guard let item = state.item, item.mediaKind == .livePhoto,
                                      state.metadataVerified, state.allowNetwork,
                                      viewer.isDisplayingFullResolution,
                                      item.additional?.orientation == item.additional?.orientationOriginal else { return nil }
                                return LivePhotoConfiguration(repository: viewer.repository, itemID: item.id,
                                                              generation: state.selection.generation, isMuted: videoMuted)
                              },
                              controller: viewer.canvasController,
                              onPrevious: viewer.navigatePrevious,
                              onNext: viewer.navigateNext,
                              onClose: onClose,
                              onInteractiveDismiss: onInteractiveDismiss) { viewer.zoom = Double($0) }
                .accessibilityLabel(viewer.filename)

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
        .overlay(alignment: .bottomTrailing) {
            if showsHistogram, viewer.state?.item?.isVideo != true, let image = viewer.image {
                ViewerHistogram(image: image)
                    .padding(12)
            }
        }
        if showsFilmstrip {
            Rectangle().fill(.secondary.opacity(0.4)).frame(height: 6)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = filmstripHeight }
                    filmstripHeight = min(220, max(56, (dragStartHeight ?? filmstripHeight) - value.translation.height))
                }.onEnded { _ in dragStartHeight = nil })
                .accessibilityLabel("Filmstrip height")
            ViewerFilmstrip(viewer: viewer, height: filmstripHeight)
                .frame(height: filmstripHeight)
        }
        }
        .task(id: InspectionRequest(image: viewer.image.map(ObjectIdentifier.init),
                                    enabled: showsHighlightPeaking && viewer.state?.item?.isVideo != true)) {
            inspectionOverlay = nil
            guard showsHighlightPeaking, viewer.state?.item?.isVideo != true,
                  let image = viewer.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let result = await ViewerInspectionEngine.shared.overlay(for: image, module: .highlightPeaking)
            guard !Task.isCancelled else { return }
            inspectionOverlay = result
        }
        .onAppear {
            viewer.setFilmstripEnabled(showsFilmstrip)
            if let state = viewer.state { onSelectionChanged(state) }
        }
        .onChange(of: showsFilmstrip) { _, enabled in viewer.setFilmstripEnabled(enabled) }
        .onChange(of: viewer.state?.selection) { _, _ in
            if let state = viewer.state { onSelectionChanged(state) }
        }
        .onChange(of: viewer.canToggleFavorite) { _, _ in
            if let state = viewer.state { onSelectionChanged(state) }
        }
    }
}

private struct InspectionRequest: Equatable {
    let image: ObjectIdentifier?
    let enabled: Bool
}
