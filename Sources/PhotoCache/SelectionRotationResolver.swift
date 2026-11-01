import Foundation
import SynologyAPI

/// Resolves selected still-image items from only the required verified pages.
public struct SelectionRotationResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot,
                        selectedOrdinals: IndexSet, knownItemIDsByOrdinal: [Int: Int64],
                        expectedTimelineFingerprint: String? = nil) async -> SelectionRotationAction? {
        guard await repository.mediaCollection(for: collection) == .personalLibrary else { return nil }
        guard !selectedOrdinals.isEmpty else { return nil }
        let index = LibraryIndex(snapshot: snapshot)
        guard expectedTimelineFingerprint == nil || expectedTimelineFingerprint == index.fingerprint else { return nil }
        let locations = selectedOrdinals.compactMap { index.location(forOrdinal: $0) }
        guard locations.count == selectedOrdinals.count else { return nil }
        var grouped: [Int: [LibraryIndex.Location]] = [:]
        for location in locations { grouped[location.sectionIndex, default: []].append(location) }
        var itemsByID: [Int64: PhotoItem] = [:]
        var sectionsByID: [Int64: TimelineSection] = [:]
        var resolvedByOrdinal: [Int: Int64] = [:]
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
                        for await event in await repository.page(section, collection: collection,
                                                                 allowNetwork: true, priority: .prefetch) {
                            if case .value(let items, _) = event {
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
                let section = index.sections[sectionIndex]
                for location in grouped[sectionIndex] ?? [] {
                    guard let slot = items.slot(at: location.pageOffset), slot.verified, let item = slot.item else { return nil }
                    if let known = knownItemIDsByOrdinal[location.ordinal], known != item.id { return nil }
                    guard item.hasDisplayableStillImage, item.additional?.thumbnail != nil else { continue }
                    itemsByID[item.id] = item
                    sectionsByID[item.id] = section
                    resolvedByOrdinal[location.ordinal] = item.id
                }
            }
        }
        guard let current = await repository.latestTimelineSnapshot(collection: collection),
              LibraryIndex(snapshot: current).fingerprint == index.fingerprint else { return nil }
        let ids = selectedOrdinals.compactMap { resolvedByOrdinal[$0] }
        return SelectionRotationAction(itemIDs: ids, sectionsByID: sectionsByID,
                                       collection: collection, itemsByID: itemsByID,
                                       expectedTimelineFingerprint: index.fingerprint)
    }
}
