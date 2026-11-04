import SwiftUI

struct AlbumOperationView: View {
    var model: LibraryModel
    let operation: AlbumOperation
    @State private var name = ""
    @State private var albumID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            if operation.loading {
                ProgressView(operation.writing ? "Updating album…" : "Preparing…")
            } else {
                switch operation.kind {
                case .create:
                    TextField("Album name", text: $name)
                case .add:
                    if operation.albums.isEmpty {
                        Text("No albums available.")
                    } else {
                        List(selection: $albumID) {
                            ForEach(operation.albums) { album in
                                Text(album.name).tag(album.id)
                            }
                        }.frame(height: 220)
                    }
                case .remove:
                    Text("Remove \(operation.selection?.items.count ?? 0) selected items from this album?")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelAlbumOperation() }
                    .disabled(operation.writing)
                Button(actionTitle) { model.submitAlbumOperation(name: name, albumID: albumID) }
                    .disabled(operation.loading || (operation.kind == .create && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (operation.kind == .add && albumID == nil))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled()
        .padding(20)
        .frame(width: 380)
    }

    private var title: String {
        switch operation.kind { case .create: "New Album"; case .add: "Add to Album"; case .remove: "Remove from Album" }
    }
    private var actionTitle: String {
        switch operation.kind { case .create: "Create"; case .add: "Add"; case .remove: "Remove" }
    }
}
