import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Complete Tags index, cached first and validated once per run.
    public func tags() -> AsyncStream<ResourceEvent<[TagSummary]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let validation = "\(runID):\(epoch):tags"
                    let cached = try await store.metadataTags(metadataNamespace)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.0, verified: cached.1 == validation)) }
                    if cached?.1 == validation { continuation.finish(); return }
                    let task = registerTags(subscriber: subscriber, validation: validation, epoch: epoch)
                    let tags = try await task.value
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch else { continuation.finish(); return }
                    continuation.yield(.value(tags, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { continuation.yield(.failure("Tags: \(error.localizedDescription)")) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseTags(subscriber: subscriber) }
            }
        }
    }
    private func registerTags(subscriber: UUID, validation: String, epoch: UInt64) -> Task<[TagSummary], Error> {
        if var job = metadata.tagsJob {
            job.subscribers.insert(subscriber); metadata.tagsJob = job; return job.task
        }
        let id = UUID()
        let task = Task<[TagSummary], Error> {
            try await connect()
            try await reconcileMetadataSource()
            let admission = try await store.metadataAdmission(metadataNamespace)
            let list = try await metadataReadRequest(priority: .visible) { try await client.tags() }
            try Task.checkCancellation()
            guard epoch == metadata.admissionEpoch, metadata.tagsJob?.id == id, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
            try await store.storeMetadataTags(list, namespace: metadataNamespace, currentRun: validation, admission: admission)
            guard epoch == metadata.admissionEpoch, metadata.tagsJob?.id == id else { throw MetadataAdmissionError.superseded }
            return list
        }
        metadata.tagsJob = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }
    private func releaseTags(subscriber: UUID) {
        guard var job = metadata.tagsJob else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.tagsJob = nil; cancelIdleLogin() }
        else { metadata.tagsJob = job }
    }
}
