import Foundation
import SynologyAPI

/// Resolves the items of a selection for a rating or tag edit through the shared
/// selection verifier.
public struct SelectionAnnotationResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(_ selection: PhotoSelectionSnapshot) async -> SelectionAnnotationAction? {
        let source = await repository.mediaCollection(for: selection.collection)
        guard source.incomingAlbumIdentity == nil,
              let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
              !resolved.items.isEmpty else { return nil }
        return SelectionAnnotationAction(
            itemIDs: resolved.items.map(\.id), collection: selection.collection,
            itemsByID: Dictionary(resolved.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            expectedTimelineFingerprint: selection.timelineFingerprint)
    }
}
