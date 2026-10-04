import Foundation
import SynologyAPI

// Actor-isolated favorites coordination; task identities remain owned by the session.
extension PhotoViewerSession {
    public func toggleFavorite() async {
        guard !closed, allowNetwork, metadataVerified, let item = currentItem,
              !pendingFavoriteIDs.contains(item.id) else { return }
        let itemID = item.id
        pendingFavoriteIDs.insert(itemID)
        favoriteFailures.removeValue(forKey: itemID)
        publish()
        let section = index.sections[desired.sectionIndex]
        let target = !item.isFavorite
        let previousPlaylistEntry = playlist.entry(for: itemID)
        if collection == .favorites,
           let slice = index.slices(inSection: desired.sectionIndex)
            .first(where: { $0.pageRange.contains(desired.pageOffset) }) {
            let dayOffset = slice.dayRange.lowerBound + desired.pageOffset - slice.pageRange.lowerBound
            playlist.record(item: item, dayID: slice.dayID, dayOffset: dayOffset,
                            isFavorite: target)
            playlistDidChange()
        }
        applyFavorite(itemID: itemID, value: target)
        do {
            try await repository.setFavorite(itemID: itemID, item: item, in: section,
                                              collection: collection, to: target)
        } catch {
            if collection == .favorites {
                playlist.restore(previousPlaylistEntry, itemID: itemID)
                playlistDidChange()
            }
            applyFavorite(itemID: itemID, value: item.isFavorite)
            favoriteFailures[itemID] = error.localizedDescription
        }
        pendingFavoriteIDs.remove(itemID)
        publish()
    }

    func reconstructPlaylistPage(_ live: [PhotoItem], plan: ViewerPlaylist.PagePlan,
                                         playlistRevision expectedRevision: UInt64) -> [PhotoItem]? {
        guard expectedRevision == playlistRevision else { return nil }
        return applyingFavorites(playlist.reconstruct(live, using: plan))
    }

    func playlistDidChange() {
        playlistRevision &+= 1
        retryRevision &+= 1
        metadata.cancelJobs()
    }

    func applyingFavorite(_ item: PhotoItem) -> PhotoItem {
        guard let value = favoriteValues[item.id] else { return item }
        return item.withFavorite(value)
    }

    func applyingFavorites(_ items: [PhotoItem]) -> [PhotoItem] { items.map(applyingFavorite) }

    func applyFavorite(itemID: Int64, value: Bool) {
        favoriteValues[itemID] = value
        for (section, page) in metadata.pages where page.items.contains(where: { $0.id == itemID }) {
            metadata.pages[section] = ViewerMetadataWindow.PageEntry(items: page.items.map { $0.id == itemID ? $0.withFavorite(value) : $0 },
                                       verified: page.verified)
        }
        if currentItem?.id == itemID {
            currentItem = currentItem?.withFavorite(value)
            publish()
        }
    }
}
