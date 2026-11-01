import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Creates a disposable copy of a cached original for a single still photo.
    /// Live Photo downloads may represent more than the cached still, so they use
    /// the server's item-download endpoint instead.
    public func cachedOriginalForDownload(_ item: PhotoItem, includeLivePhoto: Bool = false) async throws -> PhotoDownloadResponse? {
        guard (item.mediaKind == .photo || (includeLivePhoto && item.mediaKind == .livePhoto)),
              let resource = item.fullImageResource else { return nil }
        return try await originalStillCopy(item, resource: resource, allowNetwork: false, progress: nil)
    }

    /// Editing a Live Photo needs its still, not the ZIP returned by item download.
    public func livePhotoStillForEditing(_ item: PhotoItem,
        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse? {
        guard item.mediaKind == .livePhoto, let resource = item.fullImageResource else { return nil }
        return try await originalStillCopy(item, resource: resource, allowNetwork: true, progress: progress)
    }

    private func originalStillCopy(_ item: PhotoItem, resource: FullImageResource, allowNetwork: Bool,
        progress: (@Sendable (TransferProgress) -> Void)?) async throws -> PhotoDownloadResponse? {
        guard let name = item.filename, !name.isEmpty else { return nil }
        let filename = URL(fileURLWithPath: name).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        for await event in fullImage(resource, allowNetwork: allowNetwork, progress: progress) {
            if case .failure(let message) = event { throw SynologyAPIError.unsupported(message) }
            guard case .value(let data, _) = event, !data.isEmpty else { continue }
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(filename)
            do {
                try data.write(to: file, options: .atomic)
                try Task.checkCancellation()
                return PhotoDownloadResponse(temporaryURL: file, filename: filename)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        try Task.checkCancellation()
        return nil
    }

    public func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                               progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        try await connect()
        return try await client.downloadPhotos(itemIDs: itemIDs, kind: kind, progress: progress)
    }
    /// Incoming IDs are only meaningful in their album's scope. Refresh the grant
    /// immediately before transfer and never reuse personal-space originals.
    public func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, collection: PhotoCollectionDescriptor,
                               progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        let source = mediaCollection(for: collection)
        guard source.incomingAlbumIdentity != nil else {
            guard source == .personalLibrary else { throw SynologyAPIError.unsupported("The album context is unavailable.") }
            return try await downloadPhotos(itemIDs: itemIDs, kind: kind, progress: progress)
        }
        try await connect()
        let rows = try await metadataReadRequest(priority: .visible) { try await client.incomingAlbums() }
        guard let row = rows.first(where: { $0.summary.collection == source }), row.access.view, row.access.download else {
            incomingAccess.removeValue(forKey: source)
            throw SynologyAPIError.unsupported("You no longer have permission to download from this album.")
        }
        incomingAccess[source] = row
        return try await client.downloadIncomingPhotos(itemIDs: itemIDs, kind: kind, reference: row.sharingReference, progress: progress)
    }

}
