import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func createEmptyAlbum(name: String) async throws -> AlbumSummary {
        try await createAlbum(name: name, itemIDs: [])
    }

    func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary {
        try await performAlbumMutation(albumID: nil) { repository in
            try await repository.client.createAlbum(name: name, itemIDs: itemIDs)
        }
    }

    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws {
        guard !itemIDs.isEmpty else { return }
        try await performAlbumMutation(albumID: id) { repository in
            try await repository.client.addItems(itemIDs, toAlbum: id)
        }
    }

    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws {
        guard !itemIDs.isEmpty else { return }
        try await performAlbumMutation(albumID: id) { repository in
            try await repository.client.removeItems(itemIDs, fromAlbum: id)
        }
    }

    public func createAlbum(name: String, selection: ResolvedPhotoSelection) async throws -> AlbumSummary {
        try await performAlbumMutation(albumID: nil, selection: selection) { repository in
            try await repository.client.createAlbum(name: name, itemIDs: selection.items.map(\.id))
        }
    }

    public func addItems(_ selection: ResolvedPhotoSelection, toAlbum id: Int64) async throws {
        try await performAlbumMutation(albumID: id, selection: selection) { repository in
            try await repository.client.addItems(selection.items.map(\.id), toAlbum: id)
        }
    }

    /// Compare against a verified destination before adding, including videos.
    public func addMissingItems(_ selection: ResolvedPhotoSelection, toAlbum id: Int64) async throws {
        let collection = PhotoCollectionDescriptor.album(id)
        let timeline = try await verifiedTimelineSnapshot(collection: collection)
        let index = LibraryIndex(snapshot: timeline)
        guard let authority = selectionAuthority(collection: collection, snapshot: timeline) else {
            throw SynologyAPIError.unsupported("The destination album could not be verified. Try again.")
        }
        var destination: ResolvedPhotoSelection?
        if index.totalCount > 0 {
            let snapshot = PhotoSelectionSnapshot(collection: collection, timeline: timeline,
                timelineFingerprint: index.fingerprint, selectedOrdinals: IndexSet(integersIn: 0..<index.totalCount),
                knownItemIDsByOrdinal: [:], authority: authority)
            guard let resolved = await SelectionItemResolver(repository: self).resolveWithReceipt(snapshot) else {
                throw SynologyAPIError.unsupported("The destination album could not be verified. Try again.")
            }
            destination = resolved
        }
        let existing = Set(destination?.items.map(\.id) ?? [])
        let missing = selection.items.map(\.id).filter { !existing.contains($0) }
        guard !missing.isEmpty else {
            guard await verifySelectionFences(selection.authority, proofs: selection.proofs,
                                              authority, proofs: destination?.proofs ?? []) else {
                throw SynologyAPIError.unsupported("Album membership changed. Try again.")
            }
            return
        }
        try await performAlbumMutation(albumID: id, selection: selection,
                                       destinationAuthority: authority, destinationProofs: destination?.proofs ?? []) { repository in
            try await repository.client.addItems(missing, toAlbum: id)
        }
    }

    public func removeItems(_ selection: ResolvedPhotoSelection, fromAlbum id: Int64) async throws {
        try await performAlbumMutation(albumID: id, selection: selection) { repository in
            try await repository.client.removeItems(selection.items.map(\.id), fromAlbum: id)
        }
    }

    private func performAlbumMutation<Value: Sendable>(albumID: Int64?, selection: ResolvedPhotoSelection? = nil, destinationAuthority: PhotoSelectionAuthority? = nil, destinationProofs: [SelectionMembershipProof] = [], operation: @escaping @Sendable (isolated CachedPhotosRepository) async throws -> Value) async throws -> Value {
        guard !metadata.albumMutationInProgress else {
            throw SynologyAPIError.unsupported("Another album change is in progress. Try again.")
        }
        metadata.albumMutationInProgress = true
        metadata.albumMutationID = albumID
        metadata.albumMutationWriting = true
        defer { metadata.albumMutationInProgress = false; metadata.albumMutationWriting = false; metadata.albumMutationID = nil }
        try await initializeMetadataEngine()
        try await connect()
        try await reconcileMetadataSource()
        // Complete all suspending preparation before the final selection fence.
        // Readers of the destination are already fenced by albumMutationWriting.
        metadata.albumListEpoch &+= 1
        metadata.albumListJob?.task.cancel()
        metadata.albumListJob = nil
        let admission = try await store.metadataAdmission(metadataNamespace)
        try await store.invalidateMetadataAlbumSummaries(metadataNamespace, admission: admission)
        if let selection {
            guard !selection.items.isEmpty,
                  await verifySelectionFence(selection.authority, proofs: selection.proofs) else {
                throw SynologyAPIError.unsupported("The selected items could not be verified. Try again.")
            }
        }
        if let destinationAuthority {
            guard let selection, await verifySelectionFences(selection.authority, proofs: selection.proofs,
                                                              destinationAuthority, proofs: destinationProofs) else {
                throw SynologyAPIError.unsupported("Album membership changed. Try again.")
            }
        }
        try Task.checkCancellation()
        // No suspension between the final fence and starting the request. Existing
        // destination work is superseded synchronously; disk invalidation follows
        // the request while destination readers remain fenced.
        invalidateAlbumMutationMemory(albumID: albumID)
        var result: Result<Value, Error>
        do {
            let value = try await operation(self)
            try Task.checkCancellation()
            result = .success(value)
        }
        catch { result = .failure(error) }
        // A request may have reached the NAS even when it fails or is cancelled.
        // Unstructured work is independent of the caller's cancellation and must
        // invalidate again before attempting authoritative reads.
        let invalidation = Task { try await self.invalidateAlbumMutationState(albumID: albumID) }
        do { try await invalidation.value }
        catch {
            if case .success = result { result = .failure(error) }
        }
        metadata.albumMutationWriting = false
        let reconciliation = Task { try await self.reconcileAlbumMutation(albumID: albumID) }
        do { try await reconciliation.value }
        catch {
            if case .success = result { result = .failure(error) }
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private func invalidateAlbumMutationMemory(albumID: Int64?) {
        guard let albumID else { return }
        let collection = PhotoCollectionDescriptor.album(albumID)
        metadata.mutationEpochs[collection, default: 0] &+= 1
        metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
        metadata.collectionRecoveries.removeValue(forKey: collection)?.task.cancel()
        let filterIDs = metadata.libraryFilters.filter { $0.value.registration.sourceCollection == collection }.map(\.key)
        for id in filterIDs {
            if let state = metadata.libraryFilters.removeValue(forKey: id) {
                metadata.selectionRetentions.removeValue(forKey: state.registration.descriptor)
                metadata.deferredSelectionUnregisters.remove(state.registration.descriptor)
                metadata.latestTimelines.removeValue(forKey: state.registration.descriptor)
            }
        }
    }

    private func invalidateAlbumMutationState(albumID: Int64?) async throws {
        metadata.albumListEpoch &+= 1
        metadata.albumListJob?.task.cancel()
        metadata.albumListJob = nil
        invalidateAlbumMutationMemory(albumID: albumID)
        if let albumID {
            let collection = PhotoCollectionDescriptor.album(albumID)
            let admission = try await store.metadataAdmission(metadataNamespace)
            try await store.invalidateMetadataCollection(CollectionKey(namespace: metadataNamespace, collection: collection), admission: admission)
            publishMetadataInvalidation(collection: collection)
        }
        let admission = try await store.metadataAdmission(metadataNamespace)
        try await store.invalidateMetadataAlbumSummaries(metadataNamespace, admission: admission)
    }

    private func reconcileAlbumMutation(albumID: Int64?) async throws {
        try await invalidateAlbumMutationState(albumID: albumID)
        var refreshError: (any Error)?
        if let albumID {
            let collection = PhotoCollectionDescriptor.album(albumID)
            do { _ = try await client.album(id: albumID) }
            catch { refreshError = error }
            do {
                // Reuse the normal catalog and identity-page acquisition path.
                let snapshot = try await verifiedTimelineSnapshot(collection: collection)
                publishTimelineProjection(snapshot, collection: collection)
            } catch { if refreshError == nil { refreshError = error } }
        }
        var verified = false
        var failure: String?
        for await event in albums() {
            if case .value(_, true) = event { verified = true }
            if case .failure(let message) = event { failure = message }
        }
        if !verified, refreshError == nil {
            refreshError = SynologyAPIError.unsupported("Album list refresh failed: \(failure ?? "The result was superseded.")")
        }
        if let refreshError { throw refreshError }
    }
}
