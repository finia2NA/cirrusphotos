import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Preserve album authority for thumbnail requests, including filtered album views.
    private func thumbnailCollection(for collection: PhotoCollectionDescriptor) -> PhotoCollectionDescriptor {
        mediaCollection(for: collection)
    }

    /// Provisional metadata can request cached bytes with allowNetwork=false.
    public func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, allowNetwork: Bool,
                          collection: PhotoCollectionDescriptor,
                          priority: RequestPriority = .visible,
                          cachePurpose: ThumbnailCachePurpose = .library) -> AsyncStream<ResourceEvent<Data>> {
        let scope = thumbnailCollection(for: collection)
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard !scope.isSessionDerived else {
                    continuation.yield(.failure(.stale("The source collection is no longer available.")))
                    continuation.finish()
                    return
                }
                let identity = CacheKey.thumbnailIdentity(scope: scope.contentScope, namespace: namespace, descriptor: descriptor, size: size, collection: scope)
                let key = identity.key
                let cached = try? await store.getThumbnail(identity)
                guard !Task.isCancelled else { continuation.finish(); return }
                if cached != nil, cachePurpose == .library {
                    try? await store.promotePreviewThumbnail(key)
                }
                if let cached { continuation.yield(.value(cached.data, verified: cached.validatedRun == runID)) }
                guard allowNetwork && cached?.validatedRun != runID else { continuation.finish(); return }
                do {
                    let task = registerImage(descriptor, size: size, key: key, collection: scope,
                                             subscriber: subscriber, priority: priority,
                                             cachePurpose: cachePurpose)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    if cachePurpose == .library {
                        try? await store.promotePreviewThumbnail(key)
                    }
                    continuation.yield(.value(current.data, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) &&
                        !(error is NetworkGateError && priority == .prefetch) {
                        continuation.yield(.failure(RepositoryError.record(error, operation: "Thumbnail")))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseImage(key: CacheKey.thumbnail(scope: scope.contentScope, namespace: self.namespace, descriptor: descriptor, size: size, collection: scope), subscriber: subscriber) }
            }
        }
    }

    /// Supplies the best already-cached compatible rendition before resolving the exact
    /// configured size. Alternate sizes are never fetched or treated as exact completion.
    public func thumbnailWithFallback(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                                      allowNetwork: Bool,
                                      collection: PhotoCollectionDescriptor,
                                      priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<ThumbnailRenditionValue>> {
        let scope = thumbnailCollection(for: collection)
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            producer.task = Task {
                guard !scope.isSessionDerived else {
                    continuation.yield(.failure(.stale("The source collection is no longer available.")))
                    continuation.finish()
                    return
                }
                let exact = CacheKey.thumbnailIdentity(scope: scope.contentScope, namespace: namespace,
                                                       descriptor: descriptor, size: size, collection: scope)
                let exactCached = try? await store.getThumbnail(exact)
                guard !Task.isCancelled else { continuation.finish(); return }
                if exactCached == nil,
                   let fallback = await bestCachedFallback(descriptor, target: size, collection: scope) {
                    continuation.yield(.value(
                        ThumbnailRenditionValue(data: fallback.entry.data, size: fallback.size,
                                                isExact: false),
                        verified: fallback.entry.validatedRun == runID
                    ))
                }
                guard !Task.isCancelled else { continuation.finish(); return }
                for await event in thumbnail(descriptor, size: size,
                                             allowNetwork: allowNetwork && descriptor.isReady(size),
                                             collection: scope, priority: priority, cachePurpose: .library) {
                    guard !Task.isCancelled else { continuation.finish(); return }
                    switch event {
                    case .value(let data, let verified):
                        continuation.yield(.value(
                            ThumbnailRenditionValue(data: data, size: size, isExact: true),
                            verified: verified
                        ))
                    case .failure(let message):
                        continuation.yield(.failure(message))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    public func setConfiguredThumbnailSize(_ size: ThumbnailSize) async throws {
        try await store.setConfiguredThumbnailSize(size)
    }

    private func bestCachedFallback(_ descriptor: ThumbnailInfo,
                                    target: ThumbnailSize, collection: PhotoCollectionDescriptor) async -> (entry: CacheEntry, size: ThumbnailSize)? {
        for candidate in Self.fallbackSizes(for: target) {
            let identity = CacheKey.thumbnailIdentity(scope: collection.contentScope, namespace: namespace,
                                                      descriptor: descriptor, size: candidate, collection: collection)
            if let entry = try? await store.getThumbnail(identity) { return (entry, candidate) }
        }
        return nil
    }

    private static func fallbackSizes(for target: ThumbnailSize) -> [ThumbnailSize] {
        switch target {
        case .sm: [.m, .xl]
        case .m: [.xl, .sm]
        case .xl: [.m, .sm]
        }
    }

    /// Resolves one thumbnail through the normal shared cache pipeline without retaining bytes.
    /// Bulk callers must use `.prefetch` so visible browsing can move ahead in the gate.
    public func cacheThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, collection: PhotoCollectionDescriptor,
                               priority: RequestPriority = .prefetch) async throws -> ThumbnailCacheOutcome {
        try await cacheThumbnailMeasurement(descriptor, size: size, collection: collection, priority: priority).outcome
    }

    /// Resolves one thumbnail while reporting bytes transferred in a successful image response.
    /// Conditional 304 responses and current-run cache hits report zero downloaded bytes.
    public func cacheThumbnailMeasurement(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                                          collection: PhotoCollectionDescriptor,
                                          priority: RequestPriority = .prefetch,
                                          validateCached: Bool = true) async throws -> ThumbnailCacheMeasurement {
        try Task.checkCancellation()
        let source = thumbnailCollection(for: collection)
        guard !source.isSessionDerived else { throw RepositoryError.stale("The source collection is no longer available.") }
        let identity = CacheKey.thumbnailIdentity(scope: source.contentScope, namespace: namespace, descriptor: descriptor, size: size, collection: source)
        let key = identity.key
        if !validateCached, (try? await store.hasThumbnail(identity)) == true {
            try? await store.promotePreviewThumbnail(key)
            return ThumbnailCacheMeasurement(outcome: .reused, downloadedBytes: 0)
        }
        if let cached = try? await store.getThumbnail(identity), cached.validatedRun == runID {
            try? await store.promotePreviewThumbnail(key)
            return ThumbnailCacheMeasurement(outcome: .reused, downloadedBytes: 0)
        }
        try Task.checkCancellation()
        let subscriber = UUID()
        let task = registerImage(descriptor, size: size, key: key, collection: source,
                                 subscriber: subscriber, priority: priority,
                                 cachePurpose: .library)
        return try await withTaskCancellationHandler {
            do {
                let resolution = try await task.value
                try Task.checkCancellation()
                try? await store.promotePreviewThumbnail(key)
                releaseImage(key: key, subscriber: subscriber)
                return ThumbnailCacheMeasurement(outcome: resolution.outcome,
                                                 downloadedBytes: resolution.downloadedBytes)
            } catch {
                releaseImage(key: key, subscriber: subscriber)
                throw error
            }
        } onCancel: {
            Task { await self.releaseImage(key: key, subscriber: subscriber) }
        }
    }

    private func registerImage(_ descriptor: ThumbnailInfo, size: ThumbnailSize, key: String,
                               collection: PhotoCollectionDescriptor,
                               subscriber: UUID, priority: RequestPriority,
                               cachePurpose: ThumbnailCachePurpose) -> Task<ImageResolution, Error> {
        if var job = imageWork.thumbnailJobs[key] {
            job.subscribers.insert(subscriber)
            imageWork.thumbnailJobs[key] = job
            if priority == .visible { Task { await gate.promote(job.id) } }
            return job.task
        }
        let id = UUID()
        let identity = CacheKey.thumbnailIdentity(scope: collection.contentScope, namespace: namespace, descriptor: descriptor, size: size, collection: collection)
        let task = Task<ImageResolution, Error> {
            defer { finishImageJob(key: key, id: id) }
            let generation = await store.currentGeneration()
            try await gate.acquire(.thumbnail, priority: priority, id: id)
            defer { Task { await gate.release(.thumbnail) } }
            try Task.checkCancellation()
            try await connect()
            let prior = try? await store.getThumbnail(identity)
            func request(etag: String?, lastModified: String?) async throws -> MediaResponse {
                if collection.isSessionDerived {
                    throw RepositoryError.unexpected("Collection access is unavailable.")
                }
                if collection.incomingAlbumIdentity != nil {
                    guard let reference = incomingReference(for: collection) else {
                        throw RepositoryError.unavailable("Shared album access is unavailable.")
                    }
                    return try await client.incomingThumbnail(descriptor, size: size, reference: reference,
                                                              etag: etag, lastModified: lastModified)
                }
                if let albumID = collection.albumID {
                    return try await client.albumThumbnail(descriptor, size: size, albumID: albumID, etag: etag, lastModified: lastModified)
                }
                guard let space = collection.space else { throw RepositoryError.unexpected("Collection space is unavailable.") }
                return try await client.thumbnail(descriptor, size: size, space: space, etag: etag, lastModified: lastModified)
            }
            var response = try await request(etag: prior?.etag, lastModified: prior?.lastModified)
            if response.notModified && prior == nil {
                response = try await request(etag: nil, lastModified: nil)
            }
            try Task.checkCancellation()
            if response.notModified, let prior {
                do {
                    try await store.markValidated(key, run: runID, expectedGeneration: generation)
                    return ImageResolution(data: prior.data, outcome: .reused, downloadedBytes: 0)
                } catch {
                    return ImageResolution(data: prior.data, outcome: .cacheWriteFailed, downloadedBytes: 0)
                }
            }
            guard let data = response.data else { throw SynologyAPIError.invalidResponse }
            do {
                try await store.put(key, kind: cachePurpose.kind, data: data, validatedRun: runID,
                                    etag: response.etag, lastModified: response.lastModified,
                                    expectedGeneration: generation, thumbnail: identity)
                return ImageResolution(data: data, outcome: .fetched, downloadedBytes: data.count)
            } catch {
                return ImageResolution(data: data, outcome: .cacheWriteFailed, downloadedBytes: data.count)
            }
        }
        imageWork.thumbnailJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseImage(key: String, subscriber: UUID) {
        guard var job = imageWork.thumbnailJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty && !imageWork.thumbnailFinishWithoutSubscribers.contains(key) {
            job.task.cancel(); imageWork.thumbnailJobs.removeValue(forKey: key); cancelIdleLogin()
        }
        else { imageWork.thumbnailJobs[key] = job }
    }

    private func finishImageJob(key: String, id: UUID) {
        imageWork.thumbnailFinishWithoutSubscribers.remove(key)
        guard let job = imageWork.thumbnailJobs[key], job.id == id,
              job.subscribers.isEmpty else { return }
        imageWork.thumbnailJobs.removeValue(forKey: key)
        cancelIdleLogin()
    }
}
