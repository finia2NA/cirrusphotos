import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Complete Subjects index, cached first and validated once per run.
    public func subjects(space: PhotoSpace = .personal) -> AsyncStream<ResourceEvent<[SubjectSummary]>> {
        let scopedNamespace = metadataNamespace(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let validation = "\(runID):\(epoch):subjects"
                    let cached = try await store.metadataSubjects(scopedNamespace)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.0, verified: cached.1 == validation)) }
                    if cached?.1 == validation { continuation.finish(); return }
                    let task = registerSubjects(space: space, subscriber: subscriber, validation: validation, epoch: epoch)
                    let subjects = try await task.value
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch else { continuation.finish(); return }
                    continuation.yield(.value(subjects, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { continuation.yield(.failure("Subjects: \(error.localizedDescription)")) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseSubjects(space: space, subscriber: subscriber) }
            }
        }
    }
    private func registerSubjects(space: PhotoSpace, subscriber: UUID, validation: String, epoch: UInt64) -> Task<[SubjectSummary], Error> {
        let scopedNamespace = metadataNamespace(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
        if var job = metadata.subjectsJob[space] {
            job.subscribers.insert(subscriber); metadata.subjectsJob[space] = job; return job.task
        }
        let id = UUID()
        let task = Task<[SubjectSummary], Error> {
            try await connect()
            try await reconcileMetadataSource(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
            let admission = try await store.metadataAdmission(scopedNamespace)
            let list = try await metadataReadRequest(priority: .visible) { try await client.subjects(space: space) }
            try Task.checkCancellation()
            guard epoch == metadata.admissionEpoch, metadata.subjectsJob[space]?.id == id, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
            try await store.storeMetadataSubjects(list, namespace: scopedNamespace, currentRun: validation, admission: admission)
            guard epoch == metadata.admissionEpoch, metadata.subjectsJob[space]?.id == id else { throw MetadataAdmissionError.superseded }
            return list
        }
        metadata.subjectsJob[space] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }
    private func releaseSubjects(space: PhotoSpace, subscriber: UUID) {
        guard var job = metadata.subjectsJob[space] else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.subjectsJob[space] = nil; cancelIdleLogin() }
        else { metadata.subjectsJob[space] = job }
    }
}
