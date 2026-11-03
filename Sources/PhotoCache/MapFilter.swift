import Foundation
import SynologyAPI

public struct MapFilterRegistration: Sendable {
    public let descriptor: PhotoCollectionDescriptor
    public let snapshot: TimelineSnapshot
    public let authority: PhotoSelectionAuthority
}

extension CachedPhotosRepository {
    /// Session collection invalidations caused by a semantic replacement of the
    /// location index. Consumers receive the collection identity, never its cache
    /// revision or validation strategy.
    public func mapFilterInvalidations() -> AsyncStream<PhotoCollectionDescriptor> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            metadata.sessions.mapFilterInvalidationObservers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeMapFilterInvalidationObserver(id) }
            }
        }
    }

    /// Registers a session-only filtered collection. `itemIDsBySection` must be
    /// parallel to `snapshot.sections`.
    /// Atomically validates the selected location revision, constructs the derived
    /// collection, and registers its dependencies inside the repository.
    public func registerMapFilter(itemIDs: [Int64],
                                  locationRevision: LocationIndexRevision) throws -> MapFilterRegistration {
        let space = locationRevision.space
        let revision = space == .shared ? metadata.sharedLocations.revision : metadata.locations.revision
        let locationRecords = space == .shared ? metadata.sharedLocations.records : metadata.locations.records
        guard locationRevision.rawValue == revision else {
            throw RepositoryError.stale("The map changed before this location opened. Try again.")
        }
        guard Set(itemIDs).count == itemIDs.count else {
            throw RepositoryError.unexpected("The selected map photos contain duplicate IDs.")
        }
        let records = itemIDs.compactMap { locationRecords[$0] }
        guard records.count == itemIDs.count else {
            throw RepositoryError.stale("Some selected map photos are no longer available.")
        }
        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID(), space: space)
        let built = DayGroupedTimelineBuilder.build(
            entries: records.map { DayTimelineEntry(id: $0.id, time: $0.time) },
            sectionLimit: 250
        )
        try storeMapFilter(descriptor, snapshot: built.snapshot,
                              itemIDsBySection: built.itemIDsBySection,
                              locationRevision: locationRevision.rawValue, space: space)
        return MapFilterRegistration(descriptor: descriptor, snapshot: built.snapshot,
                                     authority: selectionAuthority(collection: descriptor, snapshot: built.snapshot)!)
    }

    private func storeMapFilter(_ descriptor: PhotoCollectionDescriptor,
                           snapshot: TimelineSnapshot,
                           itemIDsBySection: [[Int64]],
                           locationRevision: UInt64, space: PhotoSpace) throws {
        guard let filterID = descriptor.mapFilterID, descriptor.space == space else {
            throw RepositoryError.unexpected("A map filter collection descriptor is required.")
        }
        guard itemIDsBySection.count == snapshot.sections.count else {
            throw RepositoryError.unexpected("A map filter snapshot does not match its item IDs.")
        }
        var idsBySection: [TimelineSection: [Int64]] = [:]
        for (section, ids) in zip(snapshot.sections, itemIDsBySection) {
            idsBySection[section] = ids
        }
        guard !metadata.resetInProgress else { throw MetadataAdmissionError.resetInProgress }
        installSelectionRetention(descriptor)
        metadata.sessions.mapFilters[filterID] = MapFilterState(space: space, registrationID: UUID(),
                                                       metadataEpoch: metadata.admissionEpoch,
                                                       locationRevision: locationRevision,
                                                       snapshot: snapshot,
                                                       itemIDsBySection: itemIDsBySection,
                                                       idsBySection: idsBySection)
        metadata.latestTimelines[descriptor] = snapshot
    }

    public func unregisterMapFilter(_ descriptor: PhotoCollectionDescriptor) {
        if deferSelectionUnregister(descriptor) { return }
        removeMapFilter(descriptor)
    }

    func removeMapFilter(_ descriptor: PhotoCollectionDescriptor) {
        guard let filterID = descriptor.mapFilterID,
              metadata.sessions.mapFilters.removeValue(forKey: filterID) != nil else { return }
        metadata.sessions.selectionRetentions.removeValue(forKey: descriptor)
        metadata.latestTimelines.removeValue(forKey: descriptor)
        metadata.sessions.filterCatalogs.removeValue(forKey: descriptor)
        metadata.mutationEpochs.removeValue(forKey: descriptor)
        cancelIdleLogin()
    }

    /// Explicit session membership materializes from the common canonical rows;
    /// an isolated pin never fetches every logical page of a large day.
    func mapFilterPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                       allowNetwork: Bool, priority: RequestPriority) -> AsyncStream<ResourceEvent<PhotoPageSnapshot>> {
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let subscriber = UUID()
                metadata.directSubscribers.insert(subscriber)
                defer { metadata.directSubscribers.remove(subscriber); cancelIdleLogin() }
                do {
                    try await initializeMetadataEngine()
                    guard let filterID = collection.mapFilterID, let state = metadata.sessions.mapFilters[filterID],
                          let ids = state.idsBySection[section] else { throw RepositoryError.stale("This location filter is no longer available.") }
                    let source = PhotoCollectionDescriptor.library(state.space)
                    let scopedNamespace = metadataNamespace(for: source)
                    let address = try DayPageAddress(section: section, collection: collection)
                    func current() -> Bool {
                        guard !Task.isCancelled, metadata.admissionEpoch == state.metadataEpoch,
                              metadata.sessions.mapFilters[filterID]?.registrationID == state.registrationID else { return false }
                        return true
                    }
                    func snapshot(_ details: [Int64: PhotoItemSlot]) -> PhotoPageSnapshot {
                        let slots = ids.map { id -> PhotoItemSlot in
                            guard let detail = details[id] else { return PhotoItemSlot(itemID: id, item: nil, verified: false) }
                            return detail
                        }
                        return PhotoPageSnapshot(address: address, membershipRevision: state.locationRevision,
                                                 membershipVerified: true, slots: slots)
                    }
                    let cached = try await store.metadataDetails(scopedNamespace, ids: ids, currentRun: runID)
                    guard current() else { continuation.finish(); return }
                    let initial = snapshot(cached)
                    if !cached.isEmpty { continuation.yield(.value(applyingFavoriteOverrides(initial, collection: source), verified: initial.verified)) }
                    guard allowNetwork && !initial.verified else { continuation.finish(); return }
                    try await connect()
                    try await reconcileMetadataSource(for: source)
                    guard current() else { continuation.finish(); return }
                    _ = try await resolveMetadataItems(ids, priority: priority, collection: source)
                    guard current() else { continuation.finish(); return }
                    let result = snapshot(try await store.metadataDetails(scopedNamespace, ids: ids, currentRun: runID))
                    continuation.yield(.value(applyingFavoriteOverrides(result, collection: source), verified: result.verified))
                } catch {
                    if !Task.isCancelled { continuation.yield(.failure(RepositoryError.record(error, operation: "Map filter page"))) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    func invalidateMapFiltersForLocationChange(space: PhotoSpace) {
        let descriptors = metadata.sessions.mapFilters.filter { $0.value.space == space }.map { PhotoCollectionDescriptor.mapFilter($0.key, space: $0.value.space) }
        for descriptor in descriptors {
            removeMapFilter(descriptor)
            for observer in metadata.sessions.mapFilterInvalidationObservers.values {
                observer.yield(descriptor)
            }
        }
    }

    private func removeMapFilterInvalidationObserver(_ id: UUID) {
        metadata.sessions.mapFilterInvalidationObservers.removeValue(forKey: id)
    }
}
