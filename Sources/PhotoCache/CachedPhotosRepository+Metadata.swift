import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func timeline(collection: PhotoCollectionDescriptor = .personalLibrary) -> AsyncStream<ResourceEvent<TimelineSnapshot>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.timeline(namespace: namespace, collection: collection)
                let validation = validationRun(for: collection)
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let snapshot = cached.flatMap { try? JSONDecoder().decode(TimelineSnapshot.self, from: $0.data) }
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
                     allowNetwork: Bool = true,
                     priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection) else {
                    continuation.yield(.failure("The section has no date bounds.")); continuation.finish(); return
                }
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let items = cached.flatMap { try? JSONDecoder().decode([PhotoItem].self, from: $0.data) }
                    .map { favorites.applyingOverrides($0) }
                let validation = validationRun(for: collection)
                if let items { continuation.yield(.value(items, verified: cached?.validatedRun == validation)) }
                guard allowNetwork && !(cached?.validatedRun == validation && items != nil) else {
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
        try await gate.acquire(.metadata, priority: priority, id: id)
        defer { Task { await gate.release(.metadata) } }
        try await connect()
        let items = try await client.items(in: section, collection: collection)
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
        try await gate.acquire(.metadata, priority: .visible, id: id)
        defer { Task { await gate.release(.metadata) } }
        try Task.checkCancellation()
        try await connect()
        return try await client.timeline(collection: collection, initial: true)
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
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: .visible, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let snapshot = try await client.timeline(collection: collection, initial: false)
            try Task.checkCancellation()
            guard validation == validationRun(for: collection),
                  mutationEpoch == metadata.mutationEpochs[collection, default: 0] else {
                throw CancellationError()
            }
            if let bytes = try? JSONEncoder().encode(snapshot) {
                try? await store.put(CacheKey.timeline(namespace: namespace, collection: collection), kind: .timeline,
                                     data: bytes, validatedRun: validation,
                                     expectedGeneration: generation)
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
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: effectivePriority, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let items = try await client.items(in: section, collection: collection)
            try Task.checkCancellation()
            guard validation == validationRun(for: collection),
                  mutationEpoch == metadata.mutationEpochs[collection, default: 0] else {
                throw CancellationError()
            }
            let current = favorites.applyingOverrides(items)
            if let bytes = try? JSONEncoder().encode(current) {
                try? await store.put(key, kind: .page, data: bytes,
                                     validatedRun: validation,
                                     expectedGeneration: generation)
            }
            return favorites.applyingOverrides(current)
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
        "\(runID):\(collection.rawValue):\(metadata.mutationEpochs[collection, default: 0])"
    }

    public func latestTimelineSnapshot(collection: PhotoCollectionDescriptor) -> TimelineSnapshot? {
        metadata.latestTimelines[collection]
    }

    private func removeTimelineRefreshObserver(collection: PhotoCollectionDescriptor, id: UUID) {
        metadata.refreshObservers[collection]?.removeValue(forKey: id)
    }
}
