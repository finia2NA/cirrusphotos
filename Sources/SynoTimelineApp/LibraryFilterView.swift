import PhotoCache
import SwiftUI
import SynologyAPI

struct LibraryFilterToolbarControl: View {
    @EnvironmentObject private var filter: LibraryFilterModel
    @EnvironmentObject private var metadataSync: MetadataSyncModel

    var body: some View {
        Button { filter.draft = filter.committed; filter.isPresented.toggle() } label: {
            Label("Filter Photos",
                  systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .disabled(!filter.isReady)
        .popover(isPresented: $filter.isPresented) { LibraryFilterView().environmentObject(filter).environmentObject(metadataSync) }
        .accessibilityLabel("Filter Photos")
        .accessibilityValue(filter.isActive ? "\(filter.activeCount) active filters" : "No active filters")
        .help(filter.isReady ? "Filter Photos" : "Filter Photos (metadata loading)")
    }
}

struct LibraryFilterView: View {
    @EnvironmentObject private var filter: LibraryFilterModel
    @EnvironmentObject private var metadataSync: MetadataSyncModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filter Photos").font(.headline)
                FilenameSearchField(text: $filter.filenameText,
                                    usesRegularExpression: $filter.filenameUsesRegularExpression)
                HStack {
                    mediaToggle("Photo", .photo)
                    mediaToggle("Video", .video)
                    mediaToggle("Live Photo", .livePhoto)
                }
                FilterFacetView(title: "Camera", values: filter.catalog.cameras, selection: $filter.draft.cameras)
                FilterFacetView(title: "Lens", values: filter.catalog.lenses, selection: $filter.draft.lenses)
                FilterFacetView(title: "File Extension", values: filter.catalog.extensions, selection: $filter.draft.extensions)
                rangeRow("Megapixels", min: $filter.megapixelsMin, max: $filter.megapixelsMax)
                sizeRow
                rangeRow("ISO", min: $filter.isoMin, max: $filter.isoMax)
                rangeRow("Focal Length", min: $filter.focalMin, max: $filter.focalMax, suffix: "mm")
                rangeRow("Aperture", min: $filter.apertureMin, max: $filter.apertureMax)
                rangeRow("Shutter Speed", min: $filter.shutterMin, max: $filter.shutterMax, suffix: "s")
                ForEach(filter.validationErrors.keys.sorted(), id: \.self) { key in
                    Text("\(key): \(filter.validationErrors[key] ?? "")")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack(spacing: 6) {
                    if filter.progress.isDiscoveringCachedPages {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Searching cached filter options")
                    }
                    Text(filter.coverageText).font(.caption).foregroundStyle(.secondary)
                }
                if let status = backgroundLoadingStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Clear") { filter.clear(); filter.isPresented = false }
                    Spacer()
                    Button("Cancel") { filter.isPresented = false }
                    Button("Apply") { filter.apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!filter.isReady || !filter.canApply)
                }
            }
            .padding(16)
        }
        .frame(width: 430)
        .frame(maxHeight: 640)
    }

    /// Background sync status for this filter's source timeline only.
    private var backgroundLoadingStatus: String? {
        guard let source = filter.sourceCollection, let sync = metadataSync.collections[source] else { return nil }
        switch sync.state {
        case .queued: return "Waiting to load metadata in the background"
        case .running: return "Loading metadata in the background: \(sync.verified) of \(sync.total) sections"
        case .done:
            let missing = sync.total - sync.verified
            return missing > 0 ? "\(missing) sections could not be loaded yet; retrying automatically" : nil
        }
    }

    private func mediaToggle(_ title: String, _ kind: PhotoMediaKind) -> some View {
        Toggle(title, isOn: Binding(
            get: { filter.draft.mediaKinds.contains(kind) },
            set: { value in
                if value { filter.draft.mediaKinds.insert(kind) } else { filter.draft.mediaKinds.remove(kind) }
            }))
    }

    private func rangeRow(_ title: String, min: Binding<String>, max: Binding<String>, suffix: String? = nil) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            TextField("Min", text: min).textFieldStyle(.roundedBorder)
            Text("–").foregroundStyle(.secondary)
            TextField("Max", text: max).textFieldStyle(.roundedBorder)
            if let suffix { Text(suffix).foregroundStyle(.secondary) }
        }
    }

    private var sizeRow: some View {
        HStack {
            Text("Size").frame(width: 100, alignment: .leading)
            TextField("Min", text: $filter.sizeMin).textFieldStyle(.roundedBorder)
            Picker("", selection: $filter.sizeMinUnit) { ForEach(LibraryFilterModel.SizeUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
            Text("–").foregroundStyle(.secondary)
            TextField("Max", text: $filter.sizeMax).textFieldStyle(.roundedBorder)
            Picker("", selection: $filter.sizeMaxUnit) { ForEach(LibraryFilterModel.SizeUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
        }
    }
}

private struct FilenameSearchField: View {
    @Binding var text: String
    @Binding var usesRegularExpression: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(usesRegularExpression ? "Filename regular expression" : "Filename", text: $text)
                .textFieldStyle(.plain)
                .font(usesRegularExpression ? .body.monospaced() : .body)
            Button { usesRegularExpression.toggle() } label: {
                Text(".*").font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(usesRegularExpression ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(usesRegularExpression ? "Search as Plain Text" : "Search with a Regular Expression")
            .accessibilityLabel("Regular Expression")
            .accessibilityValue(usesRegularExpression ? "On" : "Off")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private struct FilterFacetView: View {
    let title: String
    let values: [String]
    @Binding var selection: Set<String>
    @State private var search = ""
    @State private var isExpanded = false

    private var visibleValues: [String] {
        let discovered = search.isEmpty ? values : values.filter { $0.localizedCaseInsensitiveContains(search) }
        return Array(Set(discovered).union(selection)).sorted { lhs, rhs in
            title == "File Extension" ? lhs < rhs : lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if values.isEmpty && selection.isEmpty {
                Text("No \(title.lowercased()) values found in loaded sections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Search \(title)", text: $search).textFieldStyle(.roundedBorder)
                LazyVStack(alignment: .leading) {
                    ForEach(visibleValues, id: \.self) { value in
                        Toggle(value, isOn: Binding(
                            get: { selection.contains(value) },
                            set: { enabled in
                                if enabled { selection.insert(value) } else { selection.remove(value) }
                            }))
                    }
                }
            }
        } label: {
            Text(facetTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
        }
    }

    private var facetTitle: String {
        let found = values.count == 1 ? "1 found" : "\(values.count) found"
        let selected = selection.isEmpty ? "" : ", \(selection.count) selected"
        return "\(title) (\(found)\(selected))"
    }
}
