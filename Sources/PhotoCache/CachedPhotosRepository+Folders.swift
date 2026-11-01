import Foundation
import SynologyAPI

public struct FolderDirectory: Codable, Sendable {
    public let folder: FolderSummary
    public let children: [FolderSummary]
}

extension CachedPhotosRepository {
    /// A complete child listing is cached per folder and validated once per run.
    public func folderDirectory(id: Int64) -> AsyncStream<ResourceEvent<FolderDirectory>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let validation = "\(runID):\(epoch):folders"
                    let cached = try await store.metadataFolderDirectory(metadataNamespace, id: id)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.0, verified: cached.1 == validation)) }
                    if cached?.1 == validation { continuation.finish(); return }
                    let task = registerFolderDirectory(id: id, subscriber: subscriber, validation: validation, epoch: epoch)
                    let result = try await task.value
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch else { continuation.finish(); return }
                    continuation.yield(.value(result, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) { continuation.yield(.failure("Folders: \(error.localizedDescription)")) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseFolderDirectory(id: id, subscriber: subscriber) }
            }
        }
    }

    private func registerFolderDirectory(id: Int64, subscriber: UUID, validation: String, epoch: UInt64) -> Task<FolderDirectory, Error> {
        if var job = metadata.folderJobs[id] {
            job.subscribers.insert(subscriber); metadata.folderJobs[id] = job; return job.task
        }
        let jobID = UUID()
        let task = Task<FolderDirectory, Error> {
            try await connect()
            try await reconcileMetadataSource()
            let admission = try await store.metadataAdmission(metadataNamespace)
            let folder = try await metadataReadRequest(priority: .visible) { try await client.folder(id: id) }
            let children = try await metadataReadRequest(priority: .visible) { try await client.folders(parentID: folder.id) }
            try Task.checkCancellation()
            guard epoch == metadata.admissionEpoch, metadata.folderJobs[id]?.id == jobID, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
            let result = FolderDirectory(folder: folder, children: children)
            try await store.storeMetadataFolderDirectory(result, namespace: metadataNamespace, id: id, currentRun: validation, admission: admission)
            guard epoch == metadata.admissionEpoch, metadata.folderJobs[id]?.id == jobID else { throw MetadataAdmissionError.superseded }
            return result
        }
        metadata.folderJobs[id] = SharedJob(id: jobID, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseFolderDirectory(id: Int64, subscriber: UUID) {
        guard var job = metadata.folderJobs[id] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.folderJobs[id] = nil; cancelIdleLogin() }
        else { metadata.folderJobs[id] = job }
    }
}
