import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Upload one local image. A failed request may have reached the NAS, so the
    /// same invalidation and refresh runs for both successful and uncertain writes.
    public func uploadPhoto(at url: URL, destination: PhotoUploadDestination,
                            progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult {
        try claimMutation(.upload, busy: "Another upload is in progress.")
        defer { releaseMutation(.upload) }
        try await initializeMetadataEngine()
        try await connect()
        let space: PhotoSpace
        switch destination {
        case .timeline(let target): space = target
        case .album: space = .personal
        }
        try await reconcileMetadataSource(for: .library(space))
        try await invalidateUploadLibrary(space)
        let result: Result<PhotoUploadResult, Error>
        do {
            switch destination {
            case .timeline:
                result = .success(try await client.uploadPhoto(at: url, destination: destination, progress: progress))
            case .album(let id):
                let value = try await performAlbumMutation(albumID: id) { repository in
                    let user = try await repository.client.currentPhotosUserID()
                    let album = try await repository.client.album(id: id)
                    guard album.type == "normal", album.ownerUserID == user else {
                        throw RepositoryError.unavailable("Only owned albums support file uploads.")
                    }
                    return try await repository.client.uploadPhoto(at: url, destination: destination, progress: progress)
                }
                result = .success(value)
            }
        } catch { result = .failure(error) }
        let refresh = Task { try await self.refreshAfterUpload(space) }
        do { try await refresh.value }
        catch {
            if case .success = result { throw RepositoryError.unconfirmed("The upload finished, but the library could not be refreshed. Check the library before retrying.") }
        }
        return try result.get()
    }

    private func invalidateUploadLibrary(_ space: PhotoSpace) async throws {
        let collection = PhotoCollectionDescriptor.library(space)
        metadata.mutationEpochs[collection, default: 0] &+= 1
        metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
        metadata.collectionRecoveries.removeValue(forKey: collection)?.task.cancel()
        let namespace = metadataNamespace(for: collection)
        let admission = try await store.metadataAdmission(namespace)
        try await store.invalidateMetadataCollection(CollectionKey(namespace: namespace, collection: collection), admission: admission)
        publishMetadataInvalidation(collection: collection)
    }

    private func refreshAfterUpload(_ space: PhotoSpace) async throws {
        try await invalidateUploadLibrary(space)
        try await reconcileMetadataSource(space: space, force: true)
        let collection = PhotoCollectionDescriptor.library(space)
        let snapshot = try await verifiedTimelineSnapshot(collection: collection)
        publishTimelineProjection(snapshot, collection: collection)
    }
}
