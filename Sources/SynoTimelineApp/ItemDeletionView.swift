import SwiftUI

struct ItemDeletionView: View {
    var model: LibraryModel
    let deletion: ItemDeletion

    var body: some View {
        SheetScaffold(title: title) {
            if deletion.loading {
                SheetPlaceholder(state: .loading("Preparing…"), minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Synology Photos has no undo for this.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(deletion.count == 1 ? "This item is" : "These items are") deleted from Synology Photos, including every album that contains \(deletion.count == 1 ? "it" : "them").")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            Button("Cancel") { model.cancelItemDeletion() }
                .keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) { model.confirmItemDeletion() }
                .disabled(deletion.loading)
        }
        .interactiveDismissDisabled()
    }

    private var title: String {
        let noun = deletion.count == 1 ? "Item" : "Items"
        return "Delete \(deletion.count.formatted()) \(noun)?"
    }
}
