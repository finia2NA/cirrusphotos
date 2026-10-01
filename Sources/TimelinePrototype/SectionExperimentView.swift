import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

struct SectionExperimentView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var items: [PhotoItem] = []
    @State private var pageVerified = false
    @State private var loadedSectionKey: String?
    @State private var status = "Waiting for timeline…"
    @State private var error: String?

    private var section: TimelineSection? {
        guard let sections = library.snapshot?.sections, sections.indices.contains(207) else { return nil }
        return sections[207]
    }
    private var sectionIdentity: String {
        guard let section, let bounds = section.dateBounds else { return "missing" }
        return "\(bounds.start):\(bounds.end):\(section.offset):\(section.limit):\(library.timelineVerified)"
    }

    var body: some View {
        Group {
            if let section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Section 207").font(.title2.weight(.semibold))
                        Spacer()
                        Text(status).foregroundStyle(.secondary)
                        if let error { Image(systemName: "exclamationmark.circle").help(error) }
                    }
                    Text("\(items.count) of \(section.limit) items · \(library.thumbnailSize.rawValue.uppercased()) thumbnails")
                        .font(.caption).foregroundStyle(.secondary)
                    JustifiedPhotoGrid(items: items, repository: library.repository,
                                       size: library.thumbnailSize, allowNetwork: pageVerified)
                    if let error, items.isEmpty { Text(error).foregroundStyle(.secondary) }
                }
                .padding(20)
                .task(id: sectionIdentity) { await load(section) }
                .onChange(of: library.error) { _, newError in
                    if newError != nil, !pageVerified { status = items.isEmpty ? "Unavailable" : "Offline copy" }
                }
            } else if library.snapshot != nil, library.timelineVerified {
                ContentUnavailableView("Section 207 is unavailable", systemImage: "square.grid.3x3",
                                       description: Text("The current timeline contains fewer than 208 sections."))
            } else {
                ProgressView("Waiting for full timeline…")
            }
        }
        .background(Color(red: 0.065, green: 0.065, blue: 0.07))
    }

    private func load(_ section: TimelineSection) async {
        guard let repository = library.repository else { return }
        if let bounds = section.dateBounds {
            let key = "\(bounds.start):\(bounds.end):\(section.offset):\(section.limit)"
            if loadedSectionKey != key { items = []; loadedSectionKey = key }
        }
        pageVerified = false
        status = "Checking section…"
        error = nil
        for await event in await repository.page(section, allowNetwork: library.timelineVerified) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let page, let verified):
                items = page
                pageVerified = verified
                status = verified ? "Current" : (library.error == nil ? "Cached · Checking" : "Offline copy")
            case .failure(let message):
                error = message
                status = items.isEmpty ? "Could not load" : "Offline copy"
            }
        }
        await library.refreshUsage()
    }
}

/// A reusable, day-grouped row grid. Only visible rows create thumbnail views.
struct JustifiedPhotoGrid: View {
    let items: [PhotoItem]
    let repository: CachedPhotosRepository?
    let size: ThumbnailSize
    let allowNetwork: Bool

    var body: some View {
        GeometryReader { geometry in
            let entries = rowEntries(width: Double(geometry.size.width))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        switch entry.content {
                        case .heading(let date):
                            Text(date)
                                .font(.headline)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                        case .row(let row, let rowItems):
                            HStack(alignment: .top, spacing: row.gap) {
                                ForEach(row.cells.indices, id: \.self) { index in
                                    let cell = row.cells[index]
                                    ThumbnailCell(item: rowItems[index], repository: repository,
                                                  size: size, allowNetwork: allowNetwork)
                                        .frame(width: cell.width, height: row.height)
                                }
                            }
                            .frame(height: row.height)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func rowEntries(width: Double) -> [RowEntry] {
        guard width.isFinite, width > 0 else { return [] }
        var entries: [RowEntry] = []
        var group: [PhotoItem] = []
        var currentDay: String?
        var groupIndex = 0
        func appendGroup() {
            guard let currentDay, !group.isEmpty else { return }
            entries.append(RowEntry(id: "\(groupIndex)-heading", content: .heading(currentDay)))
            let rows = JustifiedRows.layout(aspectRatios: group.map(\.displayAspectRatio),
                                            availableWidth: width)
            for row in rows {
                entries.append(RowEntry(id: "\(groupIndex)-\(row.cells[0].index)",
                                        content: .row(row, row.cells.map { group[$0.index] })))
            }
            groupIndex += 1
        }

        for item in items {
            let day = item.utcDayID
            if currentDay != day {
                appendGroup()
                group = []
                currentDay = day
            }
            group.append(item)
        }
        appendGroup()
        return entries
    }
}

private struct RowEntry: Identifiable {
    enum Content {
        case heading(String)
        case row(JustifiedRows.Row, [PhotoItem])
    }
    let id: String
    let content: Content
}

struct CacheSettingsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        Form {
            Picker("Thumbnail size", selection: $library.thumbnailSize) {
                Text("Small").tag(ThumbnailSize.sm)
                Text("Medium").tag(ThumbnailSize.m)
                Text("Large").tag(ThumbnailSize.xl)
            }
            HStack {
                Text("Maximum cache")
                Slider(value: $library.budgetFraction, in: 0...1)
                Text(ByteCountFormatter.string(fromByteCount: CacheBudget.bytes(at: library.budgetFraction), countStyle: .file))
                    .frame(width: 90, alignment: .trailing)
            }
            HStack {
                Text("Stored data")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: library.cacheUsage, countStyle: .file))
                Button("Clear Cache") { Task { await library.clearCache() } }
            }
        }
        .padding(24).frame(width: 500)
        .task { await library.refreshUsage() }
    }
}
