import Foundation
import SynologyAPI

public struct MapFilterRegistration: Sendable {
    public let descriptor: PhotoCollectionDescriptor
    public let snapshot: TimelineSnapshot
}

extension CachedPhotosRepository {
    /// Maximum session pages retained per map filter.
    static let mapFilterPageCacheLimit = 12

    /// Registers a session-only filtered collection. `itemIDsBySection` must be
    /// parallel to `snapshot.sections`.
    /// Atomically validates the selected location revision, constructs the derived
    /// collection, and registers its dependencies inside the repository.
    public func registerMapFilter(itemIDs: [Int64],
                                  locationRevision: LocationIndexRevision) throws -> MapFilterRegistration {
        guard locationRevision.rawValue == metadata.locationRevision else {
            throw SynologyAPIError.unsupported("The map changed before this location opened. Try again.")
        }
        guard Set(itemIDs).count == itemIDs.count else {
            throw SynologyAPIError.unsupported("The selected map photos contain duplicate IDs.")
        }
        let records = itemIDs.compactMap { metadata.locationRecords[$0] }
        guard records.count == itemIDs.count else {
            throw SynologyAPIError.unsupported("Some selected map photos are no longer available.")
        }
        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let built = DayGroupedTimelineBuilder.build(
            entries: records.map { DayTimelineEntry(id: $0.id, time: $0.time) },
            sectionLimit: 250
        )
        try registerMapFilter(descriptor, source: .personalLibrary,
                              snapshot: built.snapshot,
                              itemIDsBySection: built.itemIDsBySection,
                              locationRevision: locationRevision.rawValue)
        return MapFilterRegistration(descriptor: descriptor, snapshot: built.snapshot)
    }

    func registerMapFilter(_ descriptor: PhotoCollectionDescriptor,
                           source: PhotoCollectionDescriptor,
                           snapshot: TimelineSnapshot,
                           itemIDsBySection: [[Int64]],
                           locationRevision: UInt64? = nil) throws {
        guard let filterID = descriptor.mapFilterID else {
            throw SynologyAPIError.unsupported("A map filter collection descriptor is required.")
        }
        guard source == .personalLibrary else {
            throw SynologyAPIError.unsupported("Map filters require the Personal Library source.")
        }
        guard itemIDsBySection.count == snapshot.sections.count else {
            throw SynologyAPIError.unsupported("A map filter snapshot does not match its item IDs.")
        }
        var idsBySection: [TimelineSection: [Int64]] = [:]
        for (section, ids) in zip(snapshot.sections, itemIDsBySection) {
            idsBySection[section] = ids
        }
        guard !metadata.resetInProgress else { throw MetadataAdmissionError.resetInProgress }
        metadata.mapFilters[filterID] = MapFilterState(registrationID: UUID(),
                                                       metadataEpoch: metadata.admissionEpoch,
                                                       locationRevision: locationRevision,
                                                       source: source, snapshot: snapshot,
                                                       itemIDsBySection: itemIDsBySection,
                                                       idsBySection: idsBySection)
        metadata.latestTimelines[descriptor] = snapshot
    }

    public func unregisterMapFilter(_ descriptor: PhotoCollectionDescriptor) {
        guard let filterID = descriptor.mapFilterID,
              let state = metadata.mapFilters.removeValue(forKey: filterID) else { return }
        for section in state.snapshot.sections {
            guard let key = CacheKey.page(namespace: namespace, section: section,
                                          collection: descriptor) else { continue }
            metadata.mapFilterPages.removeValue(forKey: key)
            metadata.mapFilterPageOrder.removeAll(where: { $0 == key })
        }
        metadata.latestTimelines.removeValue(forKey: descriptor)
        metadata.mutationEpochs.removeValue(forKey: descriptor)
        cancelIdleLogin()
    }

    /// A filtered page is built from the complete Personal Library timeline pages
    /// covering its day. Fetching complete pages keeps the persistent timeline cache
    /// behind the filter and avoids a second, ID-addressed transport path: the normal
    /// `page(_:collection:)` pipeline handles cached-first delivery, once-per-run
    /// validation, request sharing, and persistence, and this method only filters the
    /// resulting items down to the section's registered IDs.
    func mapFilterPage(_ section: TimelineSection,
                       collection: PhotoCollectionDescriptor,
                       allowNetwork: Bool,
                       priority: RequestPriority) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        let producer = StreamProducer()
        let key = CacheKey.page(namespace: namespace, section: section, collection: collection)
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard let filterID = collection.mapFilterID,
                      let state = metadata.mapFilters[filterID] else {
                    continuation.yield(.failure("This location filter is no longer available."))
                    continuation.finish()
                    return
                }
                guard let key else {
                    continuation.yield(.failure("The section has no date bounds."))
                    continuation.finish()
                    return
                }
                guard let ids = state.idsBySection[section] else {
                    continuation.yield(.failure("This section is no longer part of the location filter."))
                    continuation.finish()
                    return
                }
                if let cached = metadata.mapFilterPages[key] {
                    touchMapFilterPage(key)
                    continuation.yield(.value(favorites.applyingOverrides(cached), verified: true))
                    continuation.finish()
                    return
                }
                let candidates = personalSections(covering: section)
                guard !candidates.isEmpty else {
                    continuation.yield(.failure("No Personal Library timeline section covers this day."))
                    continuation.finish()
                    return
                }
                let wanted = Set(ids)
                let registrationID = state.registrationID
                let metadataEpoch = state.metadataEpoch
                var contributions: [TimelineSection: (items: [PhotoItem], verified: Bool)] = [:]
                var failureMessage: String?

                func registrationIsCurrent() -> Bool {
                    guard metadata.admissionEpoch == metadataEpoch else { return false }
                    guard metadata.mapFilters[filterID]?.registrationID == registrationID else { return false }
                    if let sourceRevision = state.locationRevision {
                        return sourceRevision == metadata.locationRevision
                    }
                    return true
                }

                func assembledValue() -> (items: [PhotoItem], verified: Bool)? {
                    guard !contributions.isEmpty else { return nil }
                    var byID: [Int64: PhotoItem] = [:]
                    for contribution in contributions.values {
                        for item in contribution.items where wanted.contains(item.id) {
                            byID[item.id] = item
                        }
                    }
                    let current = favorites.applyingOverrides(ids.compactMap { byID[$0] })
                    let allSourcesResolved = contributions.count == candidates.count
                    let allSourcesVerified = allSourcesResolved && contributions.values.allSatisfy(\.verified)
                    return (current, allSourcesVerified && current.count == ids.count)
                }

                // Cache-only pass: visit every covering source section before any
                // network-backed stream can suspend. This makes cached filtered data
                // useful immediately even when the first section's validation is slow.
                for candidate in candidates {
                    if Task.isCancelled { continuation.finish(); return }
                    var latest: (items: [PhotoItem], verified: Bool)?
                    for await event in page(candidate, collection: .personalLibrary,
                                            allowNetwork: false, priority: priority) {
                        if Task.isCancelled { break }
                        switch event {
                        case .value(let items, let verified):
                            latest = (items, verified)
                        case .failure(let message):
                            if failureMessage == nil { failureMessage = message }
                        }
                    }
                    guard !Task.isCancelled, registrationIsCurrent() else {
                        continuation.finish(); return
                    }
                    if let latest { contributions[candidate] = latest }
                }

                if let cached = assembledValue() {
                    if cached.verified { insertMapFilterPage(cached.items, key: key) }
                    continuation.yield(.value(cached.items, verified: cached.verified))
                    if cached.verified || !allowNetwork {
                        if let failureMessage { continuation.yield(.failure(failureMessage)) }
                        continuation.finish()
                        return
                    }
                } else if !allowNetwork {
                    if let failureMessage { continuation.yield(.failure(failureMessage)) }
                    continuation.finish()
                    return
                }

                // Authoritative pass: replace each source contribution with the
                // latest ordinary page result. Never append a second copy of a cached
                // contribution when that stream later emits its validated value.
                for candidate in candidates {
                    if Task.isCancelled { continuation.finish(); return }
                    var latest: (items: [PhotoItem], verified: Bool)?
                    for await event in page(candidate, collection: .personalLibrary,
                                            allowNetwork: true, priority: priority) {
                        if Task.isCancelled { break }
                        switch event {
                        case .value(let items, let verified): latest = (items, verified)
                        case .failure(let message):
                            if failureMessage == nil { failureMessage = message }
                        }
                    }
                    guard !Task.isCancelled, registrationIsCurrent() else {
                        continuation.finish(); return
                    }
                    if let latest { contributions[candidate] = latest }
                }

                if let current = assembledValue() {
                    if current.verified { insertMapFilterPage(current.items, key: key) }
                    continuation.yield(.value(current.items, verified: current.verified))
                }
                if let failureMessage {
                    continuation.yield(.failure(failureMessage))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
            }
        }
    }

    /// The Personal Library sections whose date bounds overlap the filtered section's
    /// day. Membership is matched later by item ID, so a stale timeline snapshot can
    /// only cause misses, never a wrong item.
    func personalSections(covering section: TimelineSection) -> [TimelineSection] {
        guard let bounds = section.dateBounds,
              let snapshot = metadata.latestTimelines[.personalLibrary] else { return [] }
        return snapshot.sections.filter { candidate in
            guard let candidateBounds = candidate.dateBounds else { return false }
            return candidateBounds.start <= bounds.end && candidateBounds.end >= bounds.start
        }
    }

    private func insertMapFilterPage(_ items: [PhotoItem], key: String) {
        if metadata.mapFilterPages.updateValue(items, forKey: key) == nil {
            metadata.mapFilterPageOrder.append(key)
        }
        while metadata.mapFilterPageOrder.count > Self.mapFilterPageCacheLimit {
            let evicted = metadata.mapFilterPageOrder.removeFirst()
            metadata.mapFilterPages.removeValue(forKey: evicted)
        }
    }

    private func touchMapFilterPage(_ key: String) {
        guard let index = metadata.mapFilterPageOrder.firstIndex(of: key) else { return }
        metadata.mapFilterPageOrder.remove(at: index)
        metadata.mapFilterPageOrder.append(key)
    }

    func invalidateMapFiltersForLocationChange() {
        let descriptors = metadata.mapFilters.keys.map(PhotoCollectionDescriptor.mapFilter)
        for descriptor in descriptors { unregisterMapFilter(descriptor) }
    }
}
