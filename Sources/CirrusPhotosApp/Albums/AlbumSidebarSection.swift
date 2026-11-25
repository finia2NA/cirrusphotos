import PhotoCache
import SwiftUI
import SynologyAPI

/// Command-1 to Command-9 add the browser selection to the first nine sidebar albums.
func sidebarAlbumShortcutNumber(of collection: PhotoCollectionDescriptor, in pins: [PhotoCollectionDescriptor]) -> Int? {
    guard let index = pins.prefix(9).firstIndex(of: collection) else { return nil }
    return index + 1
}

struct AlbumSidebarSection: View {
    @Environment(LibraryModel.self) private var model
    @ObservedObject var presentation: AlbumPresentationStore
    let albums: [AlbumSummary]
    let repository: CachedPhotosRepository?
    let commandKey: CommandKeyHoldState
    let showOverviewForDrag: (String) -> Void
    let select: (SidebarSelection) -> Void
    @State private var containment: Set<PhotoCollectionDescriptor> = []

    private struct ContainmentKey: Hashable {
        let viewer: Bool
        let selection: UInt64
        let membership: UInt64
        let pins: [PhotoCollectionDescriptor]
    }

    private var containmentKey: ContainmentKey? {
        guard commandKey.isShowingShortcuts, model.albumShortcutSnapshot != nil else { return nil }
        let viewer = model.canCloseViewer
        return ContainmentKey(viewer: viewer, selection: viewer ? model.viewerShortcutRevision : model.browserSelectionRevision, membership: model.albumMembershipRevision,
                              pins: Array(presentation.pinnedCollections.prefix(9)))
    }

    var body: some View {
        let pins = presentation.pinnedCollections
        Section("Albums") {
            Label("Albums", systemImage: "rectangle.stack")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .tag(SidebarSelection.destination(.albums))
                .background(AlbumOverviewSpringTarget(namespace: repository?.namespace, selections: model.session.drags.selections,
                                                      albums: model.session.drags.albums, presentation: presentation,
                                                      open: showOverviewForDrag))
            if pins.isEmpty {
                Text("Drag albums here to pin them")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(AlbumPinPlaceholderTarget(namespace: repository?.namespace,
                                                          albums: model.session.drags.albums, presentation: presentation))
                    .selectionDisabled()
            }
            ForEach(Array(pins.enumerated()), id: \.element) { index, id in
                let album = albums.first { $0.collection == id }
                let number = commandKey.isShowingShortcuts && model.canAddSelection(toPinned: id)
                    ? sidebarAlbumShortcutNumber(of: id, in: pins) : nil
                AlbumSidebarRow(id: id, next: index + 1 < pins.count ? pins[index + 1] : nil, album: album,
                                repository: repository, presentation: presentation,
                                shortcutNumber: number, containsSelection: containment.contains(id),
                                select: { select(.album(id)) })
                    .tag(SidebarSelection.album(id))
            }
        }
        .task(id: containmentKey) {
            guard let key = containmentKey else { containment = []; return }
            let result = await model.cachedSelectionContainment(in: key.pins)
            guard !Task.isCancelled else { return }
            containment = result
        }
    }
}

/// The digit of a sidebar album shortcut, or a check when cached metadata shows the album
/// already holds the whole selection.
private struct AlbumShortcutBadge: View {
    let number: Int
    let contained: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(contained ? AnyShapeStyle(Color.green) : AnyShapeStyle(.quaternary))
            if contained {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else {
                Text(verbatim: "\(number)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct AlbumSidebarRow: View {
    @Environment(LibraryModel.self) private var model
    let id: PhotoCollectionDescriptor
    let next: PhotoCollectionDescriptor?
    let album: AlbumSummary?
    let repository: CachedPhotosRepository?
    @ObservedObject var presentation: AlbumPresentationStore
    let shortcutNumber: Int?
    let containsSelection: Bool
    let select: () -> Void
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
            Spacer(minLength: 0)
            if let shortcutNumber {
                AlbumShortcutBadge(number: shortcutNumber, contained: containsSelection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(AlbumDragGesture(collection: id, name: album?.name ?? "Album",
                                     repository: repository, session: model.session, preview: dragPreview, onClick: select))
        .background(AlbumSidebarRowTarget(collection: id, next: next, model: model, presentation: presentation))
        .contextMenu {
            Button("Remove from Sidebar") { presentation.remove(id) }
            if let album, let albumID = id.albumID {
                Divider()
                AlbumDownloadCommands(albumID: albumID, repository: repository)
                Divider()
                Button("Rename Album…") { rename = true }
                    .disabled(model.albumOperation != nil || album.type != "normal")
                Button("Delete Album…", role: .destructive) { confirmDelete = true }
                    .disabled(model.albumOperation != nil || album.type != "normal")
            }
        }
        .sheet(isPresented: $rename) { if let album { AlbumRenameView(album: album).focusRingsOnlyForKeyboardNavigation() } }
        .alert("Delete Album?", isPresented: $confirmDelete) {
            Button("Delete Album", role: .destructive) { if let albumID = id.albumID { model.deleteAlbum(albumID) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Delete ‘\(album?.name ?? "Album")’? Its photos and videos will remain in your library.") }
    }
}
