import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func createEmptyAlbum(name: String) async throws -> AlbumSummary {
        try await createAlbum(name: name, itemIDs: [])
    }

    public func deleteAlbum(id: Int64) async throws {
        try await performAlbumMutation(albumID: id, deleting: true) { repository in
            let user = try await repository.client.currentPhotosUserID()
            let album = try await repository.client.album(id: id)
            guard album.type == "normal", album.ownerUserID == user else {
                throw RepositoryError.unavailable("Only the owner can delete a normal album.")
            }
            try await repository.client.deleteAlbum(id: id)
        }
    }

    public func renameAlbum(id: Int64, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepositoryError.invalidInput("Enter an album name.") }
        try await performAlbumMutation(albumID: id) { repository in
            let user = try await repository.client.currentPhotosUserID()
            let album = try await repository.client.album(id: id)
            guard album.type == "normal", album.ownerUserID == user else {
                throw RepositoryError.unavailable("Only the owner can rename a normal album.")
            }
            try await repository.client.renameAlbum(id: id, name: trimmed)
            guard try await repository.client.album(id: id).name == trimmed else {
                throw RepositoryError.unconfirmed("The server did not confirm the album name.")
            }
        }
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
    /// Items of either space are accepted; the NAS resolves them by ID alone.
    public func addMissingItems(_ selection: ResolvedPhotoSelection, toAlbum id: Int64) async throws {
        let source = mediaCollection(for: selection.authority.originatingCollection)
        let sourceSpace = source.albumID != nil ? try await albumItemSpace(itemIDs: selection.items.map(\.id), collection: source) : source.contentScope.space
        guard source.incomingAlbumIdentity == nil else {
            throw RepositoryError.unavailable("Items of incoming albums cannot be added to albums.")
        }
        let collection = PhotoCollectionDescriptor.album(id)
        let timeline = try await verifiedTimelineSnapshot(collection: collection)
        let index = LibraryIndex(snapshot: timeline)
        guard let authority = selectionAuthority(collection: collection, snapshot: timeline) else {
            throw RepositoryError.stale("The destination album could not be verified. Try again.")
        }
        var destination: ResolvedPhotoSelection?
        if index.totalCount > 0 {
            let snapshot = PhotoSelectionSnapshot(collection: collection, timeline: timeline,
                timelineFingerprint: index.fingerprint, selectedOrdinals: IndexSet(integersIn: 0..<index.totalCount),
                knownItemIDsByOrdinal: [:], authority: authority)
            guard let resolved = await SelectionItemResolver(repository: self).resolveWithReceipt(snapshot) else {
                throw RepositoryError.stale("The destination album could not be verified. Try again.")
            }
            destination = resolved
        }
        var existing = Set(destination?.items.map(\.id) ?? [])
        let overlapping = existing.intersection(selection.items.map(\.id))
        if !overlapping.isEmpty {
            // A numeric member ID in a mixed album cannot skip an add from a
            // different space. Resolve the overlapping destination identities.
            let destinationSpace = try await albumItemSpace(itemIDs: Array(overlapping).sorted(), collection: collection)
            if destinationSpace != sourceSpace { existing.subtract(overlapping) }
        }
        let missing = selection.items.map(\.id).filter { !existing.contains($0) }
        guard !missing.isEmpty else {
            guard await verifySelectionFences(selection.authority, proofs: selection.proofs,
                                              authority, proofs: destination?.proofs ?? []) else {
                throw RepositoryError.stale("Album membership changed. Try again.")
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

    func performAlbumMutation<Value: Sendable>(albumID: Int64?, selection: ResolvedPhotoSelection? = nil, destinationAuthority: PhotoSelectionAuthority? = nil, destinationProofs: [SelectionMembershipProof] = [], deleting: Bool = false, operation: @escaping @Sendable (isolated CachedPhotosRepository) async throws -> Value) async throws -> Value {
        try claimMutation(.album, busy: "Another album change is in progress. Try again.")
        metadata.albums.mutationID = albumID
        metadata.albums.mutationWriting = true
        defer { releaseMutation(.album); metadata.albums.mutationWriting = false; metadata.albums.mutationID = nil }
        try await initializeMetadataEngine()
        try await connect()
        try await reconcileMetadataSource()
        // Complete all suspending preparation before the final selection fence.
        // Readers of the destination are already fenced by albumMutationWriting.
        metadata.albums.listEpoch &+= 1
        metadata.albums.listJob?.task.cancel()
        metadata.albums.listJob = nil
        let admission = try await store.metadataAdmission(personalMetadataNamespace)
        try await store.invalidateMetadataAlbumSummaries(personalMetadataNamespace, admission: admission)
        if let selection {
            let source = mediaCollection(for: selection.authority.originatingCollection)
            // A selection from either space may join an owned album. An album source
            // can mix spaces, so its members must resolve to exactly one.
            if source.albumID != nil { _ = try await albumItemSpace(itemIDs: selection.items.map(\.id), collection: source) }
            guard source.incomingAlbumIdentity == nil,
                  !selection.items.isEmpty,
                  await verifySelectionFence(selection.authority, proofs: selection.proofs) else {
                throw RepositoryError.stale("The selected items could not be verified. Try again.")
            }
        }
        if let destinationAuthority {
            guard let selection, await verifySelectionFences(selection.authority, proofs: selection.proofs,
                                                              destinationAuthority, proofs: destinationProofs) else {
                throw RepositoryError.stale("Album membership changed. Try again.")
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
        metadata.albums.mutationWriting = false
        let reconciliation = Task { try await self.reconcileAlbumMutation(albumID: albumID, deleting: deleting) }
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
        let filterIDs = metadata.sessions.libraryFilters.filter { $0.value.registration.sourceCollection == collection }.map(\.key)
        for id in filterIDs {
            if let state = metadata.sessions.libraryFilters.removeValue(forKey: id) {
                metadata.sessions.selectionRetentions.removeValue(forKey: state.registration.descriptor)
                metadata.sessions.deferredUnregisters.remove(state.registration.descriptor)
                metadata.latestTimelines.removeValue(forKey: state.registration.descriptor)
            }
        }
    }

    private func invalidateAlbumMutationState(albumID: Int64?) async throws {
        metadata.albums.listEpoch &+= 1
        metadata.albums.listJob?.task.cancel()
        metadata.albums.listJob = nil
        invalidateAlbumMutationMemory(albumID: albumID)
        if let albumID {
            let collection = PhotoCollectionDescriptor.album(albumID)
            let scopedNamespace = metadataNamespace(for: collection)
            let admission = try await store.metadataAdmission(scopedNamespace)
            try await store.invalidateMetadataCollection(CollectionKey(namespace: scopedNamespace, collection: collection), admission: admission)
            publishMetadataInvalidation(collection: collection)
        }
        let admission = try await store.metadataAdmission(personalMetadataNamespace)
        try await store.invalidateMetadataAlbumSummaries(personalMetadataNamespace, admission: admission)
    }

    private func reconcileAlbumMutation(albumID: Int64?, deleting: Bool) async throws {
        try await invalidateAlbumMutationState(albumID: albumID)
        var refreshError: (any Error)?
        if let albumID, !deleting {
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
            if case .value(let albums, true) = event {
                verified = true
                if deleting, let albumID, albums.contains(where: { $0.id == albumID }) {
                    refreshError = RepositoryError.unconfirmed("The server did not confirm album deletion.")
                }
            }
            if case .failure(let message) = event { failure = message.localizedDescription }
        }
        if !verified, refreshError == nil {
            refreshError = RepositoryError.unavailable("Album list refresh failed: \(failure ?? "The result was superseded.")")
        }
        if let refreshError { throw refreshError }
    }
}
