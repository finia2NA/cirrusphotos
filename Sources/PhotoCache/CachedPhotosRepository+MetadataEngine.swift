import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    var personalMetadataNamespace: MetadataNamespace { MetadataNamespace(account: namespace, scope: .space(.personal)) }

    func metadataNamespace(for space: PhotoSpace) -> MetadataNamespace {
        MetadataNamespace(account: namespace, scope: .space(space))
    }

    func metadataNamespace(for collection: PhotoCollectionDescriptor) -> MetadataNamespace {
        let source = mediaCollection(for: collection)
        return MetadataNamespace(account: namespace, scope: source.contentScope)
    }

    /// Shared Space uses current-run authoritative collection reads. The Personal
    /// Diff cursor and inventory are never a freshness boundary for shared items.
    func reconcileMetadataSource(for collection: PhotoCollectionDescriptor) async throws {
        if mediaCollection(for: collection).contentScope != .space(.personal) { try await initializeMetadataEngine(); return }
        try await reconcileMetadataSource()
    }

    /// Enroll the normalized format only when its consumer pipeline is admitted.
    func initializeMetadataEngine() async throws {
        guard !metadata.initialized else { return }
        let epoch = metadata.admissionEpoch
        try await store.initializeMetadataStore()
        try requireAdmission(epoch)
        metadata.initialized = true
    }

    /// Every destination joins this source job. Unproven annotation/membership
    /// sources deliberately retain ordinary current-run authoritative reads.
    func reconcileMetadataSource(force: Bool = false) async throws {
        try await initializeMetadataEngine()
        if metadata.sourceUnavailable { return }
        if metadata.reconciled && !force { return }
        if let job = metadata.reconciliation { return try await job.value }
        metadata.reconciled = false
        let id = UUID()
        let epoch = metadata.admissionEpoch
        let job = Task<Void, Error> {
            defer {
                if metadata.reconciliationID == id {
                    metadata.reconciliation = nil
                    metadata.reconciliationID = nil
                }
            }
            try await connect()
            let admission = try await store.metadataAdmission(personalMetadataNamespace)
            let prior = try await store.metadataState(personalMetadataNamespace)
            do {
                guard let cursor = prior.cursor else {
                    let boundary = try await metadataSourceRequest { try await client.diffVersion() }
                    try requireMetadataEngineAdmission(epoch: epoch, id: id)
                    try await store.applyMetadataChanges(namespace: personalMetadataNamespace, cursor: boundary, replacements: [], deletedIDs: [], affectedDays: [],
                                                         invalidateAll: true, currentRun: runID, admission: admission)
                    let committed = try await store.metadataState(personalMetadataNamespace)
                    try requireMetadataEngineAdmission(epoch: epoch, id: id)
                    metadata.revision = committed.revision
                    metadata.reconciled = true
                    return
                }
                // Favorite events are read after the item feed from the same cursor, so they
                // cover at least the item interval; the fence below covers everything after it.
                let interval = try await metadataSourceRequest { try await client.changes(since: cursor) }
                let events = try await metadataSourceRequest { try await client.userEvents(since: cursor) }
                try requireMetadataEngineAdmission(epoch: epoch, id: id)
                guard interval.isBoundedTerminal, events.isBoundedTerminal else {
                    try await recoverMetadataSource(admission: admission, epoch: epoch, id: id)
                    return
                }
                if interval.isEmpty && events.isEmpty {
                    try await store.applyMetadataChanges(namespace: personalMetadataNamespace, cursor: interval.cursor, replacements: [], deletedIDs: [], affectedDays: [],
                                                         invalidateAll: false, proven: true, currentRun: runID, admission: admission)
                    let committed = try await store.metadataState(personalMetadataNamespace)
                    try requireMetadataEngineAdmission(epoch: epoch, id: id)
                    metadata.revision = committed.revision
                    metadata.reconciled = true
                    return
                }
                let old = try await store.metadataItemTimes(personalMetadataNamespace, ids: interval.modifiedItemIDs + interval.deletedItemIDs)
                var replacements: [PhotoItem] = []
                for start in stride(from: 0, to: interval.modifiedItemIDs.count, by: MetadataReadPlanner.lookupBatchSize) {
                    let end = min(start + MetadataReadPlanner.lookupBatchSize, interval.modifiedItemIDs.count)
                    let ids = Array(interval.modifiedItemIDs[start..<end])
                    let items = try await metadataSourceRequest { try await client.items(ids: ids, space: .personal) }
                    guard items.count == ids.count, Set(items.map(\.id)) == Set(ids) else {
                        try await recoverMetadataSource(admission: admission, epoch: epoch, id: id)
                        return
                    }
                    replacements.append(contentsOf: items)
                }
                let known = Set(old.map(\.id))
                let unknown = (interval.modifiedItemIDs + interval.deletedItemIDs).filter { !known.contains($0) }
                let referenced = try await store.metadataReferencedDays(personalMetadataNamespace, ids: unknown)
                let candidate = try MetadataChangeApplication.prepare(diff: interval, oldInventory: old,
                                                                      referencedDays: referenced, lookup: replacements)
                var favorites: [Int64: Bool] = [:]
                for event in events.favorites { for itemID in event.itemIDs { favorites[itemID] = event.favorite } }
                let favoriteDays = Set(try await store.metadataItemTimes(personalMetadataNamespace, ids: Array(favorites.keys))
                    .compactMap { try? CaptureDay(time: $0.time) })
                let fence = try await metadataSourceRequest { try await client.changes(since: interval.cursor) }
                let eventFence = try await metadataSourceRequest { try await client.userEvents(since: interval.cursor) }
                guard fence.isEmpty, eventFence.isEmpty else {
                    try await recoverMetadataSource(admission: admission, epoch: epoch, id: id)
                    return
                }
                try requireMetadataEngineAdmission(epoch: epoch, id: id)
                try await store.applyMetadataChanges(namespace: personalMetadataNamespace, cursor: fence.cursor,
                                                     replacements: candidate.replacements, deletedIDs: candidate.deletedIDs,
                                                     affectedDays: candidate.affectedDays, invalidateAll: candidate.invalidateAll,
                                                     favorites: favorites, proven: true, currentRun: runID, admission: admission)
                let committed = try await store.metadataState(personalMetadataNamespace)
                try requireMetadataEngineAdmission(epoch: epoch, id: id)
                metadata.revision = committed.revision
                metadata.reconciled = true
                let unknownFavorite = favoriteDays.count < favorites.count
                publishMetadataInvalidation(days: candidate.invalidateAll || unknownFavorite ? nil : candidate.affectedDays.union(favoriteDays))
                publishLocationItemChanges(candidate.replacements, deletedIDs: candidate.deletedIDs, coverageChanged: true)
            } catch {
                try requireMetadataEngineAdmission(epoch: epoch, id: id)
                if let api = error as? SynologyAPIError {
                    switch api {
                    case .api(let code) where [102, 103, 104, 105].contains(code):
                        try await disableMetadataSource(admission: admission, epoch: epoch, id: id)
                    case .api(700), .invalidResponse, .responseTooLarge:
                        try await recoverMetadataSource(admission: admission, epoch: epoch, id: id)
                    default: throw error
                    }
                } else if error is DecodingError || error is CollectionCatalogError {
                    try await recoverMetadataSource(admission: admission, epoch: epoch, id: id)
                } else { throw error }
            }
        }
        metadata.reconciliationID = id
        metadata.reconciliation = job
        try await job.value
    }

    private func metadataSourceRequest<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await gate.acquire(.metadata, priority: .visible, id: id)
        do {
            let value = try await operation()
            await gate.release(.metadata)
            return value
        } catch {
            await gate.release(.metadata)
            throw error
        }
    }
    private func disableMetadataSource(admission: MetadataStoreAdmission, epoch: UInt64, id: UUID) async throws {
        try requireMetadataEngineAdmission(epoch: epoch, id: id)
        try await store.applyMetadataChanges(namespace: personalMetadataNamespace, cursor: nil, replacements: [], deletedIDs: [], affectedDays: [],
                                             invalidateAll: true, currentRun: runID, admission: admission)
        let committed = try await store.metadataState(personalMetadataNamespace)
        try requireMetadataEngineAdmission(epoch: epoch, id: id)
        metadata.revision = committed.revision
        metadata.sourceUnavailable = true
        publishMetadataInvalidation()
        await publishStoredLocationProjection()
    }

    private func requireMetadataEngineAdmission(epoch: UInt64, id: UUID) throws {
        guard isAdmitted(epoch),
              metadata.reconciliationID == id, !Task.isCancelled else { throw MetadataAdmissionError.superseded }
    }
    private func recoverMetadataSource(admission: MetadataStoreAdmission, epoch: UInt64, id: UUID) async throws {
        let fresh: DiffCursor
        do { fresh = try await metadataSourceRequest { try await client.diffVersion() } }
        catch {
            try requireMetadataEngineAdmission(epoch: epoch, id: id)
            // A rejected interval has already lost its authority. Failure to obtain
            // a fresh boundary must not preserve its old complete-inventory proof.
            try await disableMetadataSource(admission: admission, epoch: epoch, id: id)
            return
        }
        try requireMetadataEngineAdmission(epoch: epoch, id: id)
        try await store.applyMetadataChanges(namespace: personalMetadataNamespace, cursor: fresh, replacements: [], deletedIDs: [], affectedDays: [],
                                             invalidateAll: true, currentRun: runID, admission: admission)
        let committed = try await store.metadataState(personalMetadataNamespace)
        try requireMetadataEngineAdmission(epoch: epoch, id: id)
        metadata.revision = committed.revision
        metadata.reconciled = true
        publishMetadataInvalidation()
        await publishStoredLocationProjection()
    }

    /// Complete Personal inventory acquisition is a shared engine operation, not
    /// a Map synchronization path. SQL staging keeps all non-geotagged IDs too.
    func buildMetadataInventory(token: MetadataWorkToken, id: UUID) async throws -> [PhotoLocationRecord] {
            try await reconcileMetadataSource(force: true)
            _ = try await verifiedTimelineSnapshot(collection: .library(.personal))
            let admission = try await store.metadataAdmission(personalMetadataNamespace)
            let prior = try await store.metadataState(personalMetadataNamespace)
            guard let catalog = try await store.metadataCatalog(CollectionKey(namespace: personalMetadataNamespace, collection: .library(.personal)))?.catalog else { throw CollectionCatalogError.invalidCoverage }
            let total = catalog.itemCount
            var scanned = 0
            do {
                for page in 0..<Self.locationScanPageCap {
                    let items = try await metadataReadRequest(priority: .prefetch, id: id) {
                        try await client.readPersonalInventoryBatch(offset: page * Self.locationScanPageLimit, limit: Self.locationScanPageLimit)
                    }
                    guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
                    guard items.count <= Self.locationScanPageLimit, items.count <= total - scanned else { throw CollectionCatalogError.invalidCoverage }
                    try await store.stageMetadataInventory(items, job: id, namespace: personalMetadataNamespace, admission: admission)
                    scanned += items.count
                    publishLocationIndexProgress(scanned: scanned, total: total)
                    if items.count < Self.locationScanPageLimit {
                        guard scanned == total else { throw CollectionCatalogError.invalidCoverage }
                        var fenceCursor = prior.cursor
                        if let cursor = prior.cursor, !metadata.sourceUnavailable {
                            // Advancing the shared cursor must not skip favorite events.
                            let fence = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.changes(since: cursor) }
                            let eventFence = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.userEvents(since: cursor) }
                            guard fence.isEmpty, eventFence.isEmpty else {
                                let boundary = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.diffVersion() }
                                try await store.applyMetadataChanges(namespace: personalMetadataNamespace, cursor: boundary, replacements: [], deletedIDs: [], affectedDays: [],
                                                                     invalidateAll: true, currentRun: runID, admission: admission)
                                throw CollectionCatalogError.invalidCoverage
                            }
                            fenceCursor = fence.cursor
                        }
                        guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
                        try await store.commitMetadataInventory(id, namespace: personalMetadataNamespace, catalog: catalog, cursor: fenceCursor, admission: admission)
                        guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
                        let projection = try await store.metadataLocationProjection(personalMetadataNamespace, currentOnly: true)
                        guard projection.state.inventoryComplete, projection.state.resetEpoch == admission.resetEpoch else {
                            metadata.inventoryCurrent = false
                            throw CollectionCatalogError.invalidCoverage
                        }
                        metadata.inventoryCurrent = true
                        await publishStoredLocationProjection()
                        return projection.records
                    }
                }
                throw CollectionCatalogError.exceedsLimit
            } catch {
                try? await store.discardMetadataInventoryStage(id)
                throw error
            }
    }

}
