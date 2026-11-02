import SwiftUI
import SynologyAPI

struct AlbumRenameView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let album: AlbumSummary
    @State private var name: String
    @State private var working = false
    @State private var error: String?

    init(album: AlbumSummary) {
        self.album = album
        _name = State(initialValue: album.name)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Album").font(.headline)
            TextField("Name", text: $name).disabled(working)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(working)
                Button("Rename") { submit() }
                    .disabled(working || trimmedName.isEmpty || trimmedName == album.name)
            }
        }
        .padding(24).frame(width: 400)
        .interactiveDismissDisabled(working)
    }

    private func submit() {
        let submittedName = trimmedName
        working = true
        error = nil
        Task {
            do {
                try await model.renameAlbum(album.id, name: submittedName)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
