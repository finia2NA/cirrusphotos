import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Resolve transient filter collections to the source that owns their media.
    public func mediaCollection(for collection: PhotoCollectionDescriptor) -> PhotoCollectionDescriptor {
        var source = collection
        var seen: Set<PhotoCollectionDescriptor> = []
        while let filterID = source.libraryFilterID {
            guard seen.insert(source).inserted, let state = metadata.libraryFilters[filterID] else { return source }
            source = state.registration.sourceCollection
        }
        if let id = source.mapFilterID {
            guard let map = metadata.mapFilters[id] else { return source }
            return PhotoCollectionDescriptor.personalLibrary.inSpace(map.space)
        }
        return source.albumID == nil && source.incomingAlbumIdentity == nil && source.space != .shared ? .personalLibrary : source
    }

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
                    guard !Task.isCancelled, epoch == metadata.admissionEpoch, !metadata.resetInProgress else { throw MetadataAdmissionError.superseded }
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
                    if !Task.isCancelled { continuation.yield(.failure("Shared albums: \(error.localizedDescription)")) }
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
              !selection.items.isEmpty, !metadata.albumMutationInProgress else {
            throw SynologyAPIError.unsupported("This selection cannot be added to the shared album.")
        }
        metadata.albumMutationInProgress = true
        defer { metadata.albumMutationInProgress = false }
        try await connect()
        let rows = try await metadataReadRequest(priority: .visible) { try await client.incomingAlbums() }
        guard let row = rows.first(where: { $0.summary.collection == collection }), row.access.view, row.access.upload else {
            incomingAccess.removeValue(forKey: collection)
            throw SynologyAPIError.unsupported("You no longer have permission to add photos to this album.")
        }
        incomingAccess[collection] = row
        guard await verifySelectionFence(selection.authority, proofs: selection.proofs) else {
            throw SynologyAPIError.unsupported("The selected items could not be verified. Try again.")
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
