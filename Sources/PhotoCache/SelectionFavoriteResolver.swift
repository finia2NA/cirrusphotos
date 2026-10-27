import Foundation
import SynologyAPI

/// Resolves the current authoritative favorite status of a selection in a bounded manner.
///
/// Follows the bounded pattern used by `ThumbnailRangeDownloader`:
/// - Maps selected ordinals to `LibraryIndex.Location`
/// - Groups locations by timeline section
/// - Reads only sections containing selected ordinals through `CachedPhotosRepository.page`
/// - Waits for verified metadata before authorizing a write
/// - Processes at most 2 metadata pages concurrently and releases each page after extracting items
/// - Retains compact mutation inputs only
/// - Does not request thumbnails or originals and does not affect the browser's retention window
/// - Rejects the operation if index fingerprint changes or if verified identity differs from snapshot
public struct SelectionFavoriteResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) {
        self.repository = repository
    }

    public func resolve(
        collection: PhotoCollectionDescriptor,
        snapshot: TimelineSnapshot,
        selectedOrdinals: IndexSet,
        knownItemIDsByOrdinal: [Int: Int64],
        expectedTimelineFingerprint: String? = nil
    ) async -> SelectionFavoriteAction? {
        guard !selectedOrdinals.isEmpty else { return nil }
        let index = LibraryIndex(snapshot: snapshot)
        let expectedFingerprint = index.fingerprint
        guard expectedTimelineFingerprint == nil || expectedTimelineFingerprint == expectedFingerprint else {
            return nil
        }

        // 1. Map selected ordinals to LibraryIndex.Location values.
        let locations = selectedOrdinals.compactMap { index.location(forOrdinal: $0) }
        guard locations.count == selectedOrdinals.count else { return nil }

        // 2. Group locations by timeline section.
        var locationsBySection: [Int: [LibraryIndex.Location]] = [:]
        for loc in locations {
            locationsBySection[loc.sectionIndex, default: []].append(loc)
        }

        // 3-5. Read only sections containing selected ordinals.
        var resolvedItemsByOrdinal: [Int: (item: PhotoItem, section: TimelineSection)] = [:]
        let sectionIndices = locationsBySection.keys.sorted()
        let concurrency = 2

        for chunkStart in stride(from: 0, to: sectionIndices.count, by: concurrency) {
            if Task.isCancelled { return nil }
            let chunkEnd = min(chunkStart + concurrency, sectionIndices.count)
            let currentSections = Array(sectionIndices[chunkStart..<chunkEnd])

            let repository = self.repository
            let chunkResults = await withTaskGroup(
                of: (Int, PhotoPageSnapshot?).self,
                returning: [(Int, PhotoPageSnapshot?)]?.self
            ) { group in
                for sectionIndex in currentSections {
                    let descriptor = index.sections[sectionIndex]
                    let selectedOffsets = (locationsBySection[sectionIndex] ?? []).map(\.pageOffset)
                    group.addTask {
                        var verifiedItems: PhotoPageSnapshot?
                        for await event in await repository.page(descriptor, collection: collection,
                                                                 allowNetwork: true, priority: .prefetch) {
                            if Task.isCancelled { break }
                            switch event {
                            case .value(let items, let verified):
                                if selectedOffsets.allSatisfy({ items.slot(at: $0)?.verified == true }) { return (sectionIndex, items) }
                                verifiedItems = items
                            case .failure:
                                return (sectionIndex, nil)
                            }
                        }
                        return (sectionIndex, verifiedItems)
                    }
                }
                var results: [(Int, PhotoPageSnapshot?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            guard let chunkResults else { return nil }

            for (sectionIndex, items) in chunkResults {
                guard let items else { return nil }
                let descriptor = index.sections[sectionIndex]
                let locs = locationsBySection[sectionIndex] ?? []
                for loc in locs {
                    guard let slot = items.slot(at: loc.pageOffset), slot.verified, let item = slot.item else { return nil }

                    // If verification changes the identity of a selected item that was known when the command began, abort.
                    if let knownID = knownItemIDsByOrdinal[loc.ordinal], knownID != item.id {
                        return nil
                    }

                    resolvedItemsByOrdinal[loc.ordinal] = (item, descriptor)
                }
            }
        }

        // Reject if index fingerprint is no longer current in the repository.
        let currentSnapshot = await repository.latestTimelineSnapshot(collection: collection)
        if let currentSnapshot, LibraryIndex(snapshot: currentSnapshot).fingerprint != expectedFingerprint {
            return nil
        }

        // Calculate target and affected subset using interaction contract.
        let resolvedList = selectedOrdinals.compactMap { resolvedItemsByOrdinal[$0] }
        guard resolvedList.count == selectedOrdinals.count else { return nil }

        let anyNonFavorite = resolvedList.contains { !$0.item.isFavorite }
        let targetFavorite = anyNonFavorite
        let affected = resolvedList.filter { $0.item.isFavorite != targetFavorite }

        var sectionsByID: [Int64: TimelineSection] = [:]
        var itemsByID: [Int64: PhotoItem] = [:]
        for entry in affected {
            sectionsByID[entry.item.id] = entry.section
            itemsByID[entry.item.id] = entry.item
        }

        return SelectionFavoriteAction(
            affectedIDs: affected.map(\.item.id),
            targetFavorite: targetFavorite,
            sectionsByID: sectionsByID,
            collection: collection,
            itemsByID: itemsByID,
            expectedTimelineFingerprint: expectedFingerprint
        )
    }
}
