import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// One full-detail lane shared by every collection and derived consumer.
    /// Membership remains separate; these rows never authorize collection order.
    func resolveMetadataItems(_ ids: [Int64], priority: RequestPriority, collection: PhotoCollectionDescriptor = .personalLibrary) async throws -> [PhotoItem] {
        let source = collection.albumID != nil ? collection : mediaCollection(for: collection)
        guard !source.isSessionDerived else { throw SynologyAPIError.unsupported("The source collection is no longer available.") }
        if source.incomingAlbumIdentity != nil || source.albumID != nil || source.space == .shared {
            guard ids.count <= 2000, Set(ids).count == ids.count else { throw CollectionCatalogError.exceedsLimit }
            let scopedNamespace = metadataNamespace(for: source)
            let admission = try await store.metadataAdmission(scopedNamespace)
            var items: [PhotoItem] = []
            for start in stride(from: 0, to: ids.count, by: MetadataReadPlanner.lookupBatchSize) {
                let chunk = Array(ids[start..<min(start + MetadataReadPlanner.lookupBatchSize, ids.count)])
                let batch = try await metadataReadRequest(priority: priority) {
                    if source.space == .shared { return try await client.items(ids: chunk, space: .shared) }
                    if let albumID = source.albumID { return try await client.albumItems(ids: chunk, albumID: albumID) }
                    guard let reference = incomingReference(for: source) else { throw SynologyAPIError.unsupported("Shared album access is unavailable.") }
                    return try await client.incomingItems(ids: chunk, reference: reference)
                }
                items.append(contentsOf: batch)
            }
            guard items.count == ids.count, Set(items.map(\.id)) == Set(ids) else { throw CollectionCatalogError.invalidCoverage }
            _ = try await store.storeMetadataDetails(items, namespace: scopedNamespace, currentRun: runID, admission: admission)
            if source.space == .shared {
                await publishSharedLocationItemChanges(items)
                publishDerivedPageChanges(ids: Set(ids), space: .shared)
            }
            return items
        }
        guard ids.count <= 2000, Set(ids).count == ids.count else { throw CollectionCatalogError.exceedsLimit }
        let admissionEpoch = metadata.admissionEpoch
        let cached = try await store.metadataDetails(metadataNamespace, ids: ids, currentRun: runID)
        guard admissionEpoch == metadata.admissionEpoch, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
        let missing = ids.filter { cached[$0]?.verified != true }
        let subscriber = UUID()
        var enrolled: Set<UUID> = []
        var fresh: [Int64] = []
        for id in missing {
            if let jobID = metadata.detailJobByID[id], var job = metadata.detailJobs[jobID] {
                job.subscribers.insert(subscriber); metadata.detailJobs[jobID] = job; enrolled.insert(jobID)
                if priority == .visible { Task { await gate.promote(jobID) } }
            } else { fresh.append(id) }
        }
        for start in stride(from: 0, to: fresh.count, by: MetadataReadPlanner.lookupBatchSize) {
            let chunk = Array(fresh[start..<min(start + MetadataReadPlanner.lookupBatchSize, fresh.count)])
            let id = UUID()
            let epoch = metadata.admissionEpoch
            let task = Task<[Int64: PhotoItem], Error> {
                defer { finishMetadataDetailJob(id) }
                let admission = try await store.metadataAdmission(metadataNamespace)
                let items = try await metadataReadRequest(priority: priority, id: id) { try await client.items(ids: chunk) }
                guard items.count == chunk.count, Set(items.map(\.id)) == Set(chunk),
                      !Task.isCancelled, !metadata.resetInProgress, epoch == metadata.admissionEpoch else {
                    throw MetadataMembershipReadFailure(revision: admission.revision, cause: CollectionCatalogError.invalidCoverage)
                }
                let dirtyDays = try await store.storeMetadataDetails(items, namespace: metadataNamespace, currentRun: runID, admission: admission)
                guard epoch == metadata.admissionEpoch, !metadata.resetInProgress, !Task.isCancelled else { throw MetadataAdmissionError.superseded }
                if !dirtyDays.isEmpty { publishMetadataInvalidation(days: dirtyDays) }
                let sources = Set(metadata.collectionPageObservers.values.map(\.collection)).filter { !$0.isSessionDerived }
                for source in sources {
                    if let references = try? await store.metadataCollectionReferences(metadataNamespace, collection: source, ids: chunk) {
                        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
                        for section in references {
                            if let key = CacheKey.page(scope: .space(.personal), namespace: namespace, section: section, collection: source) { publishCollectionPage(key: key) }
                        }
                    }
                }
                publishDerivedPageChanges(ids: Set(chunk))
                publishLocationItemChanges(items)
                return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            }
            metadata.detailJobs[id] = MetadataDetailJob(task: task, itemIDs: chunk, subscribers: [subscriber])
            for itemID in chunk { metadata.detailJobByID[itemID] = id }
            enrolled.insert(id)
        }
        let jobs = enrolled.compactMap { id in metadata.detailJobs[id].map { (id, $0.task) } }
        let jobIDs = jobs.map(\.0)
        defer { releaseMetadataDetails(subscriber: subscriber, jobs: jobIDs) }
        return try await withTaskCancellationHandler {
            var byID = cached.compactMapValues { $0.verified ? $0.item : nil }
            for (_, job) in jobs {
                try Task.checkCancellation()
                byID.merge(try await job.value, uniquingKeysWith: { _, latest in latest })
            }
            return try ids.map { id in
                guard let item = byID[id] else { throw CollectionCatalogError.invalidCoverage }
                return item
            }
        } onCancel: {
            Task { await self.releaseMetadataDetails(subscriber: subscriber, jobs: jobIDs) }
        }
    }
    private func finishMetadataDetailJob(_ id: UUID) {
        guard let job = metadata.detailJobs.removeValue(forKey: id) else { return }
        for itemID in job.itemIDs where metadata.detailJobByID[itemID] == id { metadata.detailJobByID.removeValue(forKey: itemID) }
    }
    private func releaseMetadataDetails(subscriber: UUID, jobs: [UUID]) {
        for id in jobs {
            guard var job = metadata.detailJobs[id] else { continue }
            job.subscribers.remove(subscriber)
            if job.subscribers.isEmpty { job.task.cancel(); finishMetadataDetailJob(id) }
            else { metadata.detailJobs[id] = job }
        }
    }
}
