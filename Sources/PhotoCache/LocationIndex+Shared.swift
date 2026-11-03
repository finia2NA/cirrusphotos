import Foundation
import SynologyAPI

/// Shared Space has no established Diff contract. Its complete inventory is
/// validated once per run by bounded authoritative reads in the common engine.
struct SharedLocationState {
    var job: SharedJob<[PhotoLocationRecord]>?
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

    func publishSharedLocationItemChanges(_ items: [PhotoItem]) async {
        let epoch = metadata.admissionEpoch
        let state = try? await store.metadataState(metadataNamespace(for: .library(.shared)))
        guard isAdmitted(epoch) else { return }
        if state?.inventoryComplete != true { metadata.sharedLocations.current = false }
        guard metadata.sharedLocations.current || !metadata.sharedLocations.records.isEmpty else { return }
        var records = metadata.sharedLocations.records
        for item in items {
            records[item.id] = item.coordinate.map {
                PhotoLocationRecord(id: item.id, time: item.time, coordinate: $0, thumbnail: item.additional?.thumbnail)
            }
        }
        let oldRevision = metadata.sharedLocations.revision
        let value = acceptLocationRecords(records.values.sorted { $0.time > $1.time || ($0.time == $1.time && $0.id < $1.id) }, space: .shared)
        if oldRevision != metadata.sharedLocations.revision { metadata.sharedLocations.current = false }
        for observer in metadata.sharedLocations.observers.values {
            observer.yield(.completed(value, verified: metadata.sharedLocations.current))
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
                    if !cached.records.isEmpty || cached.state.inventoryComplete {
                        let value = acceptLocationRecords(cached.records, space: .shared)
                        if metadata.sharedLocations.current && cached.state.inventoryComplete {
                            continuation.yield(.completed(value, verified: true))
                            continuation.finish()
                            return
                        }
                        continuation.yield(.cached(value))
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

    /// Uses the existing scoped Timeline/Item contracts, never Personal Diff or
    /// web Places. Staging retains non-geotagged IDs to prove full coverage too.
    func buildSharedMetadataInventory(id: UUID) async throws -> [PhotoLocationRecord] {
        let token = try await captureMetadataWorkToken(resource: .transient(.library(.shared)), jobID: id)
        let scope = metadataNamespace(for: .library(.shared))
        let admission = try await store.metadataAdmission(scope)
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
            // No supported change cursor: refuse count/day drift and leave the
            // preceding inventory intact. This cannot establish a server snapshot.
            let fence = try await acquireCollectionCatalog(.library(.shared), priority: .prefetch).catalog
            guard fence.completeness == .complete, fence.days == catalog.days, scanned == catalog.itemCount else { throw CollectionCatalogError.invalidCoverage }
            try await requireCurrent()
            try await store.commitMetadataInventory(id, namespace: scope, catalog: catalog, cursor: nil, admission: admission)
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
