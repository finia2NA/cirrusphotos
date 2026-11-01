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

    var body: some View {
        Group {
            if !model.albums.isEmpty || model.albumsVerified {
                GeometryReader { geometry in
                    let count = Self.columnCount(width: geometry.size.width)
                    let columns = Array(repeating: GridItem(.flexible(maximum: 240), spacing: 20, alignment: .leading), count: count)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            HStack {
                                Spacer()
                                Picker("Sort Albums", selection: Binding(get: { presentation.sort }, set: { presentation.setSort($0) })) {
                                    ForEach(AlbumOverviewSort.allCases, id: \.self) { value in
                                        Text(value.title).tag(value)
                                    }
                                }.pickerStyle(.menu).fixedSize()
                            }
                            section("Shared Albums", shared: true, columns: columns, count: count)
                            section("Albums", shared: false, columns: columns, count: count)
                        }
                        .padding(24)
                        .padding(.top, contentTopInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let error = model.albumListError {
                ContentUnavailableView {
                    Label("Albums unavailable", systemImage: "rectangle.stack.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.reload() } }.disabled(model.isLoading)
                }
            } else {
                ProgressView("Loading albums…")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    static func columnCount(width: CGFloat) -> Int {
        max(1, Int((max(0, width - 48) + 20) / 200))
    }

    private func section(_ title: String, shared: Bool, columns: [GridItem], count: Int) -> some View {
        let albums = presentation.section(model.albums, shared: shared)
        let expanded = shared ? presentation.sharedExpanded : presentation.albumsExpanded
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if albums.count > count {
                    Button(expanded ? "Show Less" : "Show All") {
                        presentation.setExpanded(!expanded, shared: shared)
                    }.buttonStyle(.link)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(expanded ? albums : Array(albums.prefix(count))) { album in
                    AlbumCardView(album: album, repository: model.repository, presentation: presentation) {
                        onOpenAlbum(album)
                    }
                }
            }
        }
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
        .modifier(AlbumDragGesture(albumID: album.id, name: album.name, repository: repository, preview: dragPreview))
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
