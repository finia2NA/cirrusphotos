import SwiftUI

struct TimelineSectionLoadView: View {
    @EnvironmentObject private var model: TimelineSectionLoadModel
    @State private var useCachedPages = false
    @AppStorage(AppPreferences.Key.warmingIncludesSharedSpace) private var includesSharedSpace = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Load Timeline Sections").font(.title2.weight(.semibold))
            if model.targetTitle != nil {
                Text(includesSharedSpace ? "Personal and Shared Library, Favorites, and All Albums" : "Personal Library, Favorites, and All Albums")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.progress.processed), total: Double(max(1, model.progress.total)))
            Text("\(model.progress.processed) of \(model.progress.total) sections")
            if let matches = model.progress.matchCount { Text("\(matches) matching items") }
            if let current = model.progress.currentSectionLabel { Text(current).foregroundStyle(.secondary) }
            if model.progress.cached > 0 { Text("\(model.progress.cached) cached pages skipped") }
            if let stale = model.staleTimelineMessage {
                Text(stale).foregroundStyle(.orange)
            }
            if model.progress.failed > 0 {
                Text("\(model.progress.failed) failed").foregroundStyle(.orange)
                ScrollView { VStack(alignment: .leading) { ForEach(model.progress.failures, id: \.self) { Text($0).font(.caption) } } }
                    .frame(maxHeight: 120)
            }
            Toggle("Include Shared Space", isOn: $includesSharedSpace)
                .disabled(model.progress.state == .running)
            Toggle("Use Cached Pages", isOn: $useCachedPages)
                .disabled(model.progress.state == .running)
            if model.progress.state != .finished || model.progress.failed > 0 {
                HStack {
                    Spacer()
                    if model.progress.state == .running {
                        Button("Cancel") { model.cancel() }
                    } else {
                        if model.progress.failed > 0 {
                            Button("Retry Failed") { model.retryFailed() }
                                .disabled(model.staleTimelineMessage != nil)
                        }
                        Button("Start") { model.start(useCachedPages: useCachedPages, includeSharedSpace: includesSharedSpace) }
                            .disabled(model.staleTimelineMessage != nil)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear {
            if model.progress.state == .running { model.cancel() }
        }
    }
}
