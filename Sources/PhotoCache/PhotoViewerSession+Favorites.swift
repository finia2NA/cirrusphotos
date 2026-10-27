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
            if collection == .favorites {
                playlist.commit(itemID: itemID, isFavorite: target)
                // Any transient page request started while the write was pending used
                // the prior server-membership translation and must not publish after
                // the filtered endpoint changes.
                playlistDidChange()
            }
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
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
    }

    func applyingFavorite(_ item: PhotoItem) -> PhotoItem {
        guard let value = favoriteValues[item.id] else { return item }
        return item.withFavorite(value)
    }

    func applyingFavorites(_ items: [PhotoItem]) -> [PhotoItem] { items.map(applyingFavorite) }

    func applyFavorites(_ values: [Int64: Bool]) {
        for (itemID, value) in values {
            favoriteValues[itemID] = value
        }
        var pagesChanged = false
        for (section, page) in metadata.pages {
            var modified = false
            let slots = page.slots.map { slot -> PhotoItemSlot in
                guard let item = slot.item, let value = values[item.id], item.isFavorite != value else { return slot }
                modified = true
                return PhotoItemSlot(itemID: slot.itemID, item: item.withFavorite(value), verified: slot.verified)
            }
            if modified {
                metadata.pages[section] = ViewerMetadataWindow.PageEntry(slots: slots, verified: page.verified, membershipVerified: page.membershipVerified)
                pagesChanged = true
            }
        }
        if let current = currentItem, let fav = values[current.id], current.isFavorite != fav {
            currentItem = current.withFavorite(fav)
            publish()
        } else if pagesChanged {
            publish()
        }
    }

    func applyFavorite(itemID: Int64, value: Bool) {
        applyFavorites([itemID: value])
    }
}
