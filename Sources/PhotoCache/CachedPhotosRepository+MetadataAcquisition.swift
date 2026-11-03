import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Authoritative acquisition has no cursor or independent freshness coordinator.
    /// The source boundary is established by the caller before this read starts.
    func acquireCollectionCatalog(_ collection: PhotoCollectionDescriptor,
                                  initial: Bool = false,
                                  priority: RequestPriority = .visible) async throws -> CollectionCatalogRead {
        if collection.usesItemCatalog {
            guard !initial else { throw SynologyAPIError.invalidResponse }
            var entries: [DayTimelineEntry] = []
            var seen: Set<Int64> = []
            for page in 0..<2048 {
                let batch = try await metadataReadRequest(priority: priority) {
                    if collection.incomingAlbumIdentity != nil {
                        guard let reference = incomingReference(for: collection) else { throw RepositoryError.unavailable("Shared album access is unavailable.") }
                        return try await client.readIncomingAlbumCatalogBatch(reference: reference, offset: page * 1000, limit: 1000)
                    }
                    if let albumID = collection.albumID {
                        return try await client.readAlbumCatalogBatch(albumID: albumID, offset: page * 1000, limit: 1000)
                    }
                    guard let folderID = collection.folderID, let space = collection.space else { throw CollectionCatalogError.invalidAddress }
                    return try await client.readFolderCatalogBatch(folderID: folderID, offset: page * 1000, limit: 1000, space: space)
                }
                guard batch.count <= 1000 else { throw CollectionCatalogError.invalidCoverage }
                for entry in batch {
                    guard seen.insert(entry.id).inserted else { throw CollectionCatalogError.invalidCoverage }
                }
                entries.append(contentsOf: batch)
                if batch.count < 1000 {
                    let grouped = DayGroupedTimelineBuilder.build(entries: entries)
                    let catalog = try CollectionDayCatalog(sections: grouped.snapshot.sections, completeness: .complete)
                    // Ordered IDs are retained for the common membership materializer,
                    // rather than thrown away by the catalog endpoint.
                    return CollectionCatalogRead(catalog: catalog, membership: AlbumCatalogMembership(grouped: grouped, times: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.time) })))
                }
            }
            throw CollectionCatalogError.exceedsLimit
        }
        let catalog = try await metadataReadRequest(priority: priority) {
            try await client.collectionDayCatalog(collection: collection, initial: initial)
        }
        return CollectionCatalogRead(catalog: catalog, membership: nil)
    }

    /// One failed transport batch can serve many logical pages. They share one
    /// conservative catalog repair and a receipt for that read revision.
    func recoverCollectionMembership(_ collection: PhotoCollectionDescriptor,
                                     failedReadRevision: Int64) async throws -> TimelineSnapshot {
        if let recovery = metadata.collectionRecoveries[collection], recovery.active || failedReadRevision < recovery.recoveryRevision {
            return try await recovery.task.value
        }
        let epoch = metadata.admissionEpoch
        let mutationEpoch = metadata.mutationEpochs[collection, default: 0]
        let admission = try await store.metadataAdmission(metadataNamespace(for: collection))
        try requireAdmission(epoch)
        if let recovery = metadata.collectionRecoveries[collection], recovery.active || failedReadRevision < recovery.recoveryRevision {
            return try await recovery.task.value
        }
        let id = UUID()
        let task = Task<TimelineSnapshot, Error> {
            defer { if metadata.collectionRecoveries[collection]?.id == id { metadata.collectionRecoveries[collection]?.active = false } }
            try requireAdmission(epoch)
            // This transaction adds invalidation; it cannot overwrite a newer value.
            try await store.invalidateMetadataCollection(CollectionKey(namespace: metadataNamespace(for: collection), collection: collection), admission: admission)
            guard isAdmitted(epoch), !Task.isCancelled,
                  metadata.collectionRecoveries[collection]?.id == id,
                  mutationEpoch == metadata.mutationEpochs[collection, default: 0] else { throw MetadataAdmissionError.superseded }
            let committed = try await store.metadataState(metadataNamespace(for: collection))
            guard epoch == metadata.admissionEpoch, metadata.collectionRecoveries[collection]?.id == id else { throw MetadataAdmissionError.superseded }
            if collection.contentScope == .space(.personal) { metadata.revision = committed.revision }
            metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
            publishMetadataInvalidation(collection: collection)
            return try await verifiedTimelineSnapshot(collection: collection)
        }
        metadata.collectionRecoveries[collection] = MetadataCollectionRecovery(id: id, recoveryRevision: admission.revision + 1, task: task, active: true)
        return try await task.value
    }

    func metadataReadRequest<Value: Sendable>(priority: RequestPriority, id: UUID = UUID(),
                                               _ operation: () async throws -> Value) async throws -> Value {
        try await gate.acquire(.metadata, priority: priority, id: id)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await gate.release(.metadata)
            return value
        } catch {
            await gate.release(.metadata)
            throw error
        }
    }
}
