import Foundation
import SynologyAPI

/// Shared Space keeps its complete inventory across runs like Personal Space: the
/// Shared Diff feed keeps it current, and a full scan runs only when it is incomplete.
struct SharedLocationState {
    var job: SharedJob<[PhotoLocationRecord]>?
    /// A complete scan finished this run.
    var current = false
    var revision: UInt64 = 0
    var records: [Int64: PhotoLocationRecord] = [:]
    var observers: [UUID: AsyncStream<LocationIndexEvent>.Continuation] = [:]
}

extension CachedPhotosRepository {
    func sharedLocationIndexChanges() -> AsyncStream<LocationIndexEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            metadata.sharedLocations.observers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeSharedLocationObserver(id) }
            }
        }
    }

    private func removeSharedLocationObserver(_ id: UUID) {
        metadata.sharedLocations.observers.removeValue(forKey: id)
    }

    func publishSharedLocationItemChanges(_ items: [PhotoItem], deletedIDs: [Int64] = []) async {
        let epoch = metadata.admissionEpoch
        let state = try? await store.metadataState(metadataNamespace(for: .library(.shared)))
        guard isAdmitted(epoch) else { return }
        if state?.inventoryComplete != true { metadata.sharedLocations.current = false }
        guard metadata.sharedLocations.current || !metadata.sharedLocations.records.isEmpty else { return }
        let verified = state?.inventoryComplete == true && (metadata.sharedLocations.current || metadataSourceCurrent(.shared))
        var records = metadata.sharedLocations.records
        for id in deletedIDs { records.removeValue(forKey: id) }
        for item in items {
            records[item.id] = item.coordinate.map {
                PhotoLocationRecord(id: item.id, time: item.time, coordinate: $0, thumbnail: item.additional?.thumbnail)
            }
        }
        let value = acceptLocationRecords(records.values.sorted { $0.time > $1.time || ($0.time == $1.time && $0.id < $1.id) }, space: .shared)
        for observer in metadata.sharedLocations.observers.values {
            observer.yield(.completed(value, verified: verified))
        }
    }

    func sharedLocationIndex() -> AsyncStream<LocationIndexEvent> {
        let producer = StreamProducer()
        let subscriber = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            producer.task = Task {
                metadata.directSubscribers.insert(subscriber)
                defer { metadata.directSubscribers.remove(subscriber); cancelIdleLogin() }
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let scope = metadataNamespace(for: .library(.shared))
                    let cached = try await store.metadataLocationProjection(scope)
                    guard isAdmitted(epoch), !Task.isCancelled else { throw CancellationError() }
                    metadata.sharedLocations.current = metadata.sharedLocations.current && cached.state.inventoryComplete
                    if !cached.records.isEmpty { continuation.yield(.cached(acceptLocationRecords(cached.records, space: .shared))) }
                    try await connect()
                    try await reconcileMetadataSource(space: .shared)
                    let projection = try await store.metadataLocationProjection(scope, currentOnly: true)
                    guard isAdmitted(epoch), !Task.isCancelled else { throw CancellationError() }
                    if projection.state.inventoryComplete && (metadata.sharedLocations.current || metadataSourceCurrent(.shared)) {
                        continuation.yield(.completed(acceptLocationRecords(projection.records, space: .shared), verified: true))
                        continuation.finish()
                        return
                    }
                    let task: Task<[PhotoLocationRecord], Error>
                    if var job = metadata.sharedLocations.job {
                        job.subscribers.insert(subscriber); metadata.sharedLocations.job = job
                        task = job.task
                    }
                    else {
                        let id = UUID()
                        task = Task {
                            defer {
                                if metadata.sharedLocations.job?.id == id { metadata.sharedLocations.job = nil }
                                cancelIdleLogin()
                            }
                            return try await buildSharedMetadataInventory(id: id)
                        }
                        metadata.sharedLocations.job = SharedJob(id: id, task: task, subscribers: [subscriber])
                    }
                    let records = try await task.value
                    guard isAdmitted(epoch), !Task.isCancelled else { throw CancellationError() }
                    continuation.yield(.completed(acceptLocationRecords(records, space: .shared), verified: true))
                } catch {
                    if !Task.isCancelled { continuation.yield(.failure(RepositoryError.record(error, operation: "Shared location index").localizedDescription)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseSharedLocationScan(subscriber) }
            }
        }
    }

    private func releaseSharedLocationScan(_ subscriber: UUID) {
        guard var job = metadata.sharedLocations.job else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.sharedLocations.job = nil; cancelIdleLogin() }
        else { metadata.sharedLocations.job = job }
    }

    /// Uses the scoped Timeline/Item contracts and the Shared Diff cursor as the fence.
    /// Staging retains non-geotagged IDs to prove full coverage too.
    func buildSharedMetadataInventory(id: UUID) async throws -> [PhotoLocationRecord] {
        let token = try await captureMetadataWorkToken(resource: .transient(.library(.shared)), jobID: id)
        let scope = metadataNamespace(for: .library(.shared))
        try await reconcileMetadataSource(space: .shared, force: true)
        let admission = try await store.metadataAdmission(scope)
        let prior = try await store.metadataState(scope)
        func requireCurrent() async throws {
            guard !Task.isCancelled, metadata.sharedLocations.job?.id == id,
                  await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
        }
        do {
            try await connect()
            let catalog = try await acquireCollectionCatalog(.library(.shared), priority: .prefetch).catalog
            try await requireCurrent()
            guard catalog.completeness == .complete else { throw CollectionCatalogError.invalidCoverage }
            let snapshot = try CollectionDayPager.snapshot(catalog: catalog)
            let counts = Dictionary(uniqueKeysWithValues: catalog.days.map { ($0.day, $0.count) })
            let demands = try snapshot.sections.map { section in
                let address = try DayPageAddress(section: section, collection: .library(.shared))
                guard let count = counts[address.day] else { throw CollectionCatalogError.invalidCoverage }
                return try DayPageRead(address: address, dayCount: count, membershipGeneration: 0)
            }
            let batches = try MetadataReadPlanner.plan(demands: demands, catalog: catalog, profile: .locations)
            guard batches.count <= Self.locationScanPageCap else { throw CollectionCatalogError.exceedsLimit }
            var scanned = 0
            for batch in batches {
                let result = try await metadataReadRequest(priority: .prefetch, id: id) {
                    try await client.readCollectionBatch(batch.request, fields: .locations)
                }
                _ = try batch.materialize(result)
                try await requireCurrent()
                try await store.stageMetadataInventory(result.items, job: id, namespace: scope, admission: admission)
                scanned += result.items.count
                for observer in metadata.sharedLocations.observers.values {
                    observer.yield(.progress(scanned: scanned, total: catalog.itemCount))
                }
            }
            guard scanned == catalog.itemCount else { throw CollectionCatalogError.invalidCoverage }
            // Any change during the scan shows up in the Shared Diff from the reconciled
            // cursor; refuse it and leave the preceding inventory intact.
            var fenceCursor = prior.cursor
            if let cursor = prior.cursor, !metadata[source: .shared].sourceUnavailable {
                let fence = try await metadataReadRequest(priority: .prefetch, id: id) { try await client.changes(since: cursor, space: .shared) }
                guard fence.isEmpty else { throw CollectionCatalogError.invalidCoverage }
                fenceCursor = fence.cursor
            } else {
                let fence = try await acquireCollectionCatalog(.library(.shared), priority: .prefetch).catalog
                guard fence.completeness == .complete, fence.days == catalog.days else { throw CollectionCatalogError.invalidCoverage }
            }
            try await requireCurrent()
            try await store.commitMetadataInventory(id, namespace: scope, catalog: catalog, cursor: fenceCursor, admission: admission)
            try await requireCurrent()
            let projection = try await store.metadataLocationProjection(scope, currentOnly: true)
            guard projection.state.inventoryComplete, projection.state.resetEpoch == admission.resetEpoch else { throw CollectionCatalogError.invalidCoverage }
            metadata.sharedLocations.current = true
            let value = acceptLocationRecords(projection.records, space: .shared)
            for observer in metadata.sharedLocations.observers.values { observer.yield(.completed(value, verified: true)) }
            return projection.records
        } catch {
            try? await store.discardMetadataInventoryStage(id)
            throw error
        }
    }
}
