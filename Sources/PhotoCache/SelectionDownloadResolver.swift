import Foundation
import SynologyAPI

/// Resolves selected still images through the shared selection verifier.
public struct SelectionDownloadResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(_ selection: PhotoSelectionSnapshot) async -> [PhotoItem]? {
        return await SelectionItemResolver(repository: repository).resolve(selection)?.filter(\.hasDisplayableStillImage)
    }

    public func resolve(collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot,
                        selectedOrdinals: IndexSet, knownItemIDsByOrdinal: [Int: Int64],
                        expectedTimelineFingerprint: String? = nil, authority: PhotoSelectionAuthority? = nil) async -> [PhotoItem]? {
        let selection = PhotoSelectionSnapshot(collection: collection, timeline: snapshot,
            timelineFingerprint: expectedTimelineFingerprint ?? LibraryIndex(snapshot: snapshot).fingerprint,
            selectedOrdinals: selectedOrdinals, knownItemIDsByOrdinal: knownItemIDsByOrdinal, authority: authority)
        return await resolve(selection)
    }
}
