import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Complete People index, cached first and validated once per run.
    public func people() -> AsyncStream<ResourceEvent<[PersonSummary]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let validation = "\(runID):\(epoch):people"
                    let cached = try await store.metadataPeople(metadataNamespace)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.0, verified: cached.1 == validation)) }
                    if cached?.1 == validation { continuation.finish(); return }
                    let task = registerPeople(subscriber: subscriber, validation: validation, epoch: epoch)
                    let people = try await task.value
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch else { continuation.finish(); return }
                    continuation.yield(.value(people, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { continuation.yield(.failure("People: \(error.localizedDescription)")) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releasePeople(subscriber: subscriber) }
            }
        }
    }
    private func registerPeople(subscriber: UUID, validation: String, epoch: UInt64) -> Task<[PersonSummary], Error> {
        if var job = metadata.peopleJob {
            job.subscribers.insert(subscriber); metadata.peopleJob = job; return job.task
        }
        let id = UUID()
        let task = Task<[PersonSummary], Error> {
            try await connect()
            try await reconcileMetadataSource()
            let admission = try await store.metadataAdmission(metadataNamespace)
            let list = try await metadataReadRequest(priority: .visible) { try await client.people() }
            try Task.checkCancellation()
            guard epoch == metadata.admissionEpoch, metadata.peopleJob?.id == id, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
            try await store.storeMetadataPeople(list, namespace: metadataNamespace, currentRun: validation, admission: admission)
            guard epoch == metadata.admissionEpoch, metadata.peopleJob?.id == id else { throw MetadataAdmissionError.superseded }
            return list
        }
        metadata.peopleJob = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }
    private func releasePeople(subscriber: UUID) {
        guard var job = metadata.peopleJob else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.peopleJob = nil; cancelIdleLogin() }
        else { metadata.peopleJob = job }
    }
}
