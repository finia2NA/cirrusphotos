import Foundation
import SynologyAPI

/// Action authorization must read after the action began; ordinary metadata
/// consumers may reuse detail authority already established during this run.
enum MetadataDetailFreshness: Sendable { case currentRun, fresh }

extension CachedPhotosRepository {
    /// One full-detail lane shared by every collection and derived consumer.
    /// Membership remains separate; these rows never authorize collection order.
    func resolveMetadataItems(_ ids: [Int64], priority: RequestPriority, collection: PhotoCollectionDescriptor = .library(.personal), freshness: MetadataDetailFreshness = .currentRun) async throws -> [PhotoItem] {
        let source = mediaCollection(for: collection)
        guard !source.isSessionDerived else { throw SynologyAPIError.unsupported("The source collection is no longer available.") }
        let scopedNamespace = metadataNamespace(for: source)
        let scope = scopedNamespace.scope
        guard ids.count <= 2000, Set(ids).count == ids.count else { throw CollectionCatalogError.exceedsLimit }
        let admissionEpoch = metadata.admissionEpoch
        let cached = try await store.metadataDetails(scopedNamespace, ids: ids, currentRun: runID)
        guard admissionEpoch == metadata.admissionEpoch, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
        let missing = ids.filter { freshness == .fresh || cached[$0]?.verified != true }
        let subscriber = UUID()
        var enrolled: Set<UUID> = []
        var fresh: [Int64] = []
        for id in missing {
            if freshness == .currentRun, let jobID = metadata.detailJobByID[PhotoItemIdentity(scope: scope, itemID: id)], var job = metadata.detailJobs[jobID] {
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
                let admission = try await store.metadataAdmission(scopedNamespace)
                let items = try await metadataReadRequest(priority: priority, id: id) { try await lookupMetadataItems(chunk, source: source) }
                try Task.checkCancellation()
                guard !metadata.resetInProgress, epoch == metadata.admissionEpoch,
                      chunk.allSatisfy({ metadata.detailJobByID[PhotoItemIdentity(scope: scope, itemID: $0)] == id }) else {
                    throw MetadataAdmissionError.superseded
                }
                guard items.count == chunk.count, Set(items.map(\.id)) == Set(chunk) else {
                    throw MetadataMembershipReadFailure(revision: admission.revision, cause: CollectionCatalogError.invalidCoverage)
                }
                let dirtyDays = try await store.storeMetadataDetails(items, namespace: scopedNamespace, currentRun: runID, admission: admission)
                guard epoch == metadata.admissionEpoch, !metadata.resetInProgress, !Task.isCancelled else { throw MetadataAdmissionError.superseded }
                if !dirtyDays.isEmpty {
                    let sources = Set(metadata.collectionObservers.values.map(\.collection))
                        .union(metadata.latestTimelines.keys)
                    for collection in sources where metadataNamespace(for: collection) == scopedNamespace {
                        publishMetadataInvalidation(collection: collection, days: dirtyDays)
                    }
                }
                let sources = Set(metadata.collectionPageObservers.values.map(\.collection)).filter { !$0.isSessionDerived && metadataNamespace(for: $0) == scopedNamespace }
                for source in sources {
                    if let references = try? await store.metadataCollectionReferences(scopedNamespace, collection: source, ids: chunk) {
                        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
                        for section in references {
                            if let key = CacheKey.page(scope: scope, namespace: namespace, section: section, collection: source) { publishCollectionPage(key: key) }
                        }
                    }
                }
                if let space = scope.space {
                    publishDerivedPageChanges(ids: Set(chunk), space: space)
                    if space == .shared { await publishSharedLocationItemChanges(items) }
                    else { publishLocationItemChanges(items) }
                }
                return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            }
            metadata.detailJobs[id] = MetadataDetailJob(scope: scope, task: task, itemIDs: chunk, subscribers: [subscriber])
            for itemID in chunk { metadata.detailJobByID[PhotoItemIdentity(scope: scope, itemID: itemID)] = id }
            enrolled.insert(id)
        }
        let jobs = enrolled.compactMap { id in metadata.detailJobs[id].map { (id, $0.task) } }
        let jobIDs = jobs.map(\.0)
        defer { releaseMetadataDetails(subscriber: subscriber, jobs: jobIDs) }
        return try await withTaskCancellationHandler {
            var byID = freshness == .currentRun ? cached.compactMapValues { $0.verified ? $0.item : nil } : [:]
            for (_, job) in jobs {
                try Task.checkCancellation()
                let items = try await job.value
                try Task.checkCancellation()
                byID.merge(items, uniquingKeysWith: { _, latest in latest })
            }
            return try ids.map { id in
                guard let item = byID[id] else { throw CollectionCatalogError.invalidCoverage }
                return item
            }
        } onCancel: {
            Task { await self.releaseMetadataDetails(subscriber: subscriber, jobs: jobIDs) }
        }
    }
    private func lookupMetadataItems(_ ids: [Int64], source: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        switch source.contentScope {
        case .space(let space): return try await client.items(ids: ids, space: space)
        case .album(let albumID): return try await client.albumItems(ids: ids, albumID: albumID)
        case .incomingAlbum:
            guard let reference = incomingReference(for: source) else { throw SynologyAPIError.unsupported("Shared album access is unavailable.") }
            return try await client.incomingItems(ids: ids, reference: reference)
        }
    }

    private func finishMetadataDetailJob(_ id: UUID) {
        guard let job = metadata.detailJobs.removeValue(forKey: id) else { return }
        for itemID in job.itemIDs {
            let identity = PhotoItemIdentity(scope: job.scope, itemID: itemID)
            if metadata.detailJobByID[identity] == id { metadata.detailJobByID.removeValue(forKey: identity) }
        }
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
