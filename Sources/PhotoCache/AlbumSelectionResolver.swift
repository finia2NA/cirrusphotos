import Foundation
import SynologyAPI

/// Resolves an entire verified album without involving a browser selection.
public struct AlbumSelectionResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    /// Returns nil when the album cannot be verified, and an empty array when it
    /// contains no eligible still images.
    public func resolve(albumID: Int64) async -> [PhotoItem]? {
        let collection = PhotoCollectionDescriptor.album(albumID)
        guard let timeline = try? await repository.verifiedTimelineSnapshot(collection: collection),
              !Task.isCancelled else { return nil }
        let index = LibraryIndex(snapshot: timeline)
        guard index.totalCount > 0 else {
            guard let authority = await repository.selectionAuthority(collection: collection, snapshot: timeline),
                  await repository.verifySelectionFence(authority, proofs: []), !Task.isCancelled else { return nil }
            return []
        }
        let selection = PhotoSelectionSnapshot(collection: collection, timeline: timeline,
            timelineFingerprint: index.fingerprint, selectedOrdinals: IndexSet(integersIn: 0..<index.totalCount),
            knownItemIDsByOrdinal: [:])
        return await SelectionDownloadResolver(repository: repository).resolve(selection)
    }
}
