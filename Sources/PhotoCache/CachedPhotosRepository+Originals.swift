import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Returns compressed original-image bytes. Cached bytes arrive first and are then
    /// validated at most once per app run when network access is allowed.
    public func fullImage(_ resource: FullImageResource, allowNetwork: Bool = true,
                          priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<Data>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.fullImage(namespace: namespace, resource: resource)
                let cached: CacheEntry?
                do {
                    cached = try await store.get(key)
                } catch {
                    cached = nil
                    SynologyDiagnostics.originals.error(
                        "Original cache read failed unit_id=\(resource.unitID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                guard !Task.isCancelled else { continuation.finish(); return }
                if let cached {
                    SynologyDiagnostics.originals.debug(
                        "Original cache hit unit_id=\(resource.unitID, privacy: .public) bytes=\(cached.data.count, privacy: .public) validated_this_run=\(cached.validatedRun == self.runID, privacy: .public)"
                    )
                    continuation.yield(.value(cached.data, verified: cached.validatedRun == runID))
                } else {
                    SynologyDiagnostics.originals.debug(
                        "Original cache miss unit_id=\(resource.unitID, privacy: .public)"
                    )
                }
                guard allowNetwork && cached?.validatedRun != runID else {
                    SynologyDiagnostics.originals.debug(
                        "Original network request skipped unit_id=\(resource.unitID, privacy: .public) network_allowed=\(allowNetwork, privacy: .public) already_validated=\(cached?.validatedRun == self.runID, privacy: .public)"
                    )
                    continuation.finish()
                    return
                }
                do {
                    let task = registerFullImage(resource, key: key, subscriber: subscriber,
                                                 priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(current.data, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) &&
                        !(error is NetworkGateError && priority == .prefetch) {
                        SynologyDiagnostics.originals.error(
                            "Original request failed unit_id=\(resource.unitID, privacy: .public) priority=\(String(describing: priority), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        continuation.yield(.failure(error.localizedDescription))
                    } else if error is CancellationError || Task.isCancelled {
                        SynologyDiagnostics.originals.debug(
                            "Original request cancelled unit_id=\(resource.unitID, privacy: .public)"
                        )
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task {
                    await self.releaseFullImage(
                        key: CacheKey.fullImage(namespace: self.namespace, resource: resource),
                        subscriber: subscriber
                    )
                }
            }
        }
    }

    public func promoteFullImage(_ resource: FullImageResource) async {
        let key = CacheKey.fullImage(namespace: namespace, resource: resource)
        if let job = imageWork.fullImageJobs[key] { await fullImageGate.promote(job.id) }
    }

    private func registerFullImage(_ resource: FullImageResource, key: String, subscriber: UUID,
                                   priority: RequestPriority) -> Task<FullImageResolution, Error> {
        if var job = imageWork.fullImageJobs[key] {
            job.subscribers.insert(subscriber)
            imageWork.fullImageJobs[key] = job
            if priority == .visible { Task { await fullImageGate.promote(job.id) } }
            return job.task
        }
        let id = UUID()
        let task = Task<FullImageResolution, Error> {
            defer { finishFullImageJob(key: key, id: id) }
            let generation = await store.currentGeneration()
            try await fullImageGate.acquire(priority: priority, id: id)
            do {
                try Task.checkCancellation()
                try await connect()
                let prior = try? await store.get(key)
                SynologyDiagnostics.originals.info(
                    "Downloading or validating original unit_id=\(resource.unitID, privacy: .public) priority=\(String(describing: priority), privacy: .public) has_etag=\(prior?.etag != nil, privacy: .public) has_last_modified=\(prior?.lastModified != nil, privacy: .public)"
                )
                var response = try await client.fullImage(resource, etag: prior?.etag,
                                                          lastModified: prior?.lastModified)
                if response.notModified && prior == nil {
                    response = try await client.fullImage(resource, etag: nil, lastModified: nil)
                }
                try Task.checkCancellation()
                let result: FullImageResolution
                if response.notModified, let prior {
                    SynologyDiagnostics.originals.info(
                        "Original validated without replacement unit_id=\(resource.unitID, privacy: .public) bytes=\(prior.data.count, privacy: .public)"
                    )
                    do {
                        try await store.markValidated(key, run: runID, expectedGeneration: generation)
                    } catch {
                        SynologyDiagnostics.originals.error(
                            "Original validation could not be persisted unit_id=\(resource.unitID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                    result = FullImageResolution(data: prior.data)
                } else {
                    guard let data = response.data else { throw SynologyAPIError.invalidResponse }
                    SynologyDiagnostics.originals.info(
                        "Original downloaded unit_id=\(resource.unitID, privacy: .public) bytes=\(data.count, privacy: .public)"
                    )
                    do {
                        try await store.put(key, kind: .fullImage, data: data, validatedRun: runID,
                                            etag: response.etag, lastModified: response.lastModified,
                                            expectedGeneration: generation)
                    } catch {
                        SynologyDiagnostics.originals.error(
                            "Original download could not be cached unit_id=\(resource.unitID, privacy: .public) bytes=\(data.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                    result = FullImageResolution(data: data)
                }
                await fullImageGate.release(id)
                return result
            } catch {
                await fullImageGate.release(id)
                throw error
            }
        }
        imageWork.fullImageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseFullImage(key: String, subscriber: UUID) {
        guard var job = imageWork.fullImageJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty && !imageWork.fullImageFinishWithoutSubscribers.contains(key) {
            job.task.cancel()
            imageWork.fullImageJobs.removeValue(forKey: key)
            Task { await fullImageGate.release(job.id) }
            cancelIdleLogin()
        } else {
            imageWork.fullImageJobs[key] = job
        }
    }

    private func finishFullImageJob(key: String, id: UUID) {
        imageWork.fullImageFinishWithoutSubscribers.remove(key)
        guard let job = imageWork.fullImageJobs[key], job.id == id,
              job.subscribers.isEmpty else { return }
        imageWork.fullImageJobs.removeValue(forKey: key)
        cancelIdleLogin()
    }
}
