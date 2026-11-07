import Foundation
import SynologyAPI

/// Resolves the still images of a selection through the shared selection verifier.
/// Videos and items without thumbnails are omitted.
public struct SelectionRotationResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(_ selection: PhotoSelectionSnapshot) async -> SelectionRotationAction? {
        let source = await repository.mediaCollection(for: selection.collection)
        guard source.incomingAlbumIdentity == nil, !source.isLibraryFilter,
              let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection) else { return nil }
        let sections = selection.sectionsByItemID(resolved.items)
        let items = resolved.items.filter { $0.hasDisplayableStillImage && $0.additional?.thumbnail != nil }
        return SelectionRotationAction(
            itemIDs: items.map(\.id), sectionsByID: sections.filter { id, _ in items.contains { $0.id == id } },
            collection: selection.collection,
            itemsByID: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            expectedTimelineFingerprint: selection.timelineFingerprint)
    }
}
