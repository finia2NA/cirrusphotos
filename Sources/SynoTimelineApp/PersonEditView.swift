import PhotoCache
import SwiftUI
import SynologyAPI

struct PersonEditRequest: Identifiable {
    let id = UUID()
    let person: PersonSummary
    let space: PhotoSpace
}

struct PersonEditView: View {
    @Environment(\.dismiss) private var dismiss
    let request: PersonEditRequest
    let people: [PersonSummary]
    let repository: CachedPhotosRepository?
    let onFinish: () -> Void
    @State private var name: String
    @State private var target: PersonSummary?
    @State private var hasEdited: Bool
    @State private var remoteSuggestions: [PersonSummary] = []
    @State private var working = false
    @State private var error: String?
    @State private var confirming = false

    init(request: PersonEditRequest, people: [PersonSummary], repository: CachedPhotosRepository?, onFinish: @escaping () -> Void) {
        self.request = request
        self.people = people
        self.repository = repository
        self.onFinish = onFinish
        _name = State(initialValue: request.person.name)
        _hasEdited = State(initialValue: false)
    }

    private var query: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        repository != nil && !working && error == nil && !query.isEmpty
    }
    private var suggestionQuery: String {
        hasEdited && target == nil && !working && error == nil ? query : ""
    }
    private var suggestions: [PersonSummary] {
        guard hasEdited, target == nil, !working, error == nil else { return [] }
        let cached = people.filter {
            $0.id != request.person.id && (query.isEmpty || $0.name.localizedStandardContains(query))
        }
        var seen: Set<Int64> = [request.person.id]
        return Array((remoteSuggestions + cached).filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Person").font(.headline)
            TextField("Name", text: Binding(
                get: { name },
                set: { value in
                    name = value
                    if target == nil {
                        remoteSuggestions = []
                        hasEdited = true
                    }
                }
            ))
            .disabled(working || error != nil)
            if let target {
                HStack(spacing: 10) {
                    personCover(target)
                    VStack(alignment: .leading) {
                        Text(displayName(target))
                        Text("Merge target").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { self.target = nil; hasEdited = true }
                        .disabled(working || error != nil)
                }
            } else if !suggestions.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestions) { person in
                            Button {
                                target = person
                                name = person.name
                                remoteSuggestions = []
                            } label: {
                                HStack(spacing: 10) {
                                    personCover(person)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(person)).lineLimit(1)
                                        Text("\(person.itemCount) items").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(displayName(person)), \(person.itemCount) items")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(error == nil ? "Cancel" : "Close") { dismiss() }.disabled(working)
                Button(target != nil ? "Merge…" : "Rename") {
                    if target != nil { confirming = true } else { submit() }
                }.disabled(!valid)
            }
        }
        .padding(24).frame(width: 400)
        .interactiveDismissDisabled(working)
        .task(id: suggestionQuery) {
            let prefix = suggestionQuery
            guard !prefix.isEmpty, let repository else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let values = try await repository.suggestPeople(prefix: prefix, space: request.space)
                guard !Task.isCancelled, suggestionQuery == prefix else { return }
                remoteSuggestions = values
            } catch {
                // The cached People index remains available when suggestions fail.
            }
        }
        .confirmationDialog("Merge these people?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Merge", role: .destructive) { submit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(displayName(request.person)) will be merged into \(target.map(displayName) ?? "the selected person").")
        }
    }

    private func personCover(_ person: PersonSummary) -> some View {
        AlbumCoverView(thumbnail: person.thumbnail, repository: repository,
                       collection: .library(request.space), cornerRadius: 5,
                       placeholderFont: .body, placeholderSymbol: "person.crop.square", maxPixel: 96)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }

    private func displayName(_ person: PersonSummary) -> String { person.name.isEmpty ? "Unnamed" : person.name }

    private func submit() {
        guard let repository, valid else { return }
        let capturedTarget = target?.id
        let capturedName = query
        working = true
        Task {
            do {
                if let capturedTarget {
                    try await repository.mergePerson(sourceID: request.person.id, targetID: capturedTarget, name: capturedName, space: request.space)
                } else {
                    try await repository.renamePerson(id: request.person.id, name: capturedName, space: request.space)
                }
                onFinish(); dismiss()
            } catch {
                onFinish(); self.error = error.localizedDescription; working = false
            }
        }
    }
}
