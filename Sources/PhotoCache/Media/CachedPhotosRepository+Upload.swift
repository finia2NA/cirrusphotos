import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Upload one local photo or video. A failed request may have reached the NAS, so the
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
        case .folder(_, let target): space = target
        }
        try await reconcileMetadataSource(for: .library(space))
        try await invalidateUploadCollection(.library(space))
        let result: Result<PhotoUploadResult, Error>
        do {
            switch destination {
            case .timeline, .folder:
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
        let folder = destination.folderCollection
        let refresh = Task { try await self.refreshAfterUpload(space, folder: folder) }
        do { try await refresh.value }
        catch {
            if case .success = result { throw RepositoryError.unconfirmed("The upload finished, but the library could not be refreshed. Check the library before retrying.") }
        }
        return try result.get()
    }

    /// Delays between checks for the generated thumbnails of freshly uploaded items. The schedule
    /// ends after about 70 seconds; a NAS that is still busy then is left to the next refresh.
    public static let uploadThumbnailPollDelays: [Duration] = [.seconds(3), .seconds(5), .seconds(10), .seconds(20), .seconds(30)]

    /// The NAS generates thumbnails after an upload, so the refresh that follows it usually
    /// records them as not ready. Reads the items by ID on a bounded schedule and, once every
    /// thumbnail is ready, re-reads the affected collections. Returns whether that happened.
    /// Cancellation ends the schedule; failed checks are skipped.
    public func refreshWhenUploadedThumbnailsAreReady(
        itemIDs: [Int64], destination: PhotoUploadDestination,
        delays: [Duration] = CachedPhotosRepository.uploadThumbnailPollDelays
    ) async throws -> Bool {
        let ids = Array(Set(itemIDs))
        guard !ids.isEmpty, ids.count <= 1_000 else { return false }
        for delay in delays {
            try await Task.sleep(for: delay)
            guard let items = try? await client.items(ids: ids, space: destination.space),
                  items.count == ids.count,
                  items.allSatisfy({ item in
                      guard let thumbnail = item.additional?.thumbnail else { return false }
                      return ThumbnailSize.allCases.allSatisfy(thumbnail.isReady)
                  }) else { continue }
            try await refreshAfterUpload(destination.space, folder: destination.folderCollection)
            return true
        }
        return false
    }

    private func invalidateUploadCollection(_ collection: PhotoCollectionDescriptor) async throws {
        metadata.mutationEpochs[collection, default: 0] &+= 1
        metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
        metadata.collectionRecoveries.removeValue(forKey: collection)?.task.cancel()
        let namespace = metadataNamespace(for: collection)
        let admission = try await store.metadataAdmission(namespace)
        try await store.invalidateMetadataCollection(CollectionKey(namespace: namespace, collection: collection), admission: admission)
        publishMetadataInvalidation(collection: collection)
    }

    /// A folder upload also changes the space library, so both are invalidated and re-read.
    private func refreshAfterUpload(_ space: PhotoSpace, folder: PhotoCollectionDescriptor?) async throws {
        let library = PhotoCollectionDescriptor.library(space)
        try await invalidateUploadCollection(library)
        if let folder { try await invalidateUploadCollection(folder) }
        if folder != nil {
            let namespace = metadataNamespace(for: library)
            try? await store.invalidateMetadataFolderCovers(namespace: namespace, admission: try await store.metadataAdmission(namespace))
        }
        try await reconcileMetadataSource(space: space, force: true)
        for collection in [library] + [folder].compactMap({ $0 }) {
            let snapshot = try await verifiedTimelineSnapshot(collection: collection)
            publishTimelineProjection(snapshot, collection: collection)
        }
    }
}

private extension PhotoUploadDestination {
    var space: PhotoSpace {
        switch self {
        case .timeline(let space), .folder(_, let space): space
        case .album: .personal
        }
    }

    var folderCollection: PhotoCollectionDescriptor? {
        if case .folder(let id, let space) = self { return .folder(id, space: space) }
        return nil
    }
}
