import AppKit
import PhotoCache
import SynologyAPI

func isKnownNormalAlbum(_ id: Int64?, in albums: [AlbumSummary]) -> Bool {
    guard let id else { return false }
    return albums.contains { !$0.isIncoming && $0.id == id && $0.type == "normal" }
}

/// Preserve sidebar order, followed by the server's album-name order.
func orderedAddableAlbums(_ albums: [AlbumSummary], pinnedIDs: [Int64]) -> (pinned: [AlbumSummary], remaining: [AlbumSummary]) {
    var byID: [Int64: AlbumSummary] = [:]
    var unique: [AlbumSummary] = []
    for album in albums where byID[album.id] == nil {
        byID[album.id] = album
        unique.append(album)
    }
    var seen = Set<Int64>()
    let pinned = pinnedIDs.compactMap { id -> AlbumSummary? in
        guard seen.insert(id).inserted else { return nil }
        return byID[id]
    }
    let pinnedSet = Set(pinned.map(\.id))
    return (pinned, unique.filter { !pinnedSet.contains($0.id) })
}

extension LibraryModel {
    func addAlbumMembershipMenu(to menu: NSMenu, captured: BrowserCommandSnapshot, pinnedIDs: [Int64]) {
        guard let repository, let selection = captured.captureSelection(timeline: captured.timeline),
              selection.authority != nil, !selection.selectedOrdinals.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let parent = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Add to Album")
        @MainActor func addNewAlbumAction() {
            submenu.addItem(PhotoDownloadMenuItem(title: "New Album…") { [weak self] in
                guard let self, self.repository?.namespace == repository.namespace else { return }
                self.beginAlbumOperation(.create, selection: selection, sourceAlbumID: captured.sourceAlbumID)
            })
        }
        addNewAlbumAction()
        submenu.addItem(.separator())
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)
        parent.submenu = submenu
        menu.addItem(parent)
        if isNormalAlbum(captured.sourceAlbumID) {
            menu.addItem(PhotoDownloadMenuItem(title: "Remove from Album…") { [weak self] in
                guard let self, self.repository?.namespace == repository.namespace else { return }
                self.beginAlbumOperation(.remove, captured: captured)
            })
        }
        Task { [weak self] in
            do {
                let albums = try await repository.addableAlbums()
                let ordered = orderedAddableAlbums(albums, pinnedIDs: pinnedIDs)
                submenu.removeAllItems()
                addNewAlbumAction()
                @MainActor func append(_ album: AlbumSummary) {
                    submenu.addItem(PhotoDownloadMenuItem(title: album.name) { [weak self] in
                        guard let self, self.repository?.namespace == repository.namespace else { return }
                        _ = self.addCapturedSelection(selection, sourceAlbumID: captured.sourceAlbumID, to: album.id)
                    })
                }
                if !ordered.pinned.isEmpty || !ordered.remaining.isEmpty { submenu.addItem(.separator()) }
                ordered.pinned.forEach(append)
                if !ordered.pinned.isEmpty && !ordered.remaining.isEmpty { submenu.addItem(.separator()) }
                ordered.remaining.forEach(append)
                if ordered.pinned.isEmpty && ordered.remaining.isEmpty {
                    submenu.addItem(.separator())
                    let empty = NSMenuItem(title: "No Albums Available", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                }
            } catch {
                submenu.removeAllItems()
                addNewAlbumAction()
                submenu.addItem(.separator())
                let failed = NSMenuItem(title: "Could Not Load Albums", action: nil, keyEquivalent: "")
                failed.isEnabled = false
                submenu.addItem(failed)
                self?.albumOperationError = error.localizedDescription
            }
        }
    }
}
