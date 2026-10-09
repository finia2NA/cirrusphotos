import Foundation
import SynologyAPI

// Actor-isolated metadata coordination; task identities remain owned by the session.
extension PhotoViewerSession {
    func applyItemChanges(_ change: PhotoItemChange) {
        for (section, page) in metadata.pages {
            let updated = page.items.map { change.items[$0.id] ?? $0 }
            metadata.pages[section] = ViewerMetadataWindow.PageEntry(items: updated, verified: page.verified)
        }
        guard let id = currentItem?.id, let replacement = change.items[id] else { return }
        currentItem = applyingFavorite(replacement)
        currentIdentity = Self.identity(of: replacement)
        if change.quarterTurns[id] == nil {
            generation &+= 1
            images.resetSelection(keeping: replacement.fullImageResource)
            startAssetsForCurrentMetadata()
        }
        publish()
    }

    func ensurePage(_ sectionIndex: Int, visible: Bool) {
        guard !closed, index.sections.indices.contains(sectionIndex) else { return }
        if let page = metadata.pages[sectionIndex], page.verified || !allowNetwork {
            if sectionIndex == desired.sectionIndex { applyCurrentPage(page, at: desired) }
            if images.prefetchEnabledGeneration == generation { scheduleLoadedNeighbors() }
            return
        }
        if let job = metadata.pageJobs[sectionIndex], job.allowNetwork == allowNetwork {
            if visible { Task { await repository.promotePage(index.sections[sectionIndex], collection: collection) } }
            return
        }
        metadata.pageJobs.removeValue(forKey: sectionIndex)?.task.cancel()
        let id = UUID()
        let descriptor = index.sections[sectionIndex]
        let network = allowNetwork
        let collection = collection
        let revision = retryRevision
        let repository = repository
        let priority: RequestPriority = visible ? .visible : .prefetch
        if collection == .favorites, playlist.hasEntries, network {
            let plan = playlist.plan(for: descriptor)
            let playlistRevision = playlistRevision
            let task = Task { [weak self] in
                do {
                    let live = try await repository.transientPage(plan.liveSection,
                                                                  collection: collection,
                                                                  priority: priority)
                    guard !Task.isCancelled else { return }
                    let items = await self?.reconstructPlaylistPage(
                        live, plan: plan, playlistRevision: playlistRevision
                    )
                    guard let items else { return }
                    await self?.receivePage(.value(items, verified: true), sectionIndex: sectionIndex,
                                            id: id, retryRevision: revision)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.receivePage(.failure(error.localizedDescription), sectionIndex: sectionIndex,
                                            id: id, retryRevision: revision)
                }
                await self?.finishPage(sectionIndex: sectionIndex, id: id)
            }
            metadata.pageJobs[sectionIndex] = ViewerMetadataWindow.PageJob(id: id, allowNetwork: network, task: task)
            return
        }
        let task = Task { [weak self] in
            for await event in await repository.page(descriptor, collection: collection,
                                                      allowNetwork: network, priority: priority) {
                guard !Task.isCancelled else { break }
                await self?.receivePage(event, sectionIndex: sectionIndex, id: id, retryRevision: revision)
            }
            await self?.finishPage(sectionIndex: sectionIndex, id: id)
        }
        metadata.pageJobs[sectionIndex] = ViewerMetadataWindow.PageJob(id: id, allowNetwork: network, task: task)
    }

    func receivePage(_ event: ResourceEvent<[PhotoItem]>, sectionIndex: Int,
                             id: UUID, retryRevision: Int) {
        guard !closed, self.retryRevision == retryRevision, metadata.pageJobs[sectionIndex]?.id == id else { return }
        switch event {
        case .value(let items, let verified):
            if metadata.pages[sectionIndex]?.verified == true && !verified { return }
            if sectionIndex == desired.sectionIndex && metadataVerified && !verified { return }
            let items = applyingFavorites(items)
            metadata.pages[sectionIndex] = ViewerMetadataWindow.PageEntry(items: items, verified: verified)
            metadata.trimPages(around: desired)
            if sectionIndex == desired.sectionIndex {
                applyCurrentPage(ViewerMetadataWindow.PageEntry(items: items, verified: verified), at: desired)
            }
            if images.prefetchEnabledGeneration == generation { scheduleLoadedNeighbors() }
            scheduleThumbnailNeighbors()
        case .failure(let message):
            if sectionIndex == desired.sectionIndex {
                if currentItem == nil { metadataStatus = .failure(message) }
                else { metadataStatus = .ready(verified: metadataVerified, validationFailure: message) }
                publish()
            }
        }
    }

    func finishPage(sectionIndex: Int, id: UUID) {
        if metadata.pageJobs[sectionIndex]?.id == id { metadata.pageJobs.removeValue(forKey: sectionIndex) }
    }

    func applyCurrentPage(_ page: ViewerMetadataWindow.PageEntry, at location: PhotoViewerLocation) {
        guard desired == location else { return }
        var item: PhotoItem
        if let selected = currentItem, page.verified {
            if let shiftedOffset = page.items.firstIndex(where: { $0.id == selected.id }) {
                let spanStart = metadata.spans[location.sectionIndex].start
                desired = PhotoViewerLocation(sectionIndex: location.sectionIndex,
                                              pageOffset: shiftedOffset,
                                              ordinal: spanStart + shiftedOffset)
                item = page.items[shiftedOffset]
            } else {
                clearCurrentForMissingItem("The selected item is no longer in this page.")
                return
            }
        } else {
            guard page.items.indices.contains(location.pageOffset) else {
                if page.verified {
                    clearCurrentForMissingItem("The selected item is no longer in this page.")
                }
                return
            }
            item = page.items[location.pageOffset]
            if let selected = currentItem, item.id != selected.id {
                // A stale cached page must not replace the exact item supplied by the grid.
                return
            }
        }
        item = applyingFavorite(item)
        let identity = Self.identity(of: item)
        if currentIdentity != identity {
            generation &+= 1
            currentItem = item
            currentIdentity = identity
            images.resetSelection(keeping: item.fullImageResource)
        } else {
            currentItem = item
        }
        metadataVerified = page.verified
        metadataStatus = .ready(verified: page.verified, validationFailure: nil)
        startAssetsForCurrentMetadata()
        publish()
    }

    func clearCurrentForMissingItem(_ message: String) {
        if currentItem != nil || currentIdentity != nil { generation &+= 1 }
        currentItem = nil
        currentIdentity = nil
        metadataVerified = true
        images.resetSelection(keeping: nil)
        metadataStatus = .failure(message)
        images.fullImageStatus = .failure(message)
        publish()
    }
}
