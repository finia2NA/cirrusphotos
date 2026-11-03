import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    func incomingReference(for collection: PhotoCollectionDescriptor) -> String? {
        incomingAccess[mediaCollection(for: collection)]?.sharingReference
    }

    /// Cached summaries never carry a sharing reference or grant network authority.
    public func incomingAlbums() -> AsyncStream<ResourceEvent<[AlbumSummary]>> {
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let listNamespace = MetadataNamespace(account: namespace + "|incoming-albums", scope: .space(.personal))
                    let cached = try await store.metadataAlbumSummaries(listNamespace)
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch else { continuation.finish(); return }
                    if let cached { continuation.yield(.value(cached.albums, verified: false)) }
                    incomingAccess.removeAll()
                    try await connect()
                    let admission = try await store.metadataAdmission(listNamespace)
                    let rows = try await metadataReadRequest(priority: .visible) { try await client.incomingAlbums() }
                    guard !Task.isCancelled, isAdmitted(epoch) else { throw MetadataAdmissionError.superseded }
                    var access: [PhotoCollectionDescriptor: IncomingAlbum] = [:]
                    for row in rows {
                        guard let collection = row.summary.collection, collection.incomingAlbumIdentity != nil,
                              row.access.view, access[collection] == nil else { throw SynologyAPIError.invalidResponse }
                        access[collection] = row
                    }
                    incomingAccess = access
                    let summaries = rows.map(\.summary)
                    try await store.storeMetadataAlbumSummaries(summaries, namespace: listNamespace, currentRun: runID, admission: admission)
                    continuation.yield(.value(summaries, verified: true))
                } catch {
                    if !Task.isCancelled { continuation.yield(.failure(RepositoryError.record(error, operation: "Shared albums"))) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }
}

extension CachedPhotosRepository {
    /// Only a fresh server grant and a verified personal selection authorize contribution.
    public func addItems(_ selection: ResolvedPhotoSelection, toIncomingAlbum collection: PhotoCollectionDescriptor) async throws {
        let source = mediaCollection(for: selection.authority.originatingCollection)
        let space = source.albumID != nil ? try await albumItemSpace(itemIDs: selection.items.map(\.id), collection: source) : source.contentScope.space
        guard collection.incomingAlbumIdentity != nil, space == .personal,
              !selection.items.isEmpty else {
            throw RepositoryError.unavailable("This selection cannot be added to the shared album.")
        }
        try claimMutation(.album, busy: "Another album change is in progress.")
        defer { releaseMutation(.album) }
        try await connect()
        let rows = try await metadataReadRequest(priority: .visible) { try await client.incomingAlbums() }
        guard let row = rows.first(where: { $0.summary.collection == collection }), row.access.view, row.access.upload else {
            incomingAccess.removeValue(forKey: collection)
            throw RepositoryError.unavailable("You no longer have permission to add photos to this album.")
        }
        incomingAccess[collection] = row
        guard await verifySelectionFence(selection.authority, proofs: selection.proofs) else {
            throw RepositoryError.stale("The selected items could not be verified. Try again.")
        }
        metadata.mutationEpochs[collection, default: 0] &+= 1
        metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
        let outcome: Result<Void, Error>
        do { try await client.addItems(selection.items.map(\.id), toSharedAlbumReference: row.sharingReference); outcome = .success(()) }
        catch { outcome = .failure(error) }
        let scoped = metadataNamespace(for: collection)
        let admission = try await store.metadataAdmission(scoped)
        try await store.invalidateMetadataCollection(CollectionKey(namespace: scoped, collection: collection), admission: admission)
        publishMetadataInvalidation(collection: collection)
        try outcome.get()
    }
}
