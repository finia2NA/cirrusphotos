import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Cached-first, validate-once-per-run stream of the Personal Space album list.
    public func albums() -> AsyncStream<ResourceEvent<[AlbumSummary]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.albumList(namespace: namespace)
                let validation = albumListValidationRun()
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let list = cached.flatMap { try? JSONDecoder().decode([AlbumSummary].self, from: $0.data) }
                if let list {
                    metadata.albumListLatest = list
                    continuation.yield(.value(list, verified: cached?.validatedRun == validation))
                }
                if cached?.validatedRun == validation, list != nil { continuation.finish(); return }
                do {
                    let requestedValidation = albumListValidationRun()
                    let task = registerAlbumList(subscriber: subscriber)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    metadata.albumListLatest = current
                    continuation.yield(.value(current,
                                              verified: requestedValidation == albumListValidationRun()))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) {
                        continuation.yield(.failure("Album list: \(error.localizedDescription)"))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseAlbumList(subscriber: subscriber) }
            }
        }
    }

    private func registerAlbumList(subscriber: UUID) -> Task<[AlbumSummary], Error> {
        if var job = metadata.albumListJob {
            job.subscribers.insert(subscriber)
            metadata.albumListJob = job
            return job.task
        }
        let id = UUID()
        let validation = albumListValidationRun()
        let task = Task<[AlbumSummary], Error> {
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: .visible, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let list = try await client.albums()
            try Task.checkCancellation()
            guard validation == albumListValidationRun() else { throw CancellationError() }
            if let bytes = try? JSONEncoder().encode(list) {
                try? await store.put(CacheKey.albumList(namespace: namespace), kind: .albumList,
                                     data: bytes, validatedRun: validation,
                                     expectedGeneration: generation)
            }
            return list
        }
        metadata.albumListJob = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseAlbumList(subscriber: UUID) {
        guard var job = metadata.albumListJob else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty {
            job.task.cancel()
            metadata.albumListJob = nil
            cancelIdleLogin()
        } else {
            metadata.albumListJob = job
        }
    }

    func albumListValidationRun() -> String { "\(runID):albums" }
}
