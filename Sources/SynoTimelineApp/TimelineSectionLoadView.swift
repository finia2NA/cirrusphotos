import SwiftUI

struct TimelineSectionLoadView: View {
    @EnvironmentObject private var model: TimelineSectionLoadModel
    @Environment(\.dismiss) private var dismiss
    @State private var useCachedPages = true
    @AppStorage(AppPreferences.Key.warmingIncludesSharedSpace) private var includesSharedSpace = true

    private var running: Bool { model.progress.state == .running }
    private var started: Bool { model.progress.state != .idle }

    var body: some View {
        Form {
            Section {
                Toggle("Include Shared Space", isOn: $includesSharedSpace)
                Toggle("Skip sections already cached", isOn: $useCachedPages)
            } footer: {
                Text("Reads every timeline section of the library, favorites and albums, so filters and search cover everything.")
            }
            .disabled(running)

            if started {
                Section {
                    ProgressView(value: Double(model.progress.processed), total: Double(max(1, model.progress.total)))
                    HStack {
                        Text("\(model.progress.processed.formatted()) of \(model.progress.total.formatted()) sections")
                        Spacer()
                        if model.progress.state == .finished { Text("Done").fontWeight(.medium) }
                        if model.progress.state == .cancelled { Text("Stopped").fontWeight(.medium) }
                    }
                    .monospacedDigit()
                    if let current = model.progress.currentSectionLabel {
                        Text(current).foregroundStyle(.secondary).lineLimit(1)
                    }
                    let details = [
                        model.progress.matchCount.map { "\($0.formatted()) matching items" },
                        model.progress.cached > 0 ? "\(model.progress.cached.formatted()) already cached" : nil
                    ].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if model.progress.failed > 0 || model.staleTimelineMessage != nil {
                Section {
                    if let stale = model.staleTimelineMessage {
                        Label(stale, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if model.progress.failed > 0 {
                        Label("\(model.progress.failed.formatted()) failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(model.progress.failures, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }
                        }
                        .frame(maxHeight: 100)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                if running {
                    Button("Stop") { model.cancel() }
                } else if model.progress.failed > 0 {
                    Button("Retry Failed") { model.retryFailed() }
                        .disabled(model.staleTimelineMessage != nil)
                }
                Button("Close") { dismiss() }
                Button("Start") { model.start(useCachedPages: useCachedPages, includeSharedSpace: includesSharedSpace) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || model.staleTimelineMessage != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
