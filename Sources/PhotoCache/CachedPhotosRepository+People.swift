import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Complete People index, cached first and validated once per run.
    public func people(space: PhotoSpace = .personal) -> AsyncStream<ResourceEvent<[PersonSummary]>> {
        let scopedNamespace = metadataNamespace(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let validation = "\(runID):\(epoch):people"
                    let cached = try await store.metadataPeople(scopedNamespace)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.0, verified: cached.1 == validation)) }
                    if cached?.1 == validation { continuation.finish(); return }
                    let task = registerPeople(space: space, subscriber: subscriber, validation: validation, epoch: epoch)
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
                Task { await self.releasePeople(space: space, subscriber: subscriber) }
            }
        }
    }
    private func registerPeople(space: PhotoSpace, subscriber: UUID, validation: String, epoch: UInt64) -> Task<[PersonSummary], Error> {
        let scopedNamespace = metadataNamespace(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
        if var job = metadata.peopleJob[space] {
            job.subscribers.insert(subscriber); metadata.peopleJob[space] = job; return job.task
        }
        let id = UUID()
        let task = Task<[PersonSummary], Error> {
            try await connect()
            try await reconcileMetadataSource(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
            let admission = try await store.metadataAdmission(scopedNamespace)
            let list = try await metadataReadRequest(priority: .visible) { try await client.people(space: space) }
            try Task.checkCancellation()
            guard epoch == metadata.admissionEpoch, metadata.peopleJob[space]?.id == id, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
            try await store.storeMetadataPeople(list, namespace: scopedNamespace, currentRun: validation, admission: admission)
            guard epoch == metadata.admissionEpoch, metadata.peopleJob[space]?.id == id else { throw MetadataAdmissionError.superseded }
            return list
        }
        metadata.peopleJob[space] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }
    private func releasePeople(space: PhotoSpace, subscriber: UUID) {
        guard var job = metadata.peopleJob[space] else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.peopleJob[space] = nil; cancelIdleLogin() }
        else { metadata.peopleJob[space] = job }
    }
}
