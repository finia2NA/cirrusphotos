import AppKit
import Combine
import Foundation
import PhotoCache
import SynologyAPI

/// One account's thumbnail download for offline use. The request is saved per account,
/// so a download continues after the app restarts or the account is reopened, until it
/// finishes, the user confirms stopping it, or the account is signed out. Progress and
/// the Cancel action are in the Activity panel. When the cache is nearly full the download
/// pauses and `pausedForSpace` asks to raise the maximum size; raising it continues.
@MainActor
final class ThumbnailPreloadModel: ObservableObject {
    struct Request: Codable, Equatable {
        let earliest: String
        let latest: String
        let includesSharedSpace: Bool
        let size: String
    }

    @Published private(set) var summary: ThumbnailBatchSummary?
    @Published private(set) var outcome: String?
    @Published private(set) var size: ThumbnailSize?
    @Published private(set) var isRunning = false
    /// The download stopped because the cache was nearly full; the request stays saved.
    @Published private(set) var pausedForSpace = false
    /// Shows the sheet that offers a larger maximum or stopping; Done hides it while paused.
    @Published var showsCacheFullSheet = false
    /// The maximum size when the download paused; a larger one continues it.
    private var pausedBudget: Int64 = 0
    private weak var pausedLibrary: LibraryModel?
    private var budgetObservation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var handle: ActivityHandle?
    private var lastActivityUpdate: ContinuousClock.Instant?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func requestKey(namespace: String) -> String { "thumbnailPreload.request.v1.\(namespace)" }

    func savedRequest(namespace: String) -> Request? {
        defaults.data(forKey: Self.requestKey(namespace: namespace)).flatMap { try? JSONDecoder().decode(Request.self, from: $0) }
    }

    /// Starts a download and saves it so it survives restarts.
    func start(library: LibraryModel, targets: ThumbnailPreloadTargets, selection: ThumbnailDaySelection, size: ThumbnailSize) {
        guard task == nil, let namespace = library.repository?.namespace else { return }
        let request = Request(earliest: selection.earliest, latest: selection.latest,
                              includesSharedSpace: targets.includesSharedSpace, size: size.rawValue)
        defaults.set(try? JSONEncoder().encode(request), forKey: Self.requestKey(namespace: namespace))
        resumeTask?.cancel()
        resumeTask = nil
        run(library: library, targets: targets, request: request, namespace: namespace)
    }

    /// Continues a saved download once the library's timelines are current.
    func resumeIfRequested(library: LibraryModel) {
        guard task == nil, resumeTask == nil, let namespace = library.repository?.namespace,
              let request = savedRequest(namespace: namespace),
              ThumbnailSize(rawValue: request.size) != nil else { return }
        resumeTask = Task { [weak self, weak library] in
            if request.includesSharedSpace { library?.ensureCollectionLoaded(.library(.shared)) }
            while !Task.isCancelled {
                guard let library else { return }
                let targets = ThumbnailPreloadTargets(library: library, includesSharedSpace: request.includesSharedSpace)
                if targets.verified {
                    guard let self else { return }
                    self.resumeTask = nil
                    self.run(library: library, targets: targets, request: request, namespace: namespace)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Asks before stopping, since a stopped download is not resumed.
    func requestCancel() {
        guard isRunning || resumeTask != nil || pausedForSpace else { return }
        let alert = NSAlert()
        alert.messageText = "Stop downloading thumbnails?"
        alert.informativeText = "Thumbnails downloaded so far are kept. Start again from Library ▸ Download Thumbnails… or Settings ▸ Storage."
        alert.addButton(withTitle: "Stop Downloading").hasDestructiveAction = true
        alert.addButton(withTitle: "Continue")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if pausedForSpace { stopDownload() } else { stop(forget: true) }
    }

    /// Pauses the download for an account switch or sign-out; the saved request stays,
    /// so reopening the account continues it.
    func suspend() {
        clearPause()
        stop(forget: false)
    }

    /// Stops a paused download from the cache-full sheet, which is the confirmation.
    func stopDownload() {
        let handle = handle
        self.handle = nil
        clearPause()
        stop(forget: true)
        outcome = "Stopped"
        handle?.cancelled()
    }

    private func clearPause() {
        pausedForSpace = false
        showsCacheFullSheet = false
        pausedLibrary = nil
        budgetObservation = nil
    }

    /// Keeps the request and the Activity entry, then continues once the maximum grows.
    private func pause(library: LibraryModel) {
        pausedForSpace = true
        showsCacheFullSheet = true
        pausedLibrary = library
        pausedBudget = library.preferences.budgetBytes
        outcome = "Paused – cache is full"
        handle?.status("Paused · cache is full")
        budgetObservation = library.preferences.$budgetFraction
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.budgetChanged() }
    }

    private func budgetChanged() {
        guard pausedForSpace, let library = pausedLibrary,
              library.preferences.budgetBytes > pausedBudget else { return }
        clearPause()
        let handle = handle
        self.handle = nil
        handle?.discard()
        Task { [weak self] in
            await library.applySharedBudget()
            self?.resumeIfRequested(library: library)
        }
    }

    private var forgetOnStop = false
    private var namespace: String?

    private func stop(forget: Bool) {
        forgetOnStop = forget
        if forget, let namespace { defaults.removeObject(forKey: Self.requestKey(namespace: namespace)) }
        resumeTask?.cancel()
        resumeTask = nil
        task?.cancel()
        if task == nil {
            handle?.discard()
            handle = nil
        }
    }

    private func run(library: LibraryModel, targets: ThumbnailPreloadTargets, request: Request, namespace: String) {
        guard let repository = library.repository, let size = ThumbnailSize(rawValue: request.size) else { return }
        let jobs = targets.targets.compactMap { target -> (PhotoCollectionDescriptor, TimelineSnapshot, ThumbnailDateRange)? in
            guard let range = ThumbnailWarmingPlan.range(in: target.snapshot, from: request.earliest,
                                                         through: request.latest) else { return nil }
            return (target.collection, target.snapshot, range)
        }
        let total = jobs.reduce(0) { $0 + $1.2.estimatedThumbnailCount(in: $1.1) }
        guard total > 0 else {
            defaults.removeObject(forKey: Self.requestKey(namespace: namespace))
            return
        }
        self.namespace = namespace
        self.size = size
        summary = ThumbnailBatchSummary(estimated: total)
        outcome = nil
        isRunning = true
        forgetOnStop = false
        handle = library.activity.begin(.thumbnailDownload, totalCount: total,
                                        cancel: { [weak self] in self?.requestCancel() })
        handle?.start()
        task = Task { [weak self, weak library] in
            let downloader = ThumbnailRangeDownloader(repository: repository, workerCount: 2)
            var final = ThumbnailBatchSummary(estimated: total)
            for (collection, snapshot, range) in jobs {
                guard !Task.isCancelled else { break }
                let completed = final
                let next = await downloader.download(snapshot: snapshot, range: range, size: size, collection: collection) { update in
                    await MainActor.run { self?.report(completed.adding(update, estimated: total)) }
                }
                final = completed.adding(next, estimated: total)
                if next.interrupted || next.budgetReached { break }
            }
            guard let self else { return }
            self.finish(final, cancelled: Task.isCancelled, library: library)
        }
    }

    private func report(_ summary: ThumbnailBatchSummary) {
        self.summary = summary
        let now = ContinuousClock.now
        if let last = lastActivityUpdate, now - last < .seconds(1), summary.processed < summary.estimated { return }
        lastActivityUpdate = now
        handle?.progress(completed: summary.processed)
        handle?.progress(fraction: Double(summary.processed) / Double(max(1, summary.estimated)))
        handle?.status("\(summary.processed.formatted()) of \(summary.estimated.formatted())"
                       + (summary.reused > 0 ? " · \(summary.reused.formatted()) already cached" : ""))
    }

    private func finish(_ final: ThumbnailBatchSummary, cancelled: Bool, library: LibraryModel?) {
        task = nil
        isRunning = false
        if !cancelled, final.budgetReached, let library {
            summary = final
            pause(library: library)
            Task { await library.refreshUsage() }
            return
        }
        let handle = handle
        self.handle = nil
        if cancelled {
            outcome = forgetOnStop ? "Stopped" : nil
            if forgetOnStop { handle?.cancelled() } else { handle?.discard() }
        } else if final.interrupted {
            // The library changed underneath the run; continue once it is current again.
            summary = final
            handle?.discard()
            if let library { resumeIfRequested(library: library) }
        } else {
            summary = final
            outcome = "Done"
            if let namespace { defaults.removeObject(forKey: Self.requestKey(namespace: namespace)) }
            handle?.progress(completed: final.processed)
            handle?.succeed()
        }
        if let library { Task { await library.refreshUsage() } }
    }
}
