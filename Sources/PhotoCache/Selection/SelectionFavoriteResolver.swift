import Foundation
import SynologyAPI

/// Resolves the favorite change for a selection through the shared selection verifier.
/// A selection containing any unfavorited item favorites those items; an all-favorite
/// selection unfavorites every item.
public struct SelectionFavoriteResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(_ selection: PhotoSelectionSnapshot) async -> SelectionFavoriteAction? {
        guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection) else { return nil }
        let sections = selection.sectionsByItemID(resolved.items)
        let target = resolved.items.contains { !$0.isFavorite }
        let affected = resolved.items.filter { $0.isFavorite != target }
        return SelectionFavoriteAction(
            affectedIDs: affected.map(\.id), targetFavorite: target,
            sectionsByID: sections.filter { id, _ in affected.contains { $0.id == id } },
            collection: selection.collection,
            itemsByID: Dictionary(uniqueKeysWithValues: affected.map { ($0.id, $0) }),
            expectedTimelineFingerprint: selection.timelineFingerprint)
    }
}
