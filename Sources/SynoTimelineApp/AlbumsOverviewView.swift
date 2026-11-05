import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// Full-screen overview of every Personal Space album.
struct AlbumsOverviewView: View {
    let onOpenAlbum: (AlbumSummary) -> Void
    @ObservedObject var presentation: AlbumPresentationStore
    var contentTopInset: CGFloat = 0
    @Environment(LibraryModel.self) private var model
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Group {
            if !model.albums.isEmpty || model.albumsVerified {
                let count = preferences.itemsPerRow
                let columns = CardGrid.columns(count)
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
                        ForEach(AlbumOverviewSection.allCases, id: \.self) { group in
                            section(group, columns: columns, count: count)
                        }
                    }
                    .padding(24)
                    .padding(.top, contentTopInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    private func section(_ group: AlbumOverviewSection, columns: [GridItem], count: Int) -> some View {
        let albums = presentation.section(model.albums, section: group)
        let expanded = presentation.expanded(group)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(group.title).font(.title2.weight(.semibold))
                Spacer()
                if albums.count > count {
                    Button(expanded ? "Show Less" : "Show All") {
                        presentation.setExpanded(!expanded, section: group)
                    }.buttonStyle(.link)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(expanded ? albums : Array(albums.prefix(count))) { album in
                    if let collection = album.collection {
                        AlbumCardView(album: album, collection: collection, repository: model.repository, presentation: presentation) {
                            onOpenAlbum(album)
                        }
                    }
                }
            }
        }
    }

}

private struct AlbumCardView: View {
    @Environment(LibraryModel.self) private var model
    let album: AlbumSummary
    let collection: PhotoCollectionDescriptor
    let repository: CachedPhotosRepository?
    @ObservedObject var presentation: AlbumPresentationStore
    let onOpen: () -> Void
    @State private var dragPreview: NSImage?
    @State private var confirmDelete = false
    @State private var rename = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                AlbumCoverView(thumbnail: album.thumbnail, repository: repository, collection: collection, onImage: { dragPreview = $0 })
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(itemCountText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(AlbumDragGesture(collection: collection, name: album.name, repository: repository,
                                   session: model.session, preview: dragPreview))
        .background(AlbumMembershipTarget(collection: collection, model: model))
        .contextMenu {
            Button("Add to Sidebar") { presentation.add(collection) }
            if !album.isIncoming || model.capabilities(for: collection).allowsDownloads {
                Divider()
                AlbumDownloadCommands(albumID: album.id, repository: repository, incomingCollection: album.isIncoming ? collection : nil)
            }
            if !album.isIncoming {
                Divider()
                Button("Rename Album…") { rename = true }
                    .disabled(model.albumOperation != nil || album.type != "normal")
                Button("Delete Album…", role: .destructive) { confirmDelete = true }
                    .disabled(model.albumOperation != nil || album.type != "normal")
            }
        }
        .sheet(isPresented: $rename) { AlbumRenameView(album: album) }
        .alert("Delete Album?", isPresented: $confirmDelete) {
            Button("Delete Album", role: .destructive) { model.deleteAlbum(album.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Delete ‘\(album.name)’? Its photos and videos will remain in your library.") }
        .accessibilityLabel("\(album.name), \(itemCountText)")
        .help(album.name)
    }

    private var itemCountText: String {
        album.itemCount == 1 ? "1 item" : "\(album.itemCount) items"
    }
}

/// Shared by album surfaces without opening the album or changing selection.
struct AlbumDownloadCommands: View {
    @Environment(LibraryModel.self) private var library
    let albumID: Int64
    let repository: CachedPhotosRepository?
    var incomingCollection: PhotoCollectionDescriptor? = nil

    var body: some View {
        ForEach(Array(photoDownloadActions.enumerated()), id: \.offset) { _, action in
            Button(action.0) {
                guard let repository else { return }
                library.session.downloads.start(repository: repository, source: incomingCollection.map { .incomingAlbum($0) } ?? .album(albumID),
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
    var collection: PhotoCollectionDescriptor
    var cornerRadius: CGFloat = 8
    var placeholderFont: Font = .largeTitle
    var placeholderSymbol: String = "rectangle.stack"
    var maxPixel: Int = 512
    var onImage: (NSImage?) -> Void = { _ in }
    @State private var image: NSImage?

    private var identity: String {
        guard let thumbnail else { return "missing" }
        return "\(repository?.namespace ?? "unavailable"):\(collection.rawValue):\(thumbnail.unitID):\(thumbnail.cacheKey):\(maxPixel)"
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
                        Image(systemName: placeholderSymbol)
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
            thumbnail, size: .m, allowNetwork: true, collection: collection, priority: .visible
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

/// Cover of a folder card: the folder's own cover, or a 2×2 tile of representative descendants.
struct FolderCoverView: View {
    let folder: FolderSummary
    let repository: CachedPhotosRepository?
    let space: PhotoSpace
    @State private var covers: [ThumbnailInfo] = []

    var body: some View {
        let collection = PhotoCollectionDescriptor.library(space)
        Group {
            if covers.count < 2 {
                AlbumCoverView(thumbnail: covers.first ?? folder.thumbnail, repository: repository, collection: collection, placeholderSymbol: "folder")
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                            GridRow { tile(0, collection); tile(1, collection) }
                            GridRow { tile(2, collection); tile(3, collection) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: folder) {
            guard let repository else { return }
            if covers.isEmpty, let cached = await repository.cachedFolderCovers(for: folder, space: space) { covers = cached }
            let fresh = await repository.folderCovers(for: folder, space: space)
            if !Task.isCancelled, fresh != covers { covers = fresh }
        }
    }

    @ViewBuilder private func tile(_ index: Int, _ collection: PhotoCollectionDescriptor) -> some View {
        if index < covers.count {
            AlbumCoverView(thumbnail: covers[index], repository: repository, collection: collection, cornerRadius: 0, maxPixel: 256)
        } else {
            Color.secondary.opacity(0.12).aspectRatio(1, contentMode: .fit)
        }
    }
}
