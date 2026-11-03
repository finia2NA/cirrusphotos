import Foundation
import SynologyAPI

// Actor-isolated metadata coordination; task identities remain owned by the session.
extension PhotoViewerSession {
    func invalidateMetadataPages(_ change: MetadataCollectionInvalidation) {
        guard !closed, !(collection.favoriteOnly && playlist.hasEntries) else { return }
        var affectedCurrent = false
        for position in index.sections.indices {
            guard let raw = index.sections[position].list.first,
                  let day = try? CaptureDay(year: raw.year, month: raw.month, day: raw.day),
                  change.days == nil || change.days!.contains(day) else { continue }
            if let page = metadata.pages[position] {
                metadata.pages[position] = ViewerMetadataWindow.PageEntry(slots: page.slots.map { PhotoItemSlot(itemID: $0.itemID, item: $0.item, verified: false) }, verified: false, membershipVerified: false)
            }
            if position == desired.sectionIndex { affectedCurrent = true }
        }
        if affectedCurrent {
            metadataVerified = false
            metadataStatus = .ready(verified: false, validationFailure: nil)
            ensurePage(desired.sectionIndex, visible: true)
            publish()
        }
    }

    func applyItemChanges(_ change: PhotoItemChange) {
        guard supportsItemActions, change.scope == mediaContentScope else { return }
        if !change.favoriteValues.isEmpty { applyFavorites(change.favoriteValues) }
        for (section, page) in metadata.pages {
            let updated = page.slots.map { slot in
                PhotoItemSlot(itemID: slot.itemID, item: change.items[slot.itemID].map { replacement in
                    applyingFavorite(slot.item?.withRotationMetadata(from: replacement) ?? replacement)
                } ?? slot.item, verified: slot.verified)
            }
            metadata.pages[section] = ViewerMetadataWindow.PageEntry(slots: updated, verified: page.verified, membershipVerified: page.membershipVerified)
        }
        guard let id = currentItem?.id, let replacement = change.items[id] else { return }
        let updated = currentItem?.withRotationMetadata(from: replacement) ?? replacement
        currentItem = applyingFavorite(updated)
        currentIdentity = Self.identity(of: updated)
        if change.quarterTurns[id] == nil {
            generation &+= 1
            images.resetSelection(keeping: replacement.fullImageResource(in: mediaContentScope))
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
        if collection.favoriteOnly, playlist.hasEntries, network {
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
                    guard let address = try? DayPageAddress(section: descriptor, collection: collection) else { return }
                    let page = PhotoPageSnapshot(address: address, membershipRevision: 0, membershipVerified: true,
                                                 slots: items.map { PhotoItemSlot(itemID: $0.id, item: $0, verified: true) })
                    await self?.receivePage(.value(page, verified: true), sectionIndex: sectionIndex,
                                            id: id, retryRevision: revision)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.receivePage(.failure(RepositoryError.record(error, operation: "Viewer page")), sectionIndex: sectionIndex,
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

    func receivePage(_ event: ResourceEvent<PhotoPageSnapshot>, sectionIndex: Int,
                             id: UUID, retryRevision: Int) {
        guard !closed, self.retryRevision == retryRevision, metadata.pageJobs[sectionIndex]?.id == id else { return }
        switch event {
        case .value(let items, let verified):
            if metadata.pages[sectionIndex]?.verified == true && !verified { return }
            if sectionIndex == desired.sectionIndex && metadataVerified && !verified { return }
            let slots = items.slots.map { slot in PhotoItemSlot(itemID: slot.itemID, item: slot.item.map(applyingFavorite), verified: slot.verified) }
            metadata.pages[sectionIndex] = ViewerMetadataWindow.PageEntry(slots: slots, verified: verified, membershipVerified: items.membershipVerified)
            metadata.trimPages(around: desired)
            if sectionIndex == desired.sectionIndex {
                applyCurrentPage(ViewerMetadataWindow.PageEntry(slots: slots, verified: verified, membershipVerified: items.membershipVerified), at: desired)
            }
            if images.prefetchEnabledGeneration == generation { scheduleLoadedNeighbors() }
            scheduleThumbnailNeighbors()
        case .failure(let message):
            if sectionIndex == desired.sectionIndex {
                if currentItem == nil { metadataStatus = .failure(message.localizedDescription) }
                else { metadataStatus = .ready(verified: metadataVerified, validationFailure: message.localizedDescription) }
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
        if let selected = currentItem, page.membershipVerified {
            if let shiftedOffset = page.slots.firstIndex(where: { $0.itemID == selected.id }) {
                let spanStart = metadata.spans[location.sectionIndex].start
                desired = PhotoViewerLocation(sectionIndex: location.sectionIndex,
                                              pageOffset: shiftedOffset,
                                              ordinal: spanStart + shiftedOffset)
                guard let resolved = page.slot(at: shiftedOffset)?.item else {
                    metadataVerified = false
                    metadataStatus = .ready(verified: false, validationFailure: nil)
                    publish()
                    return
                }
                item = resolved
            } else {
                clearCurrentForMissingItem("The selected item is no longer in this page.")
                return
            }
        } else {
            guard let slot = page.slot(at: location.pageOffset), let resolved = slot.item else {
                metadataVerified = false
                metadataStatus = .ready(verified: false, validationFailure: nil)
                publish()
                return
            }
            item = resolved
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
            images.resetSelection(keeping: item.fullImageResource(in: mediaContentScope))
        } else {
            currentItem = item
        }
        metadataVerified = page.slot(at: desired.pageOffset)?.verified == true
        metadataStatus = .ready(verified: metadataVerified, validationFailure: nil)
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
