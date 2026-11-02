import Foundation
import SynologyAPI

public struct FolderDirectory: Codable, Sendable {
    public let folder: FolderSummary
    public let children: [FolderSummary]
}

extension CachedPhotosRepository {
    /// A complete child listing is cached per folder and validated once per run.
    public func folderDirectory(id: Int64, space: PhotoSpace = .personal) -> AsyncStream<ResourceEvent<FolderDirectory>> {
        let scopedNamespace = metadataNamespace(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let validation = "\(runID):\(epoch):folders"
                    let cached = try await store.metadataFolderDirectory(scopedNamespace, id: id)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.0, verified: cached.1 == validation)) }
                    if cached?.1 == validation { continuation.finish(); return }
                    let task = registerFolderDirectory(id: id, space: space, subscriber: subscriber, validation: validation, epoch: epoch)
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
                Task { await self.releaseFolderDirectory(id: id, space: space, subscriber: subscriber) }
            }
        }
    }

    private func registerFolderDirectory(id: Int64, space: PhotoSpace, subscriber: UUID, validation: String, epoch: UInt64) -> Task<FolderDirectory, Error> {
        let scopedNamespace = metadataNamespace(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
        let key = PhotoCollectionDescriptor.folder(id).inSpace(space)
        if var job = metadata.folderJobs[key] {
            job.subscribers.insert(subscriber); metadata.folderJobs[key] = job; return job.task
        }
        let jobID = UUID()
        let task = Task<FolderDirectory, Error> {
            try await connect()
            try await reconcileMetadataSource(for: PhotoCollectionDescriptor.personalLibrary.inSpace(space))
            let admission = try await store.metadataAdmission(metadataNamespace)
            let folder = try await metadataReadRequest(priority: .visible) { try await client.folder(id: id, space: space) }
            let children = try await metadataReadRequest(priority: .visible) { try await client.folders(parentID: folder.id, space: space) }
            try Task.checkCancellation()
            guard epoch == metadata.admissionEpoch, metadata.folderJobs[key]?.id == jobID, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
            let result = FolderDirectory(folder: folder, children: children)
            try await store.storeMetadataFolderDirectory(result, namespace: scopedNamespace, id: id, currentRun: validation, admission: admission)
            guard epoch == metadata.admissionEpoch, metadata.folderJobs[key]?.id == jobID else { throw MetadataAdmissionError.superseded }
            return result
        }
        metadata.folderJobs[key] = SharedJob(id: jobID, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseFolderDirectory(id: Int64, space: PhotoSpace, subscriber: UUID) {
        let key = PhotoCollectionDescriptor.folder(id).inSpace(space)
        guard var job = metadata.folderJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); metadata.folderJobs[key] = nil; cancelIdleLogin() }
        else { metadata.folderJobs[key] = job }
    }
}
