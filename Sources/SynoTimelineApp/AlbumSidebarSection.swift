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
                    if presentation.pinnedIDs.isEmpty {
                        AlbumInsertionTarget(before: nil, namespace: repository?.namespace, presentation: presentation)
                            .frame(height: 8)
                    }
                }
            ForEach(presentation.pinnedIDs, id: \.self) { id in
                let album = albums.first { $0.id == id }
                AlbumSidebarRow(id: id, album: album, repository: repository, presentation: presentation)
                    .tag(SidebarSelection.album(id))
                    .overlay(alignment: .top) {
                        AlbumInsertionTarget(before: id, namespace: repository?.namespace, presentation: presentation)
                            .frame(height: 8)
                    }
                    .overlay(alignment: .bottom) {
                        if id == presentation.pinnedIDs.last {
                            AlbumInsertionTarget(before: nil, namespace: repository?.namespace, presentation: presentation)
                                .frame(height: 8)
                        }
                    }
            }
        }
    }
}


private struct AlbumSidebarRow: View {
    @EnvironmentObject private var model: LibraryModel
    let id: Int64
    let album: AlbumSummary?
    let repository: CachedPhotosRepository?
    @ObservedObject var presentation: AlbumPresentationStore
    @State private var dragPreview: NSImage?
    var body: some View {
        HStack(spacing: 8) {
            AlbumCoverView(thumbnail: album?.thumbnail, repository: repository,
                           cornerRadius: 3, placeholderFont: .caption, maxPixel: 96,
                           onImage: { dragPreview = $0 })
                .frame(width: 24, height: 24)
            Text(album?.name ?? "Unavailable Album").lineLimit(1)
        }
        .modifier(AlbumDragGesture(albumID: id, name: album?.name ?? "Album",
                                     repository: repository, preview: dragPreview))
        .background(AlbumMembershipTarget(albumID: id, model: model))
        .contextMenu {
            Button("Remove from Sidebar") { presentation.remove(id) }
            Divider()
            AlbumDownloadCommands(albumID: id, repository: repository)
        }
    }
}
