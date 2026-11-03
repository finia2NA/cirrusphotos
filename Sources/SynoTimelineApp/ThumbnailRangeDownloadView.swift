import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

struct ThumbnailRangeDownloadView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferences.Key.warmingIncludesSharedSpace) private var includesSharedSpace = true
    @State private var lower = 0.0
    @State private var upper = 0.0
    @State private var initialized = false
    @State private var selectedEarliestID: String?
    @State private var selectedLatestID: String?
    @State private var restoringSelection = false
    @State private var summary: ThumbnailBatchSummary?
    @State private var outcomeText: String?
    @State private var batchSize: ThumbnailSize?
    @State private var rangeSnapshot: TimelineSnapshot?
    @State private var downloadTask: Task<Void, Never>?

    private var targets: [(collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot)] {
        let collections: [PhotoCollectionDescriptor] = [.library(.personal)] + (includesSharedSpace ? [.library(.shared)] : [])
        return collections.compactMap { collection in
            library.snapshot(for: collection).map { (collection, $0) }
        }
    }
    private var timelinesVerified: Bool {
        library.timelineVerified(for: .library(.personal)) && (!includesSharedSpace || library.timelineVerified(for: .library(.shared)))
    }
    private struct TimelineKey: Equatable {
        let includesSharedSpace: Bool
        let personalRevision: Int
        let sharedRevision: Int
    }
    private var timelineKey: TimelineKey {
        .init(includesSharedSpace: includesSharedSpace,
              personalRevision: library.snapshotRevision(for: .library(.personal)),
              sharedRevision: library.snapshotRevision(for: .library(.shared)))
    }
    private var snapshot: TimelineSnapshot? { rangeSnapshot }
    private var days: [TimelineCore.LibraryDay] { snapshot?.timeline.days ?? [] }
    private var selectedRange: ThumbnailDateRange {
        ThumbnailDateRange(chronologicalLower: Int(lower.rounded()),
                           chronologicalUpper: Int(upper.rounded()), dayCount: days.count)
    }
    private var selectedDates: [String] {
        guard let snapshot else { return [] }
        return selectedRange.dayIDs(in: snapshot)
    }
    private var estimate: Int {
        guard let snapshot else { return 0 }
        return selectedRange.estimatedThumbnailCount(in: snapshot)
    }
    private var isRunning: Bool { downloadTask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download Thumbnails").font(.title2.weight(.semibold))
            Toggle("Include Shared Space", isOn: $includesSharedSpace)
                .disabled(isRunning)
            Text(includesSharedSpace ? "Personal and Shared Space; the same dates apply to both." : "Personal Space")
                .font(.callout).foregroundStyle(.secondary)
            Text("Choose an inclusive range of populated days. Only the current \(sizeLabel) rendition is requested.")
                .foregroundStyle(.secondary)

            if !days.isEmpty {
                HStack {
                    dateField("Earliest library date", days.map(\.id).min() ?? "—")
                    Spacer()
                    dateField("Latest library date", days.map(\.id).max() ?? "—", alignment: .trailing)
                }

                TwoHandleRangeSlider(lower: $lower, upper: $upper,
                                     bounds: 0...Double(max(0, days.count - 1)))
                    .frame(height: 32)
                    .disabled(isRunning)
                    .allowsHitTesting(!isRunning)

                HStack {
                    dateField("From", selectedDates.min() ?? "—")
                    Spacer()
                    dateField("Through", selectedDates.max() ?? "—", alignment: .trailing)
                }

                Text("Up to \(estimate.formatted()) photo/video thumbnails")
                    .font(.headline).monospacedDigit()
                if !isRunning && summary == nil {
                    Text("Size and speed estimates begin with each batch.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("The range may exceed the \(budgetLabel) cache budget. The budget is not increased, and normal eviction may remove thumbnails downloaded earlier in the batch.")
                .font(.callout).foregroundStyle(.secondary)
            Text("You can continue browsing while this window is open. Closing it cancels a running batch.")
                .font(.callout).foregroundStyle(.secondary)

            if includesSharedSpace, let message = library.error(for: .library(.shared)) {
                Text("Shared Space: \(message)").font(.callout).foregroundStyle(.secondary)
            }
            if !timelinesVerified {
                Label("Waiting for the current timeline before a batch can start.", systemImage: "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(summary.processed), total: Double(max(1, summary.estimated)))
                    Text("Processed \(summary.processed.formatted()) of up to \(summary.estimated.formatted())")
                        .monospacedDigit()
                    Text("Fetched \(summary.fetched.formatted()) · Reused \(summary.reused.formatted()) · Unavailable \(summary.unavailable.formatted()) · Errors \(summary.errors.formatted())")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    if let estimate = summary.estimatedDownloadBytes,
                       let average = summary.averageDownloadedThumbnailBytes,
                       let speed = summary.bytesPerSecond {
                        Text("Downloaded \(bytes(summary.downloadedBytes)) · Estimated total \(bytes(estimate))")
                            .font(.callout).monospacedDigit()
                        Text("Average \(bytes(average)) per thumbnail · \(rate(speed))\(remaining(summary))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let outcomeText { Text(outcomeText).font(.callout.weight(.medium)) }
                }
            }

            HStack {
                Spacer()
                Button(isRunning ? "Cancel" : "Close") {
                    if let downloadTask { downloadTask.cancel() } else { dismiss() }
                }
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || estimate == 0 || library.repository == nil || snapshot == nil ||
                              !timelinesVerified)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { initializeRange() }
        .task(id: timelineKey) {
            if includesSharedSpace { library.ensureCollectionLoaded(.library(.shared)) }
            rangeSnapshot = targets.isEmpty ? nil : ThumbnailWarmingPlan.combinedSnapshot(targets.map(\.snapshot))
        }
        .onChange(of: lower) { _, _ in if !restoringSelection { rememberSelectedDates() } }
        .onChange(of: upper) { _, _ in if !restoringSelection { rememberSelectedDates() } }
        .onChange(of: days.map(\.id)) { _, _ in restoreSelectedDates() }
        .onDisappear { downloadTask?.cancel() }
    }

    private var sizeLabel: String {
        switch isRunning ? (batchSize ?? preferences.thumbnailSize) : preferences.thumbnailSize {
        case .sm: "Small"; case .m: "Medium"; case .xl: "Large"
        }
    }

    private var budgetLabel: String {
        ByteCountFormatter.string(fromByteCount: CacheBudget.bytes(at: preferences.budgetFraction), countStyle: .file)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond.rounded())))/s"
    }

    private func remaining(_ summary: ThumbnailBatchSummary) -> String {
        guard summary.processed < summary.estimated,
              let seconds = summary.estimatedRemainingSeconds else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        guard let duration = formatter.string(from: max(1, seconds)) else { return "" }
        return " · About \(duration) remaining"
    }

    private func dateField(_ label: String, _ value: String,
                           alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func initializeRange() {
        guard !initialized, !days.isEmpty else { return }
        initialized = true
        let newestPosition = Double(days.count - 1)
        lower = max(0, newestPosition - 6)
        upper = newestPosition
        rememberSelectedDates()
    }

    private func rememberSelectedDates() {
        guard initialized else { return }
        selectedEarliestID = selectedDates.min()
        selectedLatestID = selectedDates.max()
    }

    private func restoreSelectedDates() {
        guard initialized, let snapshot, !days.isEmpty else { initializeRange(); return }
        let last = days.count - 1
        let latestIndex = snapshot.timeline.index(keeping: selectedLatestID) ?? 0
        let earliestIndex = snapshot.timeline.index(keeping: selectedEarliestID) ?? last
        let firstPosition = last - earliestIndex
        let secondPosition = last - latestIndex
        restoringSelection = true
        lower = Double(min(firstPosition, secondPosition))
        upper = Double(max(firstPosition, secondPosition))
        restoringSelection = false
        rememberSelectedDates()
    }

    private func start() {
        guard downloadTask == nil, timelinesVerified,
              snapshot != nil, let repository = library.repository else { return }
        guard let firstDate = selectedDates.min(), let lastDate = selectedDates.max() else { return }
        let jobs = targets.compactMap { target -> (PhotoCollectionDescriptor, TimelineSnapshot, ThumbnailDateRange)? in
            guard let range = ThumbnailWarmingPlan.range(in: target.snapshot, from: firstDate, through: lastDate) else { return nil }
            return (target.collection, target.snapshot, range)
        }
        let total = jobs.reduce(0) { $0 + $1.2.estimatedThumbnailCount(in: $1.1) }
        let size = preferences.thumbnailSize
        batchSize = size
        summary = ThumbnailBatchSummary(estimated: total)
        outcomeText = nil
        downloadTask = Task {
            let downloader = ThumbnailRangeDownloader(repository: repository, workerCount: 2)
            var final = ThumbnailBatchSummary(estimated: total)
            for (collection, snapshot, range) in jobs {
                guard !Task.isCancelled else { break }
                let completed = final
                let next = await downloader.download(snapshot: snapshot, range: range, size: size, collection: collection) { update in
                    await MainActor.run { summary = completed.adding(update, estimated: total) }
                }
                final = completed.adding(next, estimated: total)
                if next.interrupted { break }
            }
            if Task.isCancelled {
                outcomeText = "Cancelled."
            } else if final.interrupted {
                summary = final
                outcomeText = "Interrupted because cached metadata changed. Start again when the library is ready."
            } else {
                summary = final
                outcomeText = "Complete."
            }
            downloadTask = nil
            await library.refreshUsage()
        }
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
