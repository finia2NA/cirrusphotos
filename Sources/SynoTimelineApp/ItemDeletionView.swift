import SwiftUI

struct ItemDeletionView: View {
    var model: LibraryModel
    let deletion: ItemDeletion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            if deletion.loading {
                ProgressView("Preparing…")
            } else if deletion.deleting {
                ProgressView("Deleting…")
            } else {
                Text("This deletes \(deletion.count == 1 ? "this item" : "these items") from Synology Photos, including every album that contains \(deletion.count == 1 ? "it" : "them"). Synology Photos has no undo for this.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelItemDeletion() }
                    .disabled(deletion.deleting)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { model.confirmItemDeletion() }
                    .disabled(deletion.loading || deletion.deleting)
            }
        }
        .interactiveDismissDisabled()
        .padding(20)
        .frame(width: 400)
    }

    private var title: String {
        let noun = deletion.count == 1 ? "Item" : "Items"
        return "Delete \(deletion.count) \(noun)?"
    }
}
