import SwiftUI

struct AlbumOperationView: View {
    var model: LibraryModel
    let operation: AlbumOperation
    @State private var name = ""
    @State private var albumID: Int64?
    @FocusState private var nameFocused: Bool

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle) {
            Group {
                if let error = operation.loadError {
                    SheetPlaceholder(state: .failure(error), minHeight: contentHeight)
                } else if operation.loading {
                    SheetPlaceholder(state: .loading("Preparing…"), minHeight: contentHeight)
                } else {
                    content
                }
            }
        } trailing: {
            Button("Cancel") { model.cancelAlbumOperation() }
                .keyboardShortcut(.cancelAction)
            Button(actionTitle, role: operation.kind == .remove ? .destructive : nil) {
                model.submitAlbumOperation(name: name, albumID: albumID)
            }
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var content: some View {
        switch operation.kind {
        case .create:
            TextField("Name", text: $name, prompt: Text("Album name"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onAppear { nameFocused = true }
                .onSubmit { if canSubmit { model.submitAlbumOperation(name: name, albumID: albumID) } }
        case .add:
            if operation.albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "rectangle.stack",
                                       description: Text("Create an album first."))
                    .frame(height: contentHeight)
            } else {
                List(selection: $albumID) {
                    ForEach(operation.albums) { album in
                        HStack {
                            Text(album.name).lineLimit(1)
                            Spacer()
                            Text(album.itemCount.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(album.id)
                    }
                }
                .frame(height: contentHeight)
                .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                    guard let id = ids.first else { return }
                    model.submitAlbumOperation(name: name, albumID: id)
                }
            }
        case .remove:
            Text("The photos stay in your library.")
                .foregroundStyle(.secondary)
        }
    }

    private var contentHeight: CGFloat { operation.kind == .add ? 220 : 60 }

    private var canSubmit: Bool {
        guard !operation.loading, operation.loadError == nil else { return false }
        switch operation.kind {
        case .create: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .add: return albumID != nil
        case .remove: return true
        }
    }

    private var subtitle: String? {
        guard let count = operation.selection?.items.count else { return nil }
        return count == 1 ? "1 selected item" : "\(count.formatted()) selected items"
    }

    private var title: String {
        switch operation.kind { case .create: "New Album"; case .add: "Add to Album"; case .remove: "Remove from Album?" }
    }
    private var actionTitle: String {
        switch operation.kind { case .create: "Create"; case .add: "Add"; case .remove: "Remove" }
    }
}
