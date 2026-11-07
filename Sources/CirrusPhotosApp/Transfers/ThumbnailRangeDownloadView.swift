import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

/// An inclusive range of populated days, by day ID (`yyyy-MM-dd`).
struct ThumbnailDaySelection: Equatable {
    var earliest: String
    var latest: String
}

/// The libraries a thumbnail preload covers and their combined day geometry.
@MainActor
struct ThumbnailPreloadTargets {
    let targets: [(collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot)]
    let verified: Bool
    let combined: TimelineSnapshot?
    let includesSharedSpace: Bool

    init(library: LibraryModel, includesSharedSpace: Bool) {
        self.includesSharedSpace = includesSharedSpace
        let collections: [PhotoCollectionDescriptor] = [.library(.personal)] + (includesSharedSpace ? [.library(.shared)] : [])
        targets = collections.compactMap { collection in library.snapshot(for: collection).map { (collection, $0) } }
        verified = library.timelineVerified(for: .library(.personal)) &&
            (!includesSharedSpace || library.timelineVerified(for: .library(.shared)))
        combined = targets.isEmpty ? nil : ThumbnailWarmingPlan.combinedSnapshot(targets.map(\.snapshot))
    }

    func estimate(_ selection: ThumbnailDaySelection?) -> Int {
        guard let selection, let combined,
              let range = ThumbnailWarmingPlan.range(in: combined, from: selection.earliest, through: selection.latest)
        else { return 0 }
        return range.estimatedThumbnailCount(in: combined)
    }
}

/// The two-handle day range used by the Download Thumbnails window and by the preload
/// step after sign-in. It defaults to the newest week and keeps the chosen dates when
/// the timeline changes underneath it.
struct ThumbnailRangeSelector: View {
    let snapshot: TimelineSnapshot?
    @Binding var selection: ThumbnailDaySelection?
    var disabled = false
    @State private var lower = 0.0
    @State private var upper = 0.0
    @State private var restoring = false

    private var days: [TimelineCore.LibraryDay] { snapshot?.timeline.days ?? [] }
    private var selectedDates: [String] {
        guard let snapshot else { return [] }
        return ThumbnailDateRange(chronologicalLower: Int(lower.rounded()), chronologicalUpper: Int(upper.rounded()),
                                  dayCount: days.count).dayIDs(in: snapshot)
    }

    var body: some View {
        VStack(spacing: 6) {
            TwoHandleRangeSlider(lower: $lower, upper: $upper, bounds: 0...Double(max(0, days.count - 1)))
                .frame(height: 32)
                .disabled(disabled || days.isEmpty)
                .allowsHitTesting(!disabled)
            HStack {
                dateField("From", selection?.earliest ?? "—")
                Spacer()
                dateField("Through", selection?.latest ?? "—", alignment: .trailing)
            }
        }
        .onAppear { restore() }
        .onChange(of: days.map(\.id)) { _, _ in restore() }
        .onChange(of: lower) { _, _ in if !restoring { publish() } }
        .onChange(of: upper) { _, _ in if !restoring { publish() } }
    }

    private func dateField(_ label: String, _ value: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func publish() {
        guard let earliest = selectedDates.min(), let latest = selectedDates.max() else { return }
        selection = ThumbnailDaySelection(earliest: earliest, latest: latest)
    }

    /// Places the handles on the selected dates, or on the newest week.
    private func restore() {
        guard let snapshot, !days.isEmpty else { return }
        let last = days.count - 1
        restoring = true
        if let selection {
            let latestIndex = snapshot.timeline.index(keeping: selection.latest) ?? 0
            let earliestIndex = snapshot.timeline.index(keeping: selection.earliest) ?? last
            lower = Double(min(last - earliestIndex, last - latestIndex))
            upper = Double(max(last - earliestIndex, last - latestIndex))
        } else {
            lower = Double(max(0, last - 6))
            upper = Double(last)
        }
        restoring = false
        publish()
    }
}

/// Thumbnail quality, which is also the browser's thumbnail size setting.
struct ThumbnailQualityPicker: View {
    @Binding var size: ThumbnailSize

    var body: some View {
        Picker("Thumbnail quality", selection: $size) {
            Text("Small").tag(ThumbnailSize.sm)
            Text("Medium").tag(ThumbnailSize.m)
            Text("Large").tag(ThumbnailSize.xl)
        }
    }
}

struct ThumbnailRangeDownloadView: View {
    @Environment(LibraryModel.self) private var library
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var preload: ThumbnailPreloadModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferences.Key.warmingIncludesSharedSpace) private var includesSharedSpace = true
    @State private var selection: ThumbnailDaySelection?

    private var targets: ThumbnailPreloadTargets {
        ThumbnailPreloadTargets(library: library, includesSharedSpace: includesSharedSpace)
    }

    var body: some View {
        let targets = targets
        let estimate = targets.estimate(selection)
        Form {
            Section {
                Toggle("Include Shared Space", isOn: $includesSharedSpace)
                    .disabled(preload.isRunning)
                ThumbnailRangeSelector(snapshot: targets.combined, selection: $selection, disabled: preload.isRunning)
                LabeledContent("Thumbnails", value: "Up to \(estimate.formatted())")
                    .monospacedDigit()
                ThumbnailQualityPicker(size: $preferences.thumbnailSize)
                    .disabled(preload.isRunning)
                LabeledContent("Cache limit", value: bytes(CacheBudget.bytes(at: preferences.budgetFraction)))
            } footer: {
                if includesSharedSpace, let message = library.error(for: .library(.shared)) {
                    Label("Shared Space: \(message)", systemImage: "exclamationmark.triangle")
                } else if !targets.verified {
                    Label("Waiting for the timeline", systemImage: "clock")
                }
            }

            if let summary = preload.summary {
                Section {
                    ProgressView(value: Double(summary.processed), total: Double(max(1, summary.estimated)))
                    HStack {
                        Text("\(summary.processed.formatted()) of \(summary.estimated.formatted())")
                        Spacer()
                        if let outcome = preload.outcome { Text(outcome).fontWeight(.medium) }
                        else if let remaining = remaining(summary) { Text(remaining) }
                    }
                    .monospacedDigit()
                    Text(transferLine(summary))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                if preload.isRunning {
                    Button("Stop…") { preload.requestCancel() }
                }
                Button("Close") { dismiss() }
                Button("Start") {
                    if let selection {
                        preload.start(library: library, targets: targets, selection: selection, size: preferences.thumbnailSize)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preload.isRunning || estimate == 0 || library.repository == nil || !targets.verified)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: includesSharedSpace) {
            if includesSharedSpace { library.ensureCollectionLoaded(.library(.shared)) }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Run averages only; nil until the summary has enough items to project from.
    private func remaining(_ summary: ThumbnailBatchSummary) -> String? {
        guard summary.processed < summary.estimated,
              let seconds = summary.estimatedRemainingSeconds else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds)).map { "About \($0) left" }
    }

    private func transferLine(_ summary: ThumbnailBatchSummary) -> String {
        var parts = ["\(bytes(summary.downloadedBytes)) downloaded"]
        if let total = summary.estimatedDownloadBytes, summary.processed < summary.estimated {
            parts[0] += " of about \(bytes(total))"
        }
        if let speed = summary.bytesPerSecond { parts.append("\(bytes(Int64(speed.rounded())))/s") }
        if let average = summary.averageDownloadedThumbnailBytes { parts.append("\(bytes(average)) each") }
        if summary.reused > 0 { parts.append("\(summary.reused.formatted()) already cached") }
        if summary.unavailable > 0 { parts.append("\(summary.unavailable.formatted()) unavailable") }
        if summary.errors > 0 { parts.append("\(summary.errors.formatted()) failed") }
        return parts.joined(separator: " · ")
    }
}

private struct TwoHandleRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    @State private var activeHandle: Handle?

    private enum Handle { case lower, upper }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 16)
            let lowerX = x(for: lower, width: width) + 8
            let upperX = x(for: upper, width: width) + 8
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25)).frame(height: 4).padding(.horizontal, 8)
                Capsule().fill(Color.accentColor).frame(width: max(0, upperX - lowerX), height: 4)
                    .offset(x: lowerX)
                handle(.lower, at: lowerX)
                handle(.upper, at: upperX)
                Color.clear.contentShape(Rectangle()).gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let proposed = self.value(for: value.location.x - 8, width: width)
                            if activeHandle == nil {
                                if lower == upper {
                                    if proposed < lower || value.translation.width < 0 {
                                        activeHandle = .lower
                                    } else if proposed > upper || value.translation.width > 0 {
                                        activeHandle = .upper
                                    } else {
                                        // A zero-distance gesture reports an initial stationary event.
                                        // Wait for direction before choosing an overlapping handle.
                                        return
                                    }
                                } else {
                                    activeHandle = abs(proposed - lower) <= abs(proposed - upper) ? .lower : .upper
                                }
                            }
                            if activeHandle == .lower { lower = min(proposed, upper) }
                            else { upper = max(proposed, lower) }
                        }
                        .onEnded { _ in activeHandle = nil }
                )
            }
        }
    }

    private func handle(_ handle: Handle, at x: CGFloat) -> some View {
        Circle().fill(.background).overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
            .frame(width: 16, height: 16).position(x: x, y: 16)
            .accessibilityElement()
            .accessibilityLabel(handle == .lower ? "Earliest date handle" : "Latest date handle")
            .accessibilityValue("Position \(Int((handle == .lower ? lower : upper).rounded()) + 1)")
            .accessibilityAdjustableAction { direction in
                switch (handle, direction) {
                case (.lower, .increment): lower = min(upper, lower + 1)
                case (.lower, .decrement): lower = max(bounds.lowerBound, lower - 1)
                case (.upper, .increment): upper = min(bounds.upperBound, upper + 1)
                case (.upper, .decrement): upper = max(lower, upper - 1)
                default: break
                }
            }
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let span = max(Double.ulpOfOne, bounds.upperBound - bounds.lowerBound)
        return CGFloat((value - bounds.lowerBound) / span) * width
    }

    private func value(for x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(1, max(0, x / width))
        let raw = bounds.lowerBound + Double(fraction) * (bounds.upperBound - bounds.lowerBound)
        return min(bounds.upperBound, max(bounds.lowerBound, raw.rounded()))
    }
}
