import PhotoCache
import SwiftUI
import SynologyAPI

/// Permanent deletion of the browser selection.
extension LibraryModel {
    var canDeleteSelection: Bool {
        browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsSpaceItemActions &&
        browserHasSelection && browserCommandSnapshot.timeline != nil &&
        browserCommandSnapshot.authority != nil && itemDeletion == nil && albumOperation == nil && !canCloseViewer
    }

    func beginItemDeletion() {
        guard canDeleteSelection else { return }
        beginItemDeletion(captured: browserCommandSnapshot)
    }

    /// Resolves the captured selection against verified metadata, then waits for
    /// the user's confirmation. Nothing is sent to the NAS before `confirmItemDeletion`.
    func beginItemDeletion(captured: BrowserCommandSnapshot) {
        guard itemDeletion == nil, albumOperation == nil, capabilities(for: captured.collection).allowsSpaceItemActions,
              let repository, let selection = captured.captureSelection(timeline: captured.timeline),
              selection.authority != nil, !selection.selectedOrdinals.isEmpty else { return }
        let operation = ItemDeletion(count: selection.selectedOrdinals.count, collection: selection.collection)
        itemDeletion = operation
        itemDeletionTask = Task { [weak self] in
            let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection)
            guard !Task.isCancelled, let self, self.itemDeletion?.id == operation.id else { return }
            guard let resolved, !resolved.items.isEmpty else {
                self.itemDeletion = nil
                self.reportUnverified("Delete", message: "The selected items could not be verified. Try again.")
                return
            }
            self.itemDeletion?.selection = resolved
            self.itemDeletion?.count = resolved.items.count
            self.itemDeletion?.loading = false
        }
    }

    func cancelItemDeletion() {
        itemDeletionTask?.cancel()
        itemDeletionTask = nil
        itemDeletion = nil
    }

    /// Closes the sheet and deletes in the background as a tracked activity. Deletion is never
    /// retried automatically.
    func confirmItemDeletion() {
        guard let operation = itemDeletion, !operation.loading,
              let selection = operation.selection, let repository else { return }
        itemDeletion = nil
        itemDeletionTask = nil
        let collection = operation.collection
        let handle = activity.begin(.deleteItems,
                                    items: selection.items.map { ActivityItem(photo: $0, collection: collection) })
        Task {
            do {
                try await repository.deleteItems(selection)
                handle.succeed()
            } catch {
                handle.fail(error, operation: "Deletion")
            }
        }
    }
}

/// A pending permanent deletion of the browser selection.
struct ItemDeletion: Identifiable {
    let id = UUID()
    var count: Int
    let collection: PhotoCollectionDescriptor
    var selection: ResolvedPhotoSelection?
    var loading = true
}
