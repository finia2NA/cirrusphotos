import Foundation
import OSLog
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

    /// Each space reconciles its own Diff feed. An owned album has no feed of its own, but the
    /// space feeds keep its copies current (`MetadataStore.contentProven`), so its reads wait for
    /// Personal reconciliation, and for Shared when this account has a Shared cursor. A failed
    /// reconciliation only withholds the proof; the album is then read as before. Incoming
    /// albums keep current-run authoritative reads.
    func reconcileMetadataSource(for collection: PhotoCollectionDescriptor) async throws {
        switch mediaCollection(for: collection).contentScope {
        case .space(let space):
            try await reconcileMetadataSource(space: space)
        case .album:
            try await initializeMetadataEngine()
            try? await reconcileMetadataSource(space: .personal)
            if (try? await store.metadataState(metadataNamespace(for: .shared)))?.cursor != nil {
                try? await reconcileMetadataSource(space: .shared)
            }
        case .incomingAlbum:
            try await initializeMetadataEngine()
        }
    }

    /// Enroll the normalized format only when its consumer pipeline is admitted.
    func initializeMetadataEngine() async throws {
        guard !metadata.initialized else { return }
        if let pending = metadata.initialization { return try await pending.task.value }
        let id = UUID()
        let epoch = metadata.admissionEpoch
        let task = Task<Void, Error> {
            defer { if metadata.initialization?.id == id { metadata.initialization = nil } }
            try await store.initializeMetadataStore()
            try requireAdmission(epoch)
            metadata.initialized = true
            for space in PhotoSpace.allCases {
                guard let state = try? await store.metadataState(metadataNamespace(for: space)) else { continue }
                SynologyDiagnostics.diff.notice("\(space.rawValue, privacy: .public) stored at launch: inventoryComplete=\(state.inventoryComplete, privacy: .public) cursor=\(state.cursor != nil, privacy: .public)")
            }
        }
        metadata.initialization = (id, task)
        try await task.value
    }

    /// Every destination of a space joins this source job. Personal Space also reads the
    /// favorite-event feed; Shared Space has none, so Shared Favorites keep per-run reads.
    func reconcileMetadataSource(space: PhotoSpace = .personal, force: Bool = false) async throws {
        try await initializeMetadataEngine()
        if metadata[source: space].sourceUnavailable { return }
        if metadata[source: space].reconciled && !force { return }
        if let job = metadata[source: space].reconciliation { return try await job.value }
        metadata[source: space].reconciled = false
        let id = UUID()
        let epoch = metadata.admissionEpoch
        let namespace = metadataNamespace(for: space)
        let job = Task<Void, Error> {
            defer {
                if metadata[source: space].reconciliationID == id {
                    metadata[source: space].reconciliation = nil
                    metadata[source: space].reconciliationID = nil
                }
            }
            try await connect()
            let admission = try await store.metadataAdmission(namespace)
            let prior = try await store.metadataState(namespace)
            func events(since cursor: DiffCursor) async throws -> UserEventDiff {
                guard space == .personal else { return UserEventDiff(cursor: cursor, favorites: []) }
                return try await metadataSourceRequest { try await client.userEvents(since: cursor) }
            }
            do {
                guard let cursor = prior.cursor else {
                    SynologyDiagnostics.diff.notice("\(space.rawValue, privacy: .public) has no stored cursor; starting a new reset epoch")
                    let boundary = try await metadataSourceRequest { try await client.diffVersion(space: space) }
                    try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
                    try await store.applyMetadataChanges(namespace: namespace, cursor: boundary, replacements: [], deletedIDs: [], affectedDays: [],
                                                         invalidateAll: true, currentRun: runID, admission: admission)
                    try await finishReconciliation(space, namespace: namespace, epoch: epoch, id: id)
                    return
                }
                // Favorite events are read after the item feed from the same cursor, so they
                // cover at least the item interval; the fence below covers everything after it.
                let interval = try await metadataSourceRequest { try await client.changes(since: cursor, space: space) }
                let favoriteEvents = try await events(since: cursor)
                try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
                guard interval.isBoundedTerminal, favoriteEvents.isBoundedTerminal else {
                    try await recoverMetadataSource(space, reason: "interval not bounded and terminal: items \(interval.summary) events \(favoriteEvents.summary)",
                                                    admission: admission, epoch: epoch, id: id)
                    return
                }
                if interval.isEmpty && favoriteEvents.isEmpty {
                    try await store.applyMetadataChanges(namespace: namespace, cursor: interval.cursor, replacements: [], deletedIDs: [], affectedDays: [],
                                                         invalidateAll: false, proven: true, currentRun: runID, admission: admission)
                    try await finishReconciliation(space, namespace: namespace, epoch: epoch, id: id)
                    return
                }
                let modified = Set(interval.modifiedItemIDs)
                let lookupIDs = interval.modifiedItemIDs + interval.mergedItemIDs
                let old = try await store.metadataItemTimes(namespace, ids: lookupIDs + interval.deletedItemIDs)
                var replacements: [PhotoItem] = []
                for start in stride(from: 0, to: lookupIDs.count, by: MetadataReadPlanner.lookupBatchSize) {
                    let ids = Array(lookupIDs[start..<min(start + MetadataReadPlanner.lookupBatchSize, lookupIDs.count)])
                    let items = try await metadataSourceRequest { try await client.items(ids: ids, space: space) }
                    let returned = Set(items.map(\.id))
                    // Every modified item must exist; a merged ID may already be gone.
                    let required = ids.filter(modified.contains)
                    guard items.count == returned.count, returned.isSubset(of: ids), required.allSatisfy(returned.contains) else {
                        try await recoverMetadataSource(space, reason: "item lookup returned \(returned.intersection(required).count) of \(required.count) modified items",
                                                        admission: admission, epoch: epoch, id: id)
                        return
                    }
                    replacements.append(contentsOf: items)
                }
                // A merged ID that still exists is a replacement; one that is gone is a deletion.
                let returned = Set(replacements.map(\.id))
                let applied = PhotoDiff(cursor: interval.cursor, modifiedItemIDs: lookupIDs.filter(returned.contains),
                                        deletedItemIDs: interval.deletedItemIDs + interval.mergedItemIDs.filter { !returned.contains($0) })
                let known = Set(old.map(\.id))
                let unknown = (applied.modifiedItemIDs + applied.deletedItemIDs).filter { !known.contains($0) }
                let referenced = try await store.metadataReferencedDays(namespace, ids: unknown)
                let candidate = try MetadataChangeApplication.prepare(diff: applied, oldInventory: old,
                                                                      referencedDays: referenced, lookup: replacements)
                var favorites: [Int64: Bool] = [:]
                for event in favoriteEvents.favorites { for itemID in event.itemIDs { favorites[itemID] = event.favorite } }
                let favoriteDays = Set(try await store.metadataItemTimes(namespace, ids: Array(favorites.keys))
                    .compactMap { try? CaptureDay(time: $0.time) })
                let fence = try await metadataSourceRequest { try await client.changes(since: interval.cursor, space: space) }
                let eventFence = try await events(since: interval.cursor)
                guard fence.isEmpty, eventFence.isEmpty else {
                    try await recoverMetadataSource(space, reason: "changes arrived while applying: items \(fence.summary) events \(eventFence.summary)",
                                                    admission: admission, epoch: epoch, id: id)
                    return
                }
                try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
                try await store.applyMetadataChanges(namespace: namespace, cursor: fence.cursor,
                                                     replacements: candidate.replacements, deletedIDs: candidate.deletedIDs,
                                                     affectedDays: candidate.affectedDays, invalidateAll: candidate.invalidateAll,
                                                     favorites: favorites, proven: true, currentRun: runID, admission: admission)
                try await finishReconciliation(space, namespace: namespace, epoch: epoch, id: id)
                SynologyDiagnostics.diff.info("\(space.rawValue, privacy: .public) applied items \(interval.summary, privacy: .public) events \(favoriteEvents.summary, privacy: .public)")
                let unknownFavorite = favoriteDays.count < favorites.count
                publishMetadataInvalidation(space: space, days: candidate.invalidateAll || unknownFavorite ? nil : candidate.affectedDays.union(favoriteDays))
                await publishLocationChanges(space, items: candidate.replacements, deletedIDs: candidate.deletedIDs)
                if !interval.mergedItemIDs.isEmpty {
                    try await verifyInventoryCount(space, namespace: namespace, epoch: epoch, id: id)
                }
            } catch {
                try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
                if let api = error as? SynologyAPIError {
                    switch api {
                    case .api(let code) where [102, 103, 104, 105].contains(code):
                        try await disableMetadataSource(space, reason: "feed rejected with API error \(code)", admission: admission, epoch: epoch, id: id)
                    case .api(700), .invalidResponse, .responseTooLarge:
                        try await recoverMetadataSource(space, reason: "feed read failed: \(api.logSummary)", admission: admission, epoch: epoch, id: id)
                    default: throw error
                    }
                } else if error is DecodingError || error is CollectionCatalogError {
                    try await recoverMetadataSource(space, reason: "feed could not be applied: \(error.logSummary)", admission: admission, epoch: epoch, id: id)
                } else { throw error }
            }
        }
        metadata[source: space].reconciliationID = id
        metadata[source: space].reconciliation = job
        try await job.value
    }

    /// The meaning of `item.merge` is inferred from Live Photo additions, so after applying
    /// one a complete inventory must still match the library's item count. A mismatch,
    /// such as an absorbed item the feed did not name, falls back to a reset.
    private func verifyInventoryCount(_ space: PhotoSpace, namespace: MetadataNamespace, epoch: UInt64, id: UUID) async throws {
        guard let stored = try await store.metadataCompleteInventoryCount(namespace) else { return }
        let catalog = try await metadataSourceRequest { try await client.collectionDayCatalog(collection: .library(space), initial: false) }
        try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
        guard catalog.completeness != .complete || catalog.itemCount != stored else { return }
        let admission = try await store.metadataAdmission(namespace)
        try await recoverMetadataSource(space, reason: "inventory holds \(stored) items after a merge but the library lists \(catalog.itemCount)",
                                        admission: admission, epoch: epoch, id: id)
    }

    /// The space's Diff feed was applied this run, so stored content is current.
    func metadataSourceCurrent(_ space: PhotoSpace) -> Bool {
        metadata[source: space].reconciled && !metadata[source: space].sourceUnavailable
    }

    private func finishReconciliation(_ space: PhotoSpace, namespace: MetadataNamespace, epoch: UInt64, id: UUID) async throws {
        let committed = try await store.metadataState(namespace)
        try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
        metadata[source: space].revision = committed.revision
        metadata[source: space].reconciled = true
    }

    /// Item replacements and deletions reach the space's location projection.
    func publishLocationChanges(_ space: PhotoSpace, items: [PhotoItem], deletedIDs: [Int64] = [], coverageChanged: Bool = true) async {
        if space == .shared { await publishSharedLocationItemChanges(items, deletedIDs: deletedIDs) }
        else { publishLocationItemChanges(items, deletedIDs: deletedIDs, coverageChanged: coverageChanged) }
    }

    private func publishStoredLocations(_ space: PhotoSpace) async {
        if space == .shared { await publishSharedLocationItemChanges([]) } else { await publishStoredLocationProjection() }
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
    private func disableMetadataSource(_ space: PhotoSpace, reason: String, admission: MetadataStoreAdmission, epoch: UInt64, id: UUID) async throws {
        SynologyDiagnostics.diff.notice("\(space.rawValue, privacy: .public) Diff disabled for this run, cached metadata invalidated: \(reason, privacy: .public)")
        let namespace = metadataNamespace(for: space)
        try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
        try await store.applyMetadataChanges(namespace: namespace, cursor: nil, replacements: [], deletedIDs: [], affectedDays: [],
                                             invalidateAll: true, currentRun: runID, admission: admission)
        let committed = try await store.metadataState(namespace)
        try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
        metadata[source: space].revision = committed.revision
        metadata[source: space].sourceUnavailable = true
        publishMetadataInvalidation(space: space)
        await publishStoredLocations(space)
    }

    private func requireMetadataEngineAdmission(_ space: PhotoSpace, epoch: UInt64, id: UUID) throws {
        guard isAdmitted(epoch),
              metadata[source: space].reconciliationID == id, !Task.isCancelled else { throw MetadataAdmissionError.superseded }
    }
    /// Every recovery invalidates all cached metadata of the space, including its complete
    /// inventory, so the next Map open rescans the whole space.
    private func recoverMetadataSource(_ space: PhotoSpace, reason: String, admission: MetadataStoreAdmission, epoch: UInt64, id: UUID) async throws {
        SynologyDiagnostics.diff.notice("\(space.rawValue, privacy: .public) Diff reset, cached metadata invalidated: \(reason, privacy: .public)")
        let fresh: DiffCursor
        do { fresh = try await metadataSourceRequest { try await client.diffVersion(space: space) } }
        catch {
            try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
            // A rejected interval has already lost its authority. Failure to obtain
            // a fresh boundary must not preserve its old complete-inventory proof.
            try await disableMetadataSource(space, reason: "no fresh cursor after rejecting the interval: \(error.logSummary)", admission: admission, epoch: epoch, id: id)
            return
        }
        try requireMetadataEngineAdmission(space, epoch: epoch, id: id)
        try await store.applyMetadataChanges(namespace: metadataNamespace(for: space), cursor: fresh, replacements: [], deletedIDs: [], affectedDays: [],
                                             invalidateAll: true, currentRun: runID, admission: admission)
        try await finishReconciliation(space, namespace: metadataNamespace(for: space), epoch: epoch, id: id)
        publishMetadataInvalidation(space: space)
        await publishStoredLocations(space)
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
                        if let cursor = prior.cursor, !metadata[source: .personal].sourceUnavailable {
                            // Advancing the shared cursor must not skip favorite events.
                            let fence = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.changes(since: cursor, space: .personal) }
                            let eventFence = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.userEvents(since: cursor) }
                            guard fence.isEmpty, eventFence.isEmpty else {
                                let boundary = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.diffVersion(space: .personal) }
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
                        SynologyDiagnostics.diff.notice("personal Map scan committed \(scanned, privacy: .public) items")
                        await publishStoredLocationProjection()
                        return projection.records
                    }
                }
                throw CollectionCatalogError.exceedsLimit
            } catch {
                SynologyDiagnostics.diff.notice("personal Map scan ended without commit after \(scanned, privacy: .public) of \(total, privacy: .public) items: \(error.logSummary, privacy: .public)")
                try? await store.discardMetadataInventoryStage(id)
                throw error
            }
    }

}
