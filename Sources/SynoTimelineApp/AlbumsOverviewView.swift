import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// Full-screen overview of every Personal Space album.
struct AlbumsOverviewView: View {
    let onOpenAlbum: (AlbumSummary) -> Void
    @ObservedObject var presentation: AlbumPresentationStore
    var contentTopInset: CGFloat = 0
    @EnvironmentObject private var model: LibraryModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20)]

    var body: some View {
        Group {
            if !model.albums.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(model.albums) { album in
                            AlbumCardView(album: album, repository: model.repository, presentation: presentation) {
                                onOpenAlbum(album)
                            }
                        }
                    }
                    .padding(24)
                    .padding(.top, contentTopInset)
                }
            } else if let error = model.albumListError {
                ContentUnavailableView {
                    Label("Albums unavailable", systemImage: "rectangle.stack.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.reload() } }.disabled(model.isLoading)
                }
            } else if model.albumsVerified {
                ContentUnavailableView("No albums", systemImage: "rectangle.stack",
                                       description: Text("No albums in Personal Space."))
            } else {
                ProgressView("Loading albums…")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct AlbumCardView: View {
    @EnvironmentObject private var model: LibraryModel
    let album: AlbumSummary
    let repository: CachedPhotosRepository?
    @ObservedObject var presentation: AlbumPresentationStore
    let onOpen: () -> Void
    @State private var dragPreview: NSImage?

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                AlbumCoverView(thumbnail: album.thumbnail, repository: repository, onImage: { dragPreview = $0 })
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(itemCountText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .background(AlbumDragGesture(albumID: album.id, name: album.name, repository: repository, preview: dragPreview))
        .background(AlbumMembershipTarget(albumID: album.id, model: model))
        .contextMenu {
            Button("Add to Sidebar") { presentation.add(album.id) }
            Divider()
            AlbumDownloadCommands(albumID: album.id, repository: repository)
        }
        .accessibilityLabel("\(album.name), \(itemCountText)")
        .help(album.name)
    }

    private var itemCountText: String {
        album.itemCount == 1 ? "1 item" : "\(album.itemCount) items"
    }
}

/// Shared by album surfaces without opening the album or changing selection.
struct AlbumDownloadCommands: View {
    let albumID: Int64
    let repository: CachedPhotosRepository?

    var body: some View {
        ForEach(Array(photoDownloadActions.enumerated()), id: \.offset) { _, action in
            Button(action.0) {
                guard let repository else { return }
                PhotoDownloadManager.shared.start(repository: repository, source: .album(albumID),
                                                  kind: action.1, choose: action.2)
            }.disabled(repository == nil)
        }
    }
}

/// Loads an album's cover through the shared thumbnail cache. The decoded image is held
/// only by the card and released when it leaves the view.
struct AlbumCoverView: View {
    let thumbnail: ThumbnailInfo?
    let repository: CachedPhotosRepository?
    var cornerRadius: CGFloat = 8
    var placeholderFont: Font = .largeTitle
    var maxPixel: Int = 512
    var onImage: (NSImage?) -> Void = { _ in }
    @State private var image: NSImage?

    private var identity: String {
        guard let thumbnail else { return "missing" }
        return "\(repository?.namespace ?? "unavailable"):\(thumbnail.unitID):\(thumbnail.cacheKey):\(maxPixel)"
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: "rectangle.stack")
                            .font(placeholderFont)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: identity) { await load() }
    }

    private func load() async {
        image = nil
        onImage(nil)
        guard let thumbnail, let repository else { return }
        for await event in await repository.thumbnailWithFallback(
            thumbnail, size: .m, allowNetwork: true, priority: .visible
        ) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let value, _):
                if let decoded = await DecodedImages.shared.image(from: value.data, maxPixel: maxPixel) {
                    guard !Task.isCancelled else { return }
                    image = decoded
                    onImage(decoded)
                }
            case .failure:
                break
            }
        }
    }
}
