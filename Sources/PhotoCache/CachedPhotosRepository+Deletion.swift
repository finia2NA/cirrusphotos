import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    private static let deletionChunkSize = 500

    /// Permanently deletes the selected library items. The task status the NAS
    /// reports does not identify which items were deleted, so presence is read
    /// back afterwards. Failed and uncertain writes run the same invalidation,
    /// because a request may have reached the NAS.
    @discardableResult
    public func deleteItems(_ selection: ResolvedPhotoSelection) async throws -> Int {
        try claimMutation(.deletion, busy: "Another deletion is in progress.")
        defer { releaseMutation(.deletion) }
        let ids = selection.items.map(\.id)
        let source = mediaCollection(for: selection.authority.originatingCollection)
        guard !ids.isEmpty, Set(ids).count == ids.count, source.incomingAlbumIdentity == nil else {
            throw RepositoryError.unavailable("The selected items cannot be deleted.")
        }
        try await initializeMetadataEngine()
        try await connect()
        let space = try await itemActionSpace(itemIDs: ids, collection: source)
        guard await verifySelectionFence(selection.authority, proofs: selection.proofs) else {
            throw RepositoryError.stale("The selected items could not be verified. Try again.")
        }
        try Task.checkCancellation()
        var writeError: (any Error)?
        do {
            for start in stride(from: 0, to: ids.count, by: Self.deletionChunkSize) {
                try await client.deleteItems(Array(ids[start..<min(start + Self.deletionChunkSize, ids.count)]), space: space)
            }
        } catch { writeError = error }
        let reconciliation = Task { await self.reconcileAfterDeletion(ids, space: space) }
        let outcome = await reconciliation.value
        if let writeError { throw writeError }
        if let failure = outcome.failure { throw failure }
        guard let remaining = outcome.remaining else {
            throw RepositoryError.unconfirmed("Deletion could not be confirmed. Reload before trying again.")
        }
        guard remaining.isEmpty else {
            throw RepositoryError.unconfirmed("\(remaining.count) of \(ids.count) items were not deleted. You may not have permission to delete them.")
        }
        return ids.count
    }

    private struct DeletionOutcome {
        var remaining: [Int64]?
        var failure: (any Error)?
    }

    private func reconcileAfterDeletion(_ ids: [Int64], space: PhotoSpace) async -> DeletionOutcome {
        var outcome = DeletionOutcome()
        do { outcome.remaining = try await presentItemIDs(ids, space: space) }
        catch { outcome.failure = error }
        let confirmed = outcome.remaining.map { Set(ids).subtracting($0).sorted() } ?? []
        do {
            if space == .personal { try await reconcileMetadataSource(force: true) }
            let namespace = metadataNamespace(for: space)
            let admission = try await store.metadataAdmission(namespace)
            try await store.invalidateMetadataAfterDeletion(namespace: namespace, deletedIDs: confirmed, admission: admission)
            try await supersedeMetadataState()
        } catch {
            if outcome.failure == nil { outcome.failure = error }
        }
        return outcome
    }

    private func presentItemIDs(_ ids: [Int64], space: PhotoSpace) async throws -> [Int64] {
        var present: [Int64] = []
        for start in stride(from: 0, to: ids.count, by: MetadataReadPlanner.lookupBatchSize) {
            let chunk = Array(ids[start..<min(start + MetadataReadPlanner.lookupBatchSize, ids.count)])
            let found = try await client.items(ids: chunk, space: space)
            guard Set(found.map(\.id)).isSubset(of: Set(chunk)) else { throw SynologyAPIError.invalidResponse }
            present.append(contentsOf: found.map(\.id))
        }
        return present
    }
}
