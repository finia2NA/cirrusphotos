import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Fetches the server's current list of albums eligible for adding items.
    public func addableAlbums() async throws -> [AlbumSummary] {
        try await initializeMetadataEngine()
        try await connect()
        try await reconcileMetadataSource()
        return try await client.addableAlbums()
    }
    /// Cached-first, validate-once-per-run stream of the Personal Space album list.
    public func albums() -> AsyncStream<ResourceEvent<[AlbumSummary]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do { try await initializeMetadataEngine() }
                catch { continuation.yield(.failure(RepositoryError.record(error, operation: "Album list"))); continuation.finish(); return }
                let validation = albumListValidationRun()
                let epoch = metadata.admissionEpoch
                let cached = try? await store.metadataAlbumSummaries(personalMetadataNamespace)
                guard !Task.isCancelled, isAdmitted(epoch), validation == albumListValidationRun() else { continuation.finish(); return }
                let list = cached?.albums
                if let list {
                    metadata.albums.listLatest = list
                    continuation.yield(.value(list, verified: !metadata.albums.mutationWriting && cached?.validatedRun == validation))
                }
                if metadata.albums.mutationWriting { continuation.finish(); return }
                if cached?.validatedRun == validation, list != nil { continuation.finish(); return }
                do {
                    let requestedValidation = albumListValidationRun()
                    let task = registerAlbumList(subscriber: subscriber)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    metadata.albums.listLatest = current
                    continuation.yield(.value(current,
                                              verified: requestedValidation == albumListValidationRun()))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) {
                        continuation.yield(.failure(RepositoryError.record(error, operation: "Album list")))
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
        if var job = metadata.albums.listJob {
            job.subscribers.insert(subscriber)
            metadata.albums.listJob = job
            return job.task
        }
        let id = UUID()
        let validation = albumListValidationRun()
        let task = Task<[AlbumSummary], Error> {
            let token = try await captureMetadataWorkToken(resource: .albumList, jobID: id)
            try await connect()
            try await reconcileMetadataSource()
            let admission = try await store.metadataAdmission(personalMetadataNamespace)
            let list = try await metadataReadRequest(priority: .visible, id: id) { try await client.albums() }
            try Task.checkCancellation()
            guard validation == albumListValidationRun(), await metadataTokenIsCurrent(token) else { throw CancellationError() }
            try await store.storeMetadataAlbumSummaries(list, namespace: personalMetadataNamespace, currentRun: validation, admission: admission)
            guard await metadataTokenIsCurrent(token) else { throw MetadataAdmissionError.superseded }
            return list
        }
        metadata.albums.listJob = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseAlbumList(subscriber: UUID) {
        guard var job = metadata.albums.listJob else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty {
            job.task.cancel()
            metadata.albums.listJob = nil
            cancelIdleLogin()
        } else {
            metadata.albums.listJob = job
        }
    }

    func albumListValidationRun() -> String { "\(runID):\(metadata.admissionEpoch):albums:\(metadata.albums.listEpoch)" }
}
