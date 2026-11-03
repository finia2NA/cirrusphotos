import PhotoCache
import SwiftUI
import SynologyAPI

/// Permanent deletion of the browser selection.
extension LibraryModel {
    var canDeleteSelection: Bool {
        browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsSpaceItemActions &&
        !browserCommandSnapshot.selectedOrdinals.isEmpty && browserCommandSnapshot.timeline != nil &&
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
        let operation = ItemDeletion(count: selection.selectedOrdinals.count)
        itemDeletion = operation
        itemDeletionTask = Task { [weak self] in
            let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection)
            guard !Task.isCancelled, let self, self.itemDeletion?.id == operation.id else { return }
            guard let resolved, !resolved.items.isEmpty else {
                self.itemDeletion = nil
                self.itemDeletionError = "The selected items could not be verified. Try again."
                return
            }
            self.itemDeletion?.selection = resolved
            self.itemDeletion?.count = resolved.items.count
            self.itemDeletion?.loading = false
        }
    }

    func cancelItemDeletion() {
        guard itemDeletion?.deleting != true else { return }
        itemDeletionTask?.cancel()
        itemDeletionTask = nil
        itemDeletion = nil
    }

    func confirmItemDeletion() {
        guard var operation = itemDeletion, !operation.loading, !operation.deleting,
              let selection = operation.selection, let repository else { return }
        operation.deleting = true
        itemDeletion = operation
        itemDeletionTask = Task { [weak self] in
            do { try await repository.deleteItems(selection) }
            catch {
                if !Task.isCancelled { self?.itemDeletionError = reportedFailure(error, operation: "Deletion") }
            }
            guard let self, self.itemDeletion?.id == operation.id else { return }
            self.itemDeletion = nil
        }
    }
}

/// A pending permanent deletion of the browser selection.
struct ItemDeletion: Identifiable {
    let id = UUID()
    var count: Int
    var selection: ResolvedPhotoSelection?
    var loading = true
    var deleting = false
}
