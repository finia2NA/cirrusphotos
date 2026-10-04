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
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                if let cached { continuation.yield(.value(cached.data, verified: cached.validatedRun == runID)) }
                guard allowNetwork && cached?.validatedRun != runID else { continuation.finish(); return }
                do {
                    let task = registerFullImage(resource, key: key, subscriber: subscriber,
                                                 priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(current.data, verified: true))
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
            let generation = await store.currentGeneration()
            try await fullImageGate.acquire(priority: priority, id: id)
            do {
                try Task.checkCancellation()
                try await connect()
                let prior = try? await store.get(key)
                var response = try await client.fullImage(resource, etag: prior?.etag,
                                                          lastModified: prior?.lastModified)
                if response.notModified && prior == nil {
                    response = try await client.fullImage(resource, etag: nil, lastModified: nil)
                }
                try Task.checkCancellation()
                let result: FullImageResolution
                if response.notModified, let prior {
                    try? await store.markValidated(key, run: runID, expectedGeneration: generation)
                    result = FullImageResolution(data: prior.data)
                } else {
                    guard let data = response.data else { throw SynologyAPIError.invalidResponse }
                    try? await store.put(key, kind: .fullImage, data: data, validatedRun: runID,
                                         etag: response.etag, lastModified: response.lastModified,
                                         expectedGeneration: generation)
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
        if job.subscribers.isEmpty {
            job.task.cancel()
            imageWork.fullImageJobs.removeValue(forKey: key)
            Task { await fullImageGate.release(job.id) }
            cancelIdleLogin()
        } else {
            imageWork.fullImageJobs[key] = job
        }
    }
}
