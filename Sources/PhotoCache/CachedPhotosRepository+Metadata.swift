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
                let key = CacheKey.timeline(namespace: namespace, collection: collection)
                let validation = validationRun(for: collection)
                let cached = try? await readCachedMetadata(TimelineSnapshot.self, key: key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let snapshot = cached?.value
                if let snapshot {
                    metadata.latestTimelines[collection] = snapshot
                    continuation.yield(.value(snapshot, verified: cached?.entry.validatedRun == validation))
                }
                if cached?.entry.validatedRun == validation, snapshot != nil { continuation.finish(); return }
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
                     allowNetwork: Bool = true,
                     priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        if collection.isMapFilter {
            return mapFilterPage(section, collection: collection,
                                 allowNetwork: allowNetwork, priority: priority)
        }
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection) else {
                    continuation.yield(.failure("The section has no date bounds.")); continuation.finish(); return
                }
                let cached = try? await readCachedMetadata([PhotoItem].self, key: key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let items = cached.map { favorites.applyingOverrides($0.value) }
                let validation = validationRun(for: collection)
                if let items { continuation.yield(.value(items, verified: cached?.entry.validatedRun == validation)) }
                guard allowNetwork && !(cached?.entry.validatedRun == validation && items != nil) else {
                    continuation.finish(); return
                }
                do {
                    let requestedValidation = validationRun(for: collection)
                    let task = registerPage(section, collection: collection, key: key,
                                            subscriber: subscriber, priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(favorites.applyingOverrides(current),
                                              verified: requestedValidation == validationRun(for: collection)))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) &&
                        !(error is NetworkGateError && priority == .prefetch) {
                        continuation.yield(.failure(error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releasePage(key: CacheKey.page(namespace: self.namespace, section: section,
                                                                 collection: collection), subscriber: subscriber) }
            }
        }
    }

    /// Fetches metadata for a session-translated descriptor without reading or writing
    /// authoritative page-cache keys. Used only to reconstruct a frozen viewer playlist.
    func transientPage(_ section: TimelineSection,
                       collection: PhotoCollectionDescriptor,
                       priority: RequestPriority) async throws -> [PhotoItem] {
        let id = UUID()
        let token = try await captureMetadataWorkToken(
            resource: .transient(collection), jobID: id
        )
        try await gate.acquire(.metadata, priority: priority, id: id)
        defer { Task { await gate.release(.metadata) } }
        try await connect()
        let items = try await client.items(in: section, collection: collection)
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
        if collection.isMapFilter {
            for candidate in personalSections(covering: section) {
                guard let candidateKey = CacheKey.page(namespace: namespace, section: candidate,
                                                       collection: .personalLibrary) else { continue }
                if let job = metadata.pageJobs[candidateKey] { await gate.promote(job.id) }
            }
            return
        }
        if let job = metadata.pageJobs[key] {
            await gate.promote(job.id)
        } else if !metadata.pendingPagePromotions.contains(key) {
            metadata.pendingPagePromotions.append(key)
            if metadata.pendingPagePromotions.count > 64 { metadata.pendingPagePromotions.removeFirst() }
        }
    }

    private func initialTimeline(id: UUID, collection: PhotoCollectionDescriptor) async throws -> TimelineSnapshot {
        metadata.initialSubscribers.insert(id)
        defer { metadata.initialSubscribers.remove(id); cancelIdleLogin() }
        let token = try await captureMetadataWorkToken(
            resource: .transient(collection), jobID: id, collection: collection
        )
        try await gate.acquire(.metadata, priority: .visible, id: id)
        defer { Task { await gate.release(.metadata) } }
        try Task.checkCancellation()
        try await connect()
        let snapshot = try await client.timeline(collection: collection, initial: true)
        guard await metadataTokenIsCurrent(token) else { throw CancellationError() }
        return snapshot
    }

    private func registerTimeline(collection: PhotoCollectionDescriptor,
                                  subscriber: UUID) -> Task<TimelineSnapshot, Error> {
        if var job = metadata.timelineJobs[collection] {
            job.subscribers.insert(subscriber)
            metadata.timelineJobs[collection] = job
            return job.task
        }
        let id = UUID()
        let validation = validationRun(for: collection)
        let mutationEpoch = metadata.mutationEpochs[collection, default: 0]
        let task = Task<TimelineSnapshot, Error> {
            let token = try await captureMetadataWorkToken(
                resource: .timeline(collection), jobID: id, collection: collection
            )
            let key = CacheKey.timeline(namespace: namespace, collection: collection)
            let prior = try? await store.get(key)
            try await gate.acquire(.metadata, priority: .visible, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let snapshot: TimelineSnapshot
            if let albumID = collection.albumID {
                snapshot = try await client.albumTimeline(albumID: albumID)
            } else {
                snapshot = try await client.timeline(collection: collection, initial: false)
            }
            try Task.checkCancellation()
            guard validation == validationRun(for: collection),
                  mutationEpoch == metadata.mutationEpochs[collection, default: 0],
                  await metadataTokenIsCurrent(token) else {
                throw CancellationError()
            }
            let commit = try? await commitMetadata(
                snapshot, key: key, kind: .timeline, validatedRun: validation,
                token: token, replacing: rowExpectation(for: prior)
            )
            if commit == .superseded || commit == .generationChanged {
                throw CancellationError()
            }
            return snapshot
        }
        metadata.timelineJobs[collection] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                              key: String, subscriber: UUID,
                              priority: RequestPriority) -> Task<[PhotoItem], Error> {
        let promoted = metadata.pendingPagePromotions.contains(key)
        metadata.pendingPagePromotions.removeAll(where: { $0 == key })
        let effectivePriority: RequestPriority = promoted ? .visible : priority
        let mutationEpoch = metadata.mutationEpochs[collection, default: 0]
        if var job = metadata.pageJobs[key], metadata.pageJobEpochs[key] == mutationEpoch {
            job.subscribers.insert(subscriber)
            metadata.pageJobs[key] = job
            if effectivePriority == .visible { Task { await gate.promote(job.id) } }
            return job.task
        }
        metadata.pageJobs.removeValue(forKey: key)?.task.cancel()
        metadata.pageJobEpochs.removeValue(forKey: key)
        let id = UUID()
        let validation = validationRun(for: collection)
        let task = Task<[PhotoItem], Error> {
            let token = try await captureMetadataWorkToken(
                resource: .page(key: key, collection: collection),
                jobID: id,
                collection: collection
            )
            let prior = try? await store.get(key)
            try await gate.acquire(.metadata, priority: effectivePriority, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let items = try await client.items(in: section, collection: collection)
            try Task.checkCancellation()
            guard validation == validationRun(for: collection),
                  mutationEpoch == metadata.mutationEpochs[collection, default: 0],
                  await metadataTokenIsCurrent(token) else {
                throw CancellationError()
            }
            var expectation = rowExpectation(for: prior)
            for _ in 0..<3 {
                let current = favorites.applyingOverrides(items)
                let commit = try? await commitMetadata(
                    current, key: key, kind: .page, validatedRun: validation,
                    token: token, replacing: expectation
                )
                switch commit {
                case .superseded:
                    guard let latest = try? await store.get(key) else {
                        expectation = .absent
                        continue
                    }
                    expectation = .revision(latest.revision)
                case .generationChanged:
                    throw CancellationError()
                case .stored, .notRetained, nil:
                    return current
                }
            }
            throw MetadataAdmissionError.superseded
        }
        metadata.pageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        metadata.pageJobEpochs[key] = mutationEpoch
        return task
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
            job.task.cancel(); metadata.pageJobs.removeValue(forKey: key); metadata.pageJobEpochs.removeValue(forKey: key)
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
