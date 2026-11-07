import Foundation
import SynologyAPI

/// Resolves items from only the required verified pages.
public struct SelectionItemResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(_ selection: PhotoSelectionSnapshot) async -> [PhotoItem]? {
        await resolveWithReceipt(selection)?.items
    }

    public func resolveWithReceipt(_ selection: PhotoSelectionSnapshot) async -> ResolvedPhotoSelection? {
        defer { selection.retention?.release() }
        let collection = selection.collection
        let snapshot = selection.timeline
        let selectedOrdinals = selection.selectedOrdinals
        guard !selectedOrdinals.isEmpty else { return nil }
        let index = LibraryIndex(snapshot: snapshot)
        let authority: PhotoSelectionAuthority
        if let captured = selection.authority { authority = captured }
        else {
            guard !collection.isMapFilter, !collection.isLibraryFilter,
                  let captured = await repository.selectionAuthority(collection: collection, snapshot: snapshot) else { return nil }
            authority = captured
        }
        guard await repository.selectionAuthorityMatches(authority, collection: collection, fingerprint: index.fingerprint),
              let lease = await repository.beginSelectionLease(authority) else { return nil }
        let result = await resolve(selection, authority: authority, index: index)
        selection.retention?.release()
        await repository.endSelectionLease(lease)
        return result
    }

    private func resolve(_ selection: PhotoSelectionSnapshot, authority: PhotoSelectionAuthority, index: LibraryIndex) async -> ResolvedPhotoSelection? {
        let collection = selection.collection
        let selectedOrdinals = selection.selectedOrdinals
        let knownItemIDsByOrdinal = selection.knownItemIDsByOrdinal
        let expectedTimelineFingerprint = selection.timelineFingerprint
        guard expectedTimelineFingerprint == index.fingerprint else { return nil }
        let locations = selectedOrdinals.compactMap { index.location(forOrdinal: $0) }
        guard locations.count == selectedOrdinals.count else { return nil }
        var grouped: [Int: [LibraryIndex.Location]] = [:]
        for location in locations { grouped[location.sectionIndex, default: []].append(location) }
        var resolvedByOrdinal: [Int: PhotoItem] = [:]
        var revisions: [Int: UInt64] = [:]
        let sectionIndices = grouped.keys.sorted()
        for start in stride(from: 0, to: sectionIndices.count, by: 2) {
            guard !Task.isCancelled else { return nil }
            let chunk = Array(sectionIndices[start..<min(start + 2, sectionIndices.count)])
            let results = await withTaskGroup(of: (Int, PhotoPageSnapshot?).self) { group in
                for sectionIndex in chunk {
                    let section = index.sections[sectionIndex]
                    let selectedOffsets = (grouped[sectionIndex] ?? []).map(\.pageOffset)
                    group.addTask {
                        var verified: PhotoPageSnapshot?
                        var initialIDs: [Int: Int64] = [:]
                        for await event in await repository.page(section, collection: collection,
                                                                 allowNetwork: true, priority: .prefetch) {
                            if case .value(let items, _) = event {
                                for offset in selectedOffsets {
                                    guard let slot = items.slot(at: offset) else { continue }
                                    if let initial = initialIDs[offset], initial != slot.itemID { return (sectionIndex, nil) }
                                    initialIDs[offset] = slot.itemID
                                }
                                if selectedOffsets.allSatisfy({ items.slot(at: $0)?.verified == true }) { return (sectionIndex, items) }
                                verified = items
                            }
                            if case .failure = event { return (sectionIndex, nil) }
                        }
                        return (sectionIndex, verified)
                    }
                }
                var values: [(Int, PhotoPageSnapshot?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (sectionIndex, items) in results {
                guard let items else { return nil }
                revisions[sectionIndex] = items.membershipRevision
                for location in grouped[sectionIndex] ?? [] {
                    guard let slot = items.slot(at: location.pageOffset), slot.verified, let item = slot.item else { return nil }
                    if let known = knownItemIDsByOrdinal[location.ordinal], known != item.id { return nil }
                    resolvedByOrdinal[location.ordinal] = item
                }
            }
        }
        // Validate filtered membership against the exact selected source slots.
        guard let checks = await repository.selectionSourceChecks(authority, locations: locations) else { return nil }
        var proofs: [SelectionMembershipProof] = []
        for check in checks {
            var verified: PhotoPageSnapshot?
            for await event in await repository.page(check.section, collection: check.collection, allowNetwork: true, priority: .prefetch) {
                if case .value(let page, _) = event,
                   check.offsetsAndIDs.allSatisfy({ offset, id in
                       guard let slot = page.slot(at: offset) else { return false }
                       return slot.verified && slot.itemID == id
                   }) { verified = page; break }
                if case .failure = event { return nil }
            }
            guard let verified, !Task.isCancelled else { return nil }
            if !check.collection.isMapFilter && !check.collection.isLibraryFilter {
                proofs.append(SelectionMembershipProof(address: verified.address, revision: verified.membershipRevision,
                                                       offsetsAndIDs: check.offsetsAndIDs))
            }
        }
        // Re-read only selected pages after all asynchronous work. A same-shape
        // membership replacement must not turn earlier ordinal results into a write.
        for sectionIndex in sectionIndices {
            var latest: PhotoPageSnapshot?
            for await event in await repository.page(index.sections[sectionIndex], collection: collection, allowNetwork: false) {
                if case .value(let page, _) = event { latest = page }
            }
            guard let latest, latest.membershipRevision == revisions[sectionIndex] else { return nil }
            var offsetsAndIDs: [(Int, Int64)] = []
            for location in grouped[sectionIndex] ?? [] {
                guard let slot = latest.slot(at: location.pageOffset), slot.verified,
                      slot.itemID == resolvedByOrdinal[location.ordinal]?.id else { return nil }
                offsetsAndIDs.append((location.pageOffset, slot.itemID))
            }
            if !collection.isMapFilter && !collection.isLibraryFilter {
                proofs.append(SelectionMembershipProof(address: latest.address, revision: latest.membershipRevision,
                                                       offsetsAndIDs: offsetsAndIDs))
            }
        }
        guard await repository.verifySelectionFence(authority, proofs: proofs),
              let current = await repository.latestTimelineSnapshot(collection: collection),
              LibraryIndex(snapshot: current).fingerprint == index.fingerprint else { return nil }
        let items = selectedOrdinals.compactMap { resolvedByOrdinal[$0] }
        guard items.count == selectedOrdinals.count && !Task.isCancelled else { return nil }
        return ResolvedPhotoSelection(items: items, authority: authority, proofs: proofs)
    }
}
