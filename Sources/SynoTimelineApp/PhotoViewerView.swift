import AppKit
import PhotoCache
import SwiftUI
import TimelineCore

struct PhotoViewerView: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject var viewer: PhotoViewerPresentation
    var pinnedAlbumIDs: [Int64] = []
    let toolbarInset: CGFloat
    let reduceMotion: Bool
    let pixelInterpolation: PixelInterpolationPreference
    let videoMuted: Bool
    let showsFilmstrip: Bool
    let cropsThumbnailsToSquare: Bool
    let showsHistogram: Bool
    let showsHighlightPeaking: Bool
    @AppStorage("viewerHighlightThreshold") private var highlightThreshold = 100.0
    @State private var inspectionOverlay: CGImage?
    @State private var inspectionGeneration: UInt64?
    @State private var histogramOpacity: CGFloat = 1
    @State private var filmstripHeight: CGFloat = 100
    let onVideoMuteChanged: (Bool) -> Void
    let onSelectionChanged: (PhotoViewerState) -> Void
    let onClose: () -> Void
    let onInteractiveDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
        ZStack {
            PhotoViewerCanvas(image: viewer.image,
                              selectionGeneration: viewer.state?.selection.generation ?? 1,
                              inspectionOverlay: showsHighlightPeaking && viewer.state?.item?.isVideo != true &&
                                viewer.state?.selection.generation == inspectionGeneration ? inspectionOverlay : nil,
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
                              previousIsLivePhoto: viewer.previousNeighborIsLivePhoto,
                              nextIsLivePhoto: viewer.nextNeighborIsLivePhoto,
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
                                guard !viewer.isIncoming, state.contentScope.space != nil, let item = state.item, item.mediaKind == .livePhoto,
                                      state.metadataVerified, state.allowNetwork,
                                      viewer.isDisplayingFullResolution,
                                      item.additional?.orientation == item.additional?.orientationOriginal else { return nil }
                                return LivePhotoConfiguration(repository: viewer.repository, itemID: item.id, space: state.contentScope.space ?? viewer.collection.space,
                                                              generation: state.selection.generation, isMuted: videoMuted)
                              },
                              showsLivePhotoIndicator: !viewer.isIncoming && viewer.state?.contentScope.space != nil && viewer.state?.item?.mediaKind == .livePhoto,
                              controller: viewer.canvasController,
                              onPrevious: viewer.navigatePrevious,
                              onNext: viewer.navigateNext,
                              onClose: onClose,
                              onInteractiveDismiss: onInteractiveDismiss,
                              onBackdropOpacityChanged: { opacity, duration in
                                DispatchQueue.main.async {
                                    if duration > 0 { withAnimation(.easeInOut(duration: duration)) { histogramOpacity = opacity } }
                                    else { histogramOpacity = opacity }
                                }
                              }, downloadMenu: {
                                guard let state = viewer.state, state.metadataVerified, state.allowNetwork,
                                      let item = state.item else { return nil }
                                let repository = viewer.repository
                                let menu = item.hasDisplayableStillImage && library.canDownload(in: viewer.collection) ? photoDownloadMenu { kind, choose in
                                    library.downloadViewerItem(item, repository: repository, collection: viewer.collection, kind: kind, choose: choose)
                                } : NSMenu()
                                if library.allowsPersonalActions(in: viewer.collection) && item.hasDisplayableStillImage {
                                    addEditMenu(to: menu, filename: item.filename) { application in
                                        library.editViewerItem(item, repository: repository, collection: viewer.collection, application: application)
                                    }
                                }
                                if library.allowsPersonalActions(in: viewer.collection), let timeline = library.snapshot(for: viewer.collection),
                                   LibraryIndex(snapshot: timeline).fingerprint == viewer.index.fingerprint,
                                   let authority = library.selectionAuthority(for: viewer.collection) {
                                    let ordinal = state.desiredLocation.ordinal
                                    let captured = BrowserCommandSnapshot(owner: UUID(), active: true, canOpen: false,
                                        canToggleFavorite: false, collection: viewer.collection,
                                        indexFingerprint: viewer.index.fingerprint, selectionGeneration: nil,
                                        selectedOrdinals: IndexSet(integer: ordinal), knownItemIDsByOrdinal: [ordinal: item.id],
                                        timeline: timeline, authority: authority,
                                        sourceAlbumID: library.sourceAlbumID(for: viewer.collection))
                                    library.addAlbumMembershipMenu(to: menu, captured: captured, pinnedIDs: pinnedAlbumIDs)
                                }
                                return menu.items.isEmpty ? nil : menu
                              }, startFileDrag: { view, event in
                                guard !viewer.isIncoming, let state = viewer.state, state.metadataVerified, state.allowNetwork,
                                      let item = state.item, item.hasDisplayableStillImage,
                                      let filename = item.filename, !filename.isEmpty else { return false }
                                let name = URL(fileURLWithPath: filename).lastPathComponent
                                let payload = PhotoDragPayload(repository: viewer.repository, source: .item(item, collection: viewer.collection),
                                                               count: 1, filename: name)
                                let preview = state.thumbnailData.flatMap { NSImage(data: $0) } ?? viewer.source.image ?? viewer.image
                                return PhotoFileDragSource.begin(payload: payload, previews: [preview].compactMap { $0 },
                                                                 cropsToSquare: cropsThumbnailsToSquare,
                                                                 from: view, event: event)
                              }) { viewer.zoom = Double($0) }
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
                    .padding(.top, toolbarInset + 12)
                    .padding([.leading, .trailing, .bottom], 12)
                    .opacity(histogramOpacity)
            }
        }
        .frame(height: max(0, geometry.size.height - (showsFilmstrip ? filmstripHeight + 10 : 0)))
        if showsFilmstrip {
            FilmstripDivider(height: $filmstripHeight)
                .frame(height: 10)
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("Filmstrip height")
                .accessibilityValue("\(Int(filmstripHeight)) points")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: filmstripHeight = min(220, filmstripHeight + 10)
                    case .decrement: filmstripHeight = max(56, filmstripHeight - 10)
                    @unknown default: break
                    }
                }
            ViewerFilmstrip(viewer: viewer, height: filmstripHeight,
                            cropsToSquare: cropsThumbnailsToSquare)
                .frame(height: filmstripHeight)
        }
        }
        }
        .task(id: InspectionRequest(image: viewer.image.map(ObjectIdentifier.init),
                                    generation: viewer.state?.selection.generation,
                                    enabled: showsHighlightPeaking && viewer.state?.item?.isVideo != true,
                                    threshold: highlightThreshold)) {
            guard showsHighlightPeaking, viewer.state?.item?.isVideo != true,
                  let generation = viewer.state?.selection.generation,
                  let source = viewer.image,
                  let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let result = await ViewerInspectionEngine.shared.overlay(for: image, module: .highlightPeaking(threshold: highlightThreshold))
            guard !Task.isCancelled, let result, viewer.state?.selection.generation == generation else { return }
            inspectionGeneration = generation
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
    let generation: UInt64?
    let enabled: Bool
    let threshold: Double
}
