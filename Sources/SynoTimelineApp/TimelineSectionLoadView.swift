import SwiftUI

struct TimelineSectionLoadView: View {
    @EnvironmentObject private var filter: LibraryFilterModel
    @State private var useCachedPages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Load Timeline Sections").font(.title2.weight(.semibold))
            ProgressView(value: Double(filter.progress.processed), total: Double(max(1, filter.progress.total)))
            Text("\(filter.progress.processed) of \(filter.progress.total) sections")
            if let matches = filter.progress.matchCount, filter.isActive { Text("\(matches) matching items") }
            if let current = filter.progress.currentSectionLabel { Text(current).foregroundStyle(.secondary) }
            if filter.progress.provisional > 0 { Text("\(filter.progress.provisional) cached, awaiting verification") }
            if filter.progress.failed > 0 {
                Text("\(filter.progress.failed) failed").foregroundStyle(.orange)
                ScrollView { VStack(alignment: .leading) { ForEach(filter.progress.failures, id: \.self) { Text($0).font(.caption) } } }
                    .frame(maxHeight: 120)
            }
            Toggle("Use Cached Pages", isOn: $useCachedPages)
                .disabled(filter.progress.state == .running)
            if filter.progress.state == .running || filter.progress.remaining > 0 {
                HStack {
                    Spacer()
                    if filter.progress.state == .running {
                        Button("Cancel") { filter.cancel() }
                    } else {
                        Button("Start") { filter.loadAll(useCachedPages: useCachedPages) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!filter.isReady)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear {
            if filter.progress.state == .running { filter.cancel() }
        }
    }
}
