import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    func loadMetadataPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                          priority: RequestPriority) async throws -> PhotoPageSnapshot {
        let address = try DayPageAddress(section: section, collection: collection)
        let key = CollectionKey(namespace: metadataNamespace(for: collection), collection: collection)
        guard let generation = try await store.metadataDayGeneration(key, day: address.day), generation >= 0 else {
            throw CollectionCatalogError.invalidCoverage
        }
        let demand = try DayPageRead(address: address, dayCount: section.list[0].itemCount, membershipGeneration: UInt64(generation))
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var pending = metadata.pendingPages[address], pending.read == demand {
                    pending.waiters[subscriber] = continuation
                    if priority == .visible { pending.priority = .visible }
                    metadata.pendingPages[address] = pending
                } else if var active = metadata.activePages[address], active.read == demand {
                    active.waiters[subscriber] = continuation
                    if priority == .visible { active.priority = .visible }
                    metadata.activePages[address] = active
                    if priority == .visible, let batchID = active.batchID { Task { await gate.promote(batchID) } }
                } else {
                    if let old = metadata.pendingPages.removeValue(forKey: address) {
                        for waiter in old.waiters.values { waiter.resume(throwing: MetadataAdmissionError.superseded) }
                    }
                    if let old = metadata.activePages.removeValue(forKey: address) {
                        for waiter in old.waiters.values { waiter.resume(throwing: MetadataAdmissionError.superseded) }
                    }
                    metadata.pendingPages[address] = MetadataPendingPage(read: demand, priority: priority, waiters: [subscriber: continuation])
                }
                finishExpectedMetadataDemand(address)
                scheduleMetadataPageFlush()

            }
        } onCancel: {
            Task { await self.releaseMetadataPage(address, subscriber: subscriber) }
        }
    }

    func promoteMetadataPage(_ address: DayPageAddress) async {
        if var pending = metadata.pendingPages[address] {
            pending.priority = .visible
            metadata.pendingPages[address] = pending
            scheduleMetadataPageFlush()
        }
        if let batchID = metadata.activePages[address]?.batchID { await gate.promote(batchID) }
    }

    /// The warmer admits a bounded logical lookahead independently of the two
    /// physical network slots. Individual callers still share the same page jobs.
    func beginMetadataPageDemandBatch(_ sections: [TimelineSection], collection: PhotoCollectionDescriptor) -> UUID {
        let id = UUID()
        metadata.expectedPageDemands[id] = Set(sections.prefix(64).compactMap { try? DayPageAddress(section: $0, collection: collection) })
        return id
    }
    func endMetadataPageDemandBatch(_ id: UUID) {
        metadata.expectedPageDemands.removeValue(forKey: id)
        scheduleMetadataPageFlush()
    }
    func finishExpectedMetadataDemand(_ address: DayPageAddress) {
        for id in Array(metadata.expectedPageDemands.keys) {
            metadata.expectedPageDemands[id]?.remove(address)
            if metadata.expectedPageDemands[id]?.isEmpty == true { metadata.expectedPageDemands.removeValue(forKey: id) }
        }
        scheduleMetadataPageFlush()
    }
    private func scheduleMetadataPageFlush() {
        guard metadata.flushJob == nil, !metadata.pendingPages.isEmpty,
              (metadata.expectedPageDemands.values.allSatisfy(\.isEmpty) || metadata.pendingPages.values.contains { $0.priority == .visible }) else { return }
        metadata.flushJob = Task {
            try? await Task.sleep(for: .milliseconds(2))
            guard !Task.isCancelled else { return }
            await flushMetadataPages()
        }
    }

    private func flushMetadataPages() async {
        metadata.flushJob = nil
        let planningEpoch = metadata.admissionEpoch
        let pending = metadata.pendingPages
        metadata.pendingPages.removeAll()
        for (address, page) in pending { metadata.activePages[address] = page }
        let collections = Set(pending.keys.map(\.collection))
        for collection in collections {
            var rows: [DayPageAddress: MetadataPendingPage] = [:]
            do {
                let key = CollectionKey(namespace: metadataNamespace(for: collection), collection: collection)
                guard let catalog = try await store.metadataCatalog(key)?.catalog else { throw CollectionCatalogError.invalidCoverage }
                guard planningEpoch == metadata.admissionEpoch, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
                rows = metadata.activePages.filter { $0.key.collection == collection && pending[$0.key]?.id == $0.value.id && $0.value.batchID == nil }
                let batches = try MetadataReadPlanner.plan(demands: rows.values.map(\.read), catalog: catalog, profile: .fullPage)
                for batch in batches {
                    let id = UUID()
                    var priority = RequestPriority.prefetch
                    for page in batch.pages {
                        var active = metadata.activePages[page.address]!
                        active.batchID = id
                        if active.priority == .visible { priority = .visible }
                        metadata.activePages[page.address] = active
                    }
                    let effectivePriority = priority
                    metadata.batchJobs[id] = Task {
                        var readRevision: Int64 = -1
                        do {
                            let admission = try await store.metadataAdmission(metadataNamespace(for: collection))
                            readRevision = admission.revision
                            let epoch = metadata.admissionEpoch
                            let result = try await metadataReadRequest(priority: effectivePriority, id: id) {
                                if collection.incomingAlbumIdentity != nil {
                                    guard let reference = incomingReference(for: collection) else { throw SynologyAPIError.unsupported("Shared album access is unavailable.") }
                                    return try await client.readIncomingCollectionBatch(batch.request, reference: reference, fields: batch.profile)
                                }
                                return try await client.readCollectionBatch(batch.request, fields: batch.profile)
                            }
                            let pages = try batch.materialize(result)
                            guard !Task.isCancelled, !metadata.resetInProgress, epoch == metadata.admissionEpoch else { throw MetadataAdmissionError.superseded }
                            for (read, items) in zip(batch.pages, pages) {
                                try await store.storeMetadataPage(read, items: items, profile: result.profile,
                                                                  namespace: metadataNamespace(for: collection), currentRun: runID, admission: admission)
                            }
                            if collection.contentScope == .space(.personal) { publishLocationItemChanges(result.items) }
                            else if collection.contentScope == .space(.shared) { await publishSharedLocationItemChanges(result.items) }
                            for read in batch.pages {
                                guard let page = try await store.metadataPage(read.address, namespace: metadataNamespace(for: collection), currentRun: runID) else {
                                    throw CacheError.storage
                                }
                                finishMetadataPage(read.address, batchID: id, result: .success(page))
                            }
                        } catch {
                            let failure: any Error
                            if case CollectionCatalogError.invalidCoverage = error {
                                failure = MetadataMembershipReadFailure(revision: readRevision, cause: error)
                                let addresses = Set(batch.pages.compactMap { page -> DayPageAddress? in
                                    guard let active = metadata.activePages[page.address], active.batchID == id, !active.waiters.isEmpty else { return nil }
                                    return page.address
                                })
                                if !addresses.isEmpty { metadata.expectedPageDemands[UUID()] = addresses }
                            }
                            else { failure = error }
                            for read in batch.pages { finishMetadataPage(read.address, batchID: id, result: .failure(failure)) }
                        }
                        metadata.batchJobs.removeValue(forKey: id)
                    }
                }
            } catch {
                guard planningEpoch == metadata.admissionEpoch else { return }
                for address in pending.keys where address.collection == collection {
                    guard let row = metadata.activePages[address], row.id == pending[address]?.id, row.batchID == nil else { continue }
                    metadata.activePages.removeValue(forKey: address)
                    for waiter in row.waiters.values { waiter.resume(throwing: error) }
                }
            }
        }
    }

    private func finishMetadataPage(_ address: DayPageAddress, batchID: UUID,
                                    result: Result<PhotoPageSnapshot, Error>) {
        guard let active = metadata.activePages[address], active.batchID == batchID else { return }
        metadata.activePages.removeValue(forKey: address)
        for waiter in active.waiters.values { waiter.resume(with: result) }
    }
    private func releaseMetadataPage(_ address: DayPageAddress, subscriber: UUID) {
        finishExpectedMetadataDemand(address)
        if var pending = metadata.pendingPages[address] {
            pending.waiters.removeValue(forKey: subscriber)?.resume(throwing: CancellationError())
            if pending.waiters.isEmpty { metadata.pendingPages.removeValue(forKey: address) }
            else { metadata.pendingPages[address] = pending }
        }
        if var active = metadata.activePages[address] {
            active.waiters.removeValue(forKey: subscriber)?.resume(throwing: CancellationError())
            if active.waiters.isEmpty {
                metadata.activePages.removeValue(forKey: address)
                if let batchID = active.batchID, !metadata.activePages.values.contains(where: { $0.batchID == batchID }) {
                    metadata.batchJobs.removeValue(forKey: batchID)?.cancel()
                }
            } else { metadata.activePages[address] = active }
        }
    }

    func cancelNormalizedMetadataWork() {
        metadata.flushJob?.cancel()
        for task in metadata.batchJobs.values { task.cancel() }
        for page in Array(metadata.pendingPages.values) + Array(metadata.activePages.values) {
            for waiter in page.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        metadata.expectedPageDemands.removeAll()
        metadata.pendingPages.removeAll()
        metadata.activePages.removeAll()
        metadata.batchJobs.removeAll()
    }
}
