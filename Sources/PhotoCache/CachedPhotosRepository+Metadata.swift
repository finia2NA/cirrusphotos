import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Joins the ordinary cached-first timeline pipeline and returns only a value
    /// validated in this repository run. Derived resources use this before
    /// admitting network work based on timeline geometry.
    func verifiedTimelineSnapshot(
        collection: PhotoCollectionDescriptor
    ) async throws -> TimelineSnapshot {
        var failure: String?
        for await event in timeline(collection: collection) {
            try Task.checkCancellation()
            switch event {
            case .value(let snapshot, let verified):
                if verified { return snapshot }
            case .failure(let message):
                failure = message
            }
        }
        throw SynologyAPIError.unsupported(
            failure ?? "The requested timeline could not be validated."
        )
    }

    public func timeline(collection: PhotoCollectionDescriptor = .personalLibrary) -> AsyncStream<ResourceEvent<TimelineSnapshot>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do { try await initializeMetadataEngine() }
                catch { continuation.yield(.failure(error.localizedDescription)); continuation.finish(); return }
                let validation = runID
                let epoch = metadata.admissionEpoch
                let cached = try? await store.metadataCatalog(CollectionKey(namespace: metadataNamespace, collection: collection))
                guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                let snapshot = cached.flatMap { try? CollectionDayPager.snapshot(catalog: $0.catalog) }
                if let snapshot {
                    metadata.latestTimelines[collection] = snapshot
                    continuation.yield(.value(snapshot, verified: cached?.validatedRun == validation))
                }
                if cached?.validatedRun == validation, snapshot != nil { continuation.finish(); return }
                var phase = "Initial timeline"
                do {
                    if snapshot == nil, collection.supportsInitialTimeline {
                        let initial = try await initialTimeline(id: subscriber, collection: collection)
                        guard !Task.isCancelled else { continuation.finish(); return }
                        metadata.latestTimelines[collection] = initial
                        continuation.yield(.value(initial, verified: false))
                    }
                    phase = "Full timeline"
                    let requestedValidation = validationRun(for: collection)
                    let task = registerTimeline(collection: collection, subscriber: subscriber)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    metadata.latestTimelines[collection] = current
                    continuation.yield(.value(current,
                                              verified: requestedValidation == validationRun(for: collection)))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) {
                        continuation.yield(.failure("\(phase): \(error.localizedDescription)"))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseTimeline(collection: collection, subscriber: subscriber) }
            }
        }
    }

    public func page(_ section: TimelineSection, collection: PhotoCollectionDescriptor = .personalLibrary,
                     useCachedPages: Bool = true, allowNetwork: Bool = true,
                     priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<PhotoPageSnapshot>> {
        if collection.isMapFilter { return mapFilterPage(section, collection: collection, allowNetwork: allowNetwork, priority: priority) }
        if collection.isLibraryFilter {
            return libraryFilterPage(section, collection: collection, allowNetwork: allowNetwork, priority: priority)
        }
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let address = try DayPageAddress(section: section, collection: collection)
                    defer { finishExpectedMetadataDemand(address) }
                    guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection) else { throw CollectionCatalogError.invalidAddress }
                    let epoch = metadata.admissionEpoch
                    let cached = useCachedPages ? try await store.metadataPage(address, namespace: metadataNamespace, currentRun: runID) : nil
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(applyingFavoriteOverrides(cached), verified: cached.verified)) }
                    guard allowNetwork && cached?.verified != true else { continuation.finish(); return }
                    let task = registerPage(section, collection: collection, key: key, subscriber: subscriber, priority: priority, forceMembership: !useCachedPages)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(applyingFavoriteOverrides(current), verified: current.verified))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) && !(error is NetworkGateError && priority == .prefetch) {
                        continuation.yield(.failure(error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releasePage(key: CacheKey.page(namespace: self.namespace, section: section, collection: collection), subscriber: subscriber) }
            }
        }
    }

    func applyingFavoriteOverrides(_ page: PhotoPageSnapshot) -> PhotoPageSnapshot {
        PhotoPageSnapshot(address: page.address, membershipRevision: page.membershipRevision, membershipVerified: page.membershipVerified,
                          slots: page.slots.map { slot in
                              let item = slot.item.map { item in favorites.overrides[item.id].map { item.withFavorite($0) } ?? item }
                              return PhotoItemSlot(itemID: slot.itemID, item: item, verified: slot.verified)
                          })
    }
    /// Fetches metadata for a session-translated descriptor without reading or writing
    /// authoritative page-cache keys. Used only to reconstruct a frozen viewer playlist.
    func transientPage(_ section: TimelineSection,
                       collection: PhotoCollectionDescriptor,
                       priority: RequestPriority) async throws -> [PhotoItem] {
        if section.limit == 0 { return [] }
        let id = UUID()
        let token = try await captureMetadataWorkToken(
            resource: .transient(collection), jobID: id
        )
        try await gate.acquire(.metadata, priority: priority, id: id)
        defer { Task { await gate.release(.metadata) } }
        try await connect()
        guard let newest = section.list.first, let oldest = section.list.last else { throw CollectionCatalogError.invalidAddress }
        let request = try CollectionPageRequest(collection: collection, order: collection.albumID == nil ? .timeline : .takenTimeDescending,
                                                newestDay: CaptureDay(year: newest.year, month: newest.month, day: newest.day),
                                                oldestDay: CaptureDay(year: oldest.year, month: oldest.month, day: oldest.day), offset: section.offset, limit: section.limit)
        let items = try await client.readCollectionBatch(request, fields: .fullPage).items
        guard await metadataTokenIsCurrent(token) else { throw CancellationError() }
        return favorites.applyingOverrides(items)
    }

    /// Emits authoritative metadata replacements caused by local mutations. Normal startup
    /// reads use `timeline(collection:)`; this stream keeps views current without polling.
    public func timelineRefreshes(collection: PhotoCollectionDescriptor) -> AsyncStream<ResourceEvent<TimelineSnapshot>> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            metadata.refreshObservers[collection, default: [:]][id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeTimelineRefreshObserver(collection: collection, id: id) }
            }
        }
    }

    public func promotePage(_ section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary) async {
        guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection) else { return }
        if collection.isLibraryFilter {
            promoteLibraryFilterSources(section, collection: collection)
            return
        }
        if let filterID = collection.mapFilterID, let ids = metadata.mapFilters[filterID]?.idsBySection[section] {
            for id in ids {
                if let job = metadata.detailJobByID[id] { await gate.promote(job) }
            }
            return
        }
        if let job = metadata.pageJobs[key] {
            if let address = try? DayPageAddress(section: section, collection: collection) { await promoteMetadataPage(address) }
            await gate.promote(job.id)
        } else if !metadata.pendingPagePromotions.contains(key) {
            metadata.pendingPagePromotions.append(key)
            if metadata.pendingPagePromotions.count > 64 { metadata.pendingPagePromotions.removeFirst() }
        }
    }

    private func initialTimeline(id: UUID, collection: PhotoCollectionDescriptor) async throws -> TimelineSnapshot {
        metadata.initialSubscribers.insert(id)
        defer { metadata.initialSubscribers.remove(id); cancelIdleLogin() }
        let token = try await captureMetadataWorkToken(resource: .transient(collection), jobID: id, collection: collection)
        try await connect()
        try await reconcileMetadataSource()
        let catalog = try await acquireCollectionCatalog(collection, initial: true).catalog
        guard await metadataTokenIsCurrent(token) else { throw CancellationError() }
        return try CollectionDayPager.snapshot(catalog: catalog)
    }

    private func registerTimeline(collection: PhotoCollectionDescriptor,
                                  subscriber: UUID) -> Task<TimelineSnapshot, Error> {
        if var job = metadata.timelineJobs[collection] {
            job.subscribers.insert(subscriber)
            metadata.timelineJobs[collection] = job
            return job.task
        }
        let id = UUID()
        let mutationEpoch = metadata.mutationEpochs[collection, default: 0]
        let task = Task<TimelineSnapshot, Error> {
            let token = try await captureMetadataWorkToken(resource: .timeline(collection), jobID: id, collection: collection)
            try await connect()
            try await reconcileMetadataSource()
            let admission = try await store.metadataAdmission(metadataNamespace)
            let acquired = try await acquireCollectionCatalog(collection)
            let catalog = acquired.catalog
            try Task.checkCancellation()
            guard mutationEpoch == metadata.mutationEpochs[collection, default: 0],
                  await metadataTokenIsCurrent(token) else { throw CancellationError() }
            try await store.storeMetadataCatalog(catalog, key: CollectionKey(namespace: metadataNamespace, collection: collection),
                                                 validatedRun: runID, admission: admission)
            if let membership = acquired.membership {
                for (section, ids) in zip(membership.grouped.snapshot.sections, membership.grouped.itemIDsBySection) {
                    let address = try DayPageAddress(section: section, collection: collection)
                    guard let generation = try await store.metadataDayGeneration(CollectionKey(namespace: metadataNamespace, collection: collection), day: address.day) else { throw CollectionCatalogError.invalidCoverage }
                    let read = try DayPageRead(address: address, dayCount: section.list[0].itemCount, membershipGeneration: UInt64(generation))
                    try await store.storeMetadataIdentityPage(read, entries: ids.map { DayTimelineEntry(id: $0, time: membership.times[$0]!) },
                                                             namespace: metadataNamespace, currentRun: runID, admission: admission)
                }
            }
            guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
            let snapshot = try CollectionDayPager.snapshot(catalog: catalog)
            if metadata.latestTimelines[collection]?.sections != snapshot.sections {
                metadata.latestTimelines[collection] = snapshot
                publishTimelineProjection(snapshot, collection: collection)
            }
            return snapshot
        }
        metadata.timelineJobs[collection] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                              key: String, subscriber: UUID, priority: RequestPriority, forceMembership: Bool) -> Task<PhotoPageSnapshot, Error> {
        let mutationEpoch = metadata.mutationEpochs[collection, default: 0]
        if var job = metadata.pageJobs[key], metadata.pageJobEpochs[key] == mutationEpoch,
           (metadata.pageJobSourceRevisions[key] == nil || metadata.pageJobSourceRevisions[key] == metadata.revision),
           !forceMembership || metadata.forcedMembershipJobs.contains(key) {
            job.subscribers.insert(subscriber); metadata.pageJobs[key] = job
            return job.task
        }
        metadata.pageJobs.removeValue(forKey: key)?.task.cancel()
        let id = UUID()
        let task = Task<PhotoPageSnapshot, Error> {
            let token = try await captureMetadataWorkToken(resource: .page(key: key, collection: collection), jobID: id, collection: collection)
            try await connect()
            try await reconcileMetadataSource()
            _ = try await verifiedTimelineSnapshot(collection: collection)
            guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
            metadata.pageJobSourceRevisions[key] = metadata.revision
            var descriptor = section
            var result: PhotoPageSnapshot?
            for attempt in 0..<2 {
                do {
                    result = try await materializeCurrentPage(descriptor, collection: collection, priority: priority, forceMembership: forceMembership)
                    break
                } catch {
                    guard attempt == 0, await metadataTokenIsCurrent(token), !Task.isCancelled else { throw error }
                    let snapshot: TimelineSnapshot
                    if let mismatch = error as? MetadataMembershipReadFailure {
                        snapshot = try await recoverCollectionMembership(collection, failedReadRevision: mismatch.revision)
                    } else if error is MetadataAdmissionError {
                        snapshot = try await verifiedTimelineSnapshot(collection: collection)
                    } else { throw error }
                    let address = try DayPageAddress(section: descriptor, collection: collection)
                    guard let current = snapshot.sections.first(where: { (try? DayPageAddress(section: $0, collection: collection)) == address }) else { throw CollectionCatalogError.invalidAddress }
                    descriptor = current
                }
            }
            guard let page = result else { throw CollectionCatalogError.invalidCoverage }
            guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
            publishCollectionPage(key: key)
            return page
        }
        metadata.pageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        metadata.pageJobEpochs[key] = mutationEpoch
        metadata.pageJobSourceRevisions.removeValue(forKey: key)
        if forceMembership { metadata.forcedMembershipJobs.insert(key) } else { metadata.forcedMembershipJobs.remove(key) }
        return task
    }

    private func materializeCurrentPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                                        priority: RequestPriority, forceMembership: Bool) async throws -> PhotoPageSnapshot {
        if !forceMembership, let address = try? DayPageAddress(section: section, collection: collection),
           let known = try await store.metadataPage(address, namespace: metadataNamespace, currentRun: runID), known.membershipVerified {
            let missing = known.slots.filter { !$0.verified }.map(\.itemID)
            if missing.isEmpty { return known }
            if missing.count == known.slots.count || missing.count > MetadataReadPlanner.lookupBatchSize {
                return try await loadMetadataPage(section, collection: collection, priority: priority)
            }
            let revision = try await store.metadataState(metadataNamespace).revision
            _ = try await resolveMetadataItems(missing, priority: priority)
            guard let page = try await store.metadataPage(address, namespace: metadataNamespace, currentRun: runID) else { throw CacheError.storage }
            guard page.membershipVerified else { throw MetadataMembershipReadFailure(revision: revision, cause: CollectionCatalogError.invalidCoverage) }
            return page
        }
        return try await loadMetadataPage(section, collection: collection, priority: priority)
    }

    private func releaseTimeline(collection: PhotoCollectionDescriptor, subscriber: UUID) {
        metadata.initialSubscribers.remove(subscriber)
        guard var job = metadata.timelineJobs[collection] else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.timelineJobs.removeValue(forKey: collection); cancelIdleLogin() }
        else { metadata.timelineJobs[collection] = job }
    }

    private func releasePage(key: String?, subscriber: UUID) {
        guard let key, var job = metadata.pageJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty {
            job.task.cancel(); metadata.pageJobs.removeValue(forKey: key); metadata.pageJobEpochs.removeValue(forKey: key); metadata.pageJobSourceRevisions.removeValue(forKey: key); metadata.forcedMembershipJobs.remove(key)
            cancelIdleLogin()
        }
        else { metadata.pageJobs[key] = job }
    }

    func validationRun(for collection: PhotoCollectionDescriptor) -> String {
        "\(runID):\(metadata.admissionEpoch):\(collection.rawValue):\(metadata.mutationEpochs[collection, default: 0])"
    }

    public func latestTimelineSnapshot(collection: PhotoCollectionDescriptor) -> TimelineSnapshot? {
        metadata.latestTimelines[collection]
    }

    private func removeTimelineRefreshObserver(collection: PhotoCollectionDescriptor, id: UUID) {
        metadata.refreshObservers[collection]?.removeValue(forKey: id)
    }
}
