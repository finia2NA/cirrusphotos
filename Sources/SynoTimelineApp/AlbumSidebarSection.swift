import PhotoCache
import SwiftUI
import SynologyAPI

struct AlbumSidebarSection: View {
    @ObservedObject var presentation: AlbumPresentationStore
    let albums: [AlbumSummary]
    let repository: CachedPhotosRepository?
    let showOverviewForDrag: (String) -> Void

    var body: some View {
        Section("Albums") {
            Label("Albums", systemImage: "rectangle.stack")
                .tag(SidebarSelection.destination(.albums))
                .background(AlbumOverviewSpringTarget(namespace: repository?.namespace, open: showOverviewForDrag))
                .overlay(alignment: .bottom) {
                    if presentation.pinnedCollections.isEmpty {
                        AlbumInsertionTarget(before: nil, namespace: repository?.namespace, presentation: presentation)
                            .frame(height: 8)
                    }
                }
            ForEach(presentation.pinnedCollections, id: \.self) { id in
                let album = albums.first { $0.collection == id }
                AlbumSidebarRow(id: id, album: album, repository: repository, presentation: presentation)
                    .tag(SidebarSelection.album(id))
                    .overlay(alignment: .top) {
                        AlbumInsertionTarget(before: id, namespace: repository?.namespace, presentation: presentation)
                            .frame(height: 8)
                    }
                    .overlay(alignment: .bottom) {
                        if id == presentation.pinnedCollections.last {
                            AlbumInsertionTarget(before: nil, namespace: repository?.namespace, presentation: presentation)
                                .frame(height: 8)
                        }
                    }
            }
        }
    }
}


private struct AlbumSidebarRow: View {
    @Environment(LibraryModel.self) private var model
    let id: PhotoCollectionDescriptor
    let album: AlbumSummary?
    let repository: CachedPhotosRepository?
    @ObservedObject var presentation: AlbumPresentationStore
    @State private var dragPreview: NSImage?
    @State private var confirmDelete = false
    @State private var rename = false
    var body: some View {
        HStack(spacing: 8) {
            AlbumCoverView(thumbnail: album?.thumbnail, repository: repository, collection: id,
                           cornerRadius: 3, placeholderFont: .caption, maxPixel: 96,
                           onImage: { dragPreview = $0 })
                .frame(width: 24, height: 24)
            Text(album?.name ?? "Unavailable Album").lineLimit(1)
        }
        .modifier(AlbumDragGesture(collection: id, name: album?.name ?? "Album",
                                     repository: repository, preview: dragPreview))
        .background(AlbumMembershipTarget(collection: id, model: model))
        .contextMenu {
            Button("Remove from Sidebar") { presentation.remove(id) }
            if let album, let albumID = id.albumID {
                Divider()
                AlbumDownloadCommands(albumID: albumID, repository: repository)
                Divider()
                Button("Rename Album…") { rename = true }
                    .disabled(model.deletingAlbumID != nil || model.albumOperation != nil || album.type != "normal")
                Button("Delete Album…", role: .destructive) { confirmDelete = true }
                    .disabled(model.deletingAlbumID != nil || model.albumOperation != nil || album.type != "normal")
            }
        }
        .sheet(isPresented: $rename) { if let album { AlbumRenameView(album: album) } }
        .alert("Delete Album?", isPresented: $confirmDelete) {
            Button("Delete Album", role: .destructive) { if let albumID = id.albumID { model.deleteAlbum(albumID) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Delete ‘\(album?.name ?? "Album")’? Its photos and videos will remain in your library.") }
    }
}
