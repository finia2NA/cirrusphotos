import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Finite index/directory reads share admission, cached delivery and subscriber
    /// ownership. Each caller retains its typed storage and NAS fetch contract.
    func metadataIndex<Key: Hashable & Sendable, Value: Sendable>(
        key: Key, space: PhotoSpace, name: String, guardsPeopleMutations: Bool = false,
        jobs: (WritableKeyPath<MetadataEngineState, [Key: SharedJob<Value>]> & Sendable),
        cached: @escaping @Sendable (DiskCache, MetadataNamespace) async throws -> (Value, String?)?,
        fetch: @escaping @Sendable (any PhotosTransport) async throws -> Value,
        persist: @escaping @Sendable (DiskCache, MetadataNamespace, Value, String, MetadataStoreAdmission) async throws -> Void
    ) -> AsyncStream<ResourceEvent<Value>> {
        let namespace = metadataNamespace(for: space)
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let peopleEpoch = metadata.people.epoch[space, default: 0]
                    let validation = "\(runID):\(epoch):\(name)"
                    let previous = try await cached(store, namespace)
                    guard !Task.isCancelled, isAdmitted(epoch) else { continuation.finish(); return }
                    let writing = guardsPeopleMutations && metadata.people.mutationSpaces.contains(space)
                    guard !guardsPeopleMutations || peopleEpoch == metadata.people.epoch[space, default: 0] else { continuation.finish(); return }
                    if let previous { continuation.yield(.value(previous.0, verified: !writing && previous.1 == validation)) }
                    if writing || previous?.1 == validation { continuation.finish(); return }
                    let task: Task<Value, Error>
                    if var job = metadata[keyPath: jobs][key] {
                        job.subscribers.insert(subscriber)
                        metadata[keyPath: jobs][key] = job
                        task = job.task
                    } else {
                        let id = UUID()
                        task = Task {
                            try await connect()
                            try await reconcileMetadataSource(for: .library(space))
                            let admission = try await store.metadataAdmission(namespace)
                            let value = try await metadataReadRequest(priority: .visible, id: id) { try await fetch(client) }
                            try Task.checkCancellation()
                            guard isAdmitted(epoch), metadata[keyPath: jobs][key]?.id == id else { throw MetadataAdmissionError.superseded }
                            try await persist(store, namespace, value, validation, admission)
                            guard epoch == metadata.admissionEpoch, metadata[keyPath: jobs][key]?.id == id else { throw MetadataAdmissionError.superseded }
                            return value
                        }
                        metadata[keyPath: jobs][key] = SharedJob(id: id, task: task, subscribers: [subscriber])
                    }
                    let value = try await task.value
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, (!guardsPeopleMutations || (peopleEpoch == metadata.people.epoch[space, default: 0] && !metadata.people.mutationSpaces.contains(space))) else { continuation.finish(); return }
                    continuation.yield(.value(value, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { continuation.yield(.failure(RepositoryError.record(error, operation: name))) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseMetadataIndex(key: key, jobs: jobs, subscriber: subscriber) }
            }
        }
    }

    private func releaseMetadataIndex<Key: Hashable & Sendable, Value: Sendable>(
        key: Key, jobs: (WritableKeyPath<MetadataEngineState, [Key: SharedJob<Value>]> & Sendable), subscriber: UUID
    ) {
        guard var job = metadata[keyPath: jobs][key] else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata[keyPath: jobs][key] = nil; cancelIdleLogin() }
        else { metadata[keyPath: jobs][key] = job }
    }
}
