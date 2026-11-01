import PhotoCache
import SwiftUI
import SynologyAPI

struct AlbumSidebarSection: View {
    @ObservedObject var presentation: AlbumPresentationStore
    let albums: [AlbumSummary]
    let repository: CachedPhotosRepository?

    var body: some View {
        Section("Albums") {
            Label("Albums", systemImage: "rectangle.stack")
                .tag(SidebarSelection.destination(.albums))
            ForEach(presentation.pinnedIDs, id: \.self) { id in
                let album = albums.first { $0.id == id }
                HStack(spacing: 8) {
                    AlbumCoverView(thumbnail: album?.thumbnail, repository: repository,
                                   cornerRadius: 3, placeholderFont: .caption, maxPixel: 96)
                        .frame(width: 24, height: 24)
                    Text(album?.name ?? "Unavailable Album").lineLimit(1)
                }
                .tag(SidebarSelection.album(id))
                .contextMenu {
                    Button("Remove from Sidebar") { presentation.remove(id) }
                    Divider()
                    AlbumDownloadCommands(albumID: id, repository: repository)
                }
            }
        }
    }
}
