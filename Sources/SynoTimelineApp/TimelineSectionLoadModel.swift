import Combine
import Foundation
import PhotoCache
import SynologyAPI

struct TimelineSectionLoadPresentationProgress: Equatable {
    enum State: Equatable { case idle, running, cancelled, finished }

    var total = 0
    var processed = 0
    var verified = 0
    var cached = 0
    var provisional = 0
    var failed = 0
    var remaining = 0
    var currentSectionLabel: String?
    var matchCount: Int?
    var state: State = .idle
    var failures: [String] = []
}

@MainActor
final class TimelineSectionLoadModel: ObservableObject {
    private struct TargetRun {
        let target: TimelineWarmingTarget
        let loader: TimelineSectionCacheLoader
        var progress: TimelineSectionCacheProgress
    }

    @Published private(set) var canPresent = false
    @Published private(set) var targetTitle: String?
    @Published private(set) var staleTimelineMessage: String?
    @Published private(set) var progress = TimelineSectionLoadPresentationProgress()

    private weak var library: LibraryModel?
    private weak var filter: LibraryFilterModel?
    private var prepared = false
    private var targetRuns: [TargetRun] = []
    private var discoveryFailures: [String] = []
    private var operationTask: Task<Void, Never>?
    private var libraryObserver: AnyCancellable?
    private var runActive = false
    private var lastUseCachedPages = false
    private var includeSharedSpace = false

    func configure(library: LibraryModel, filter: LibraryFilterModel) {
        if self.library !== library {
            self.library = library
            libraryObserver = library.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.refreshAvailabilityAndCheckRevisions()
                }
            }
        }
        if self.filter !== filter {
            self.filter = filter
        }
        refreshAvailabilityAndCheckRevisions()
    }

    /// Refreshes app-wide command eligibility. Map remains excluded from target
    /// discovery, regardless of the current browser destination.
    func refreshAvailability() {
        refreshAvailabilityAndCheckRevisions()
    }

    /// Prepares an idle app-wide operation before the load window is opened.
    @discardableResult
    func prepare() -> Bool {
        guard canPresent, library != nil else { return false }
        if runActive { return true }
        shutdownPreparedLoaders()
        prepared = true
        runActive = false
        targetTitle = "Personal Library, Favorites, and All Albums"
        staleTimelineMessage = nil
        progress = .init()
        return true
    }

    func start(useCachedPages: Bool, includeSharedSpace: Bool = false) {
        guard staleTimelineMessage == nil, prepared, !runActive else { return }
        if !targetRuns.isEmpty || !discoveryFailures.isEmpty {
            shutdownPreparedLoaders()
        }
        lastUseCachedPages = useCachedPages
        self.includeSharedSpace = includeSharedSpace
        targetTitle = includeSharedSpace ? "Personal and Shared Library, Favorites, and All Albums" : "Personal Library, Favorites, and All Albums"
        runActive = true
        progress.state = .running
        progress.currentSectionLabel = "Discovering albums and timelines"
        operationTask = Task { [weak self] in await self?.runAll(useCachedPages: useCachedPages) }
    }

    func cancel() {
        guard prepared else { return }
        operationTask?.cancel()
        operationTask = nil
        runActive = false
        progress.state = .cancelled
        progress.currentSectionLabel = nil
        let loaders = targetRuns.map(\.loader)
        Task { for loader in loaders { await loader.cancel() } }
    }

    func retryFailed() {
        guard staleTimelineMessage == nil, prepared, !runActive else { return }
        if !discoveryFailures.isEmpty {
            shutdownPreparedLoaders()
            start(useCachedPages: lastUseCachedPages, includeSharedSpace: includeSharedSpace)
            return
        }
        let failedIndices = targetRuns.indices.filter { targetRuns[$0].progress.failed > 0 }
        guard !failedIndices.isEmpty else { return }
        runActive = true
        progress.state = .running
        operationTask = Task { [weak self] in await self?.retry(indices: failedIndices) }
    }

    private func runAll(useCachedPages: Bool) async {
        guard let library, let repository = library.repository else { return }
        let discovery = await library.discoverTimelineWarmingTargets(includeSharedSpace: includeSharedSpace)
        guard !Task.isCancelled else { return }
        discoveryFailures = discovery.failures
        targetRuns = discovery.targets.map { target in
            let loader = TimelineSectionCacheLoader(repository: repository,
                                                    collection: target.collection,
                                                    snapshot: target.snapshot)
            return TargetRun(target: target, loader: loader,
                             progress: TimelineSectionCacheProgress(
                                total: target.snapshot.sections.count, verified: 0, cached: 0,
                                provisional: 0, failed: 0,
                                remaining: target.snapshot.sections.count, state: .idle, failures: []))
        }
        publishAggregate(state: .running)
        for index in targetRuns.indices {
            guard !Task.isCancelled else { return }
            await execute(index: index, retry: false, useCachedPages: useCachedPages)
        }
        finishOperation()
    }

    private func retry(indices: [Int]) async {
        for index in indices {
            guard !Task.isCancelled else { return }
            await execute(index: index, retry: true, useCachedPages: lastUseCachedPages)
        }
        finishOperation()
    }

    private func execute(index: Int, retry: Bool, useCachedPages: Bool) async {
        guard targetRuns.indices.contains(index) else { return }
        let loader = targetRuns[index].loader
        let stream = await loader.observe()
        if retry { await loader.retryFailed() }
        else { await loader.loadAll(useCachedPages: useCachedPages) }
        var sawRunning = false
        for await progress in stream {
            guard !Task.isCancelled, staleTimelineMessage == nil else { return }
            if progress.state == .running { sawRunning = true }
            receive(progress, index: index)
            if sawRunning && progress.state != .running { break }
            if !sawRunning && progress.state == .finished { break }
        }
    }

    private func receive(_ progress: TimelineSectionCacheProgress, index: Int) {
        guard staleTimelineMessage == nil, targetRuns.indices.contains(index) else { return }
        targetRuns[index].progress = progress
        publishAggregate(state: .running, currentTitle: targetRuns[index].target.title)
    }

    private func publishAggregate(state: TimelineSectionLoadPresentationProgress.State,
                                  currentTitle: String? = nil) {
        let values = targetRuns.map(\.progress)
        let loaderFailures = zip(targetRuns, values).flatMap { run, value in
            value.failures.map { "\(run.target.title): \($0)" }
        }
        progress = .init(
            total: values.reduce(0) { $0 + $1.total } + discoveryFailures.count,
            processed: values.reduce(0) { $0 + $1.processed } + discoveryFailures.count,
            verified: values.reduce(0) { $0 + $1.verified },
            cached: values.reduce(0) { $0 + $1.cached },
            provisional: values.reduce(0) { $0 + $1.provisional },
            failed: values.reduce(0) { $0 + $1.failed } + discoveryFailures.count,
            remaining: values.reduce(0) { $0 + $1.remaining },
            currentSectionLabel: currentTitle.map { "Loading \($0)" },
            matchCount: nil, state: state,
            failures: discoveryFailures + loaderFailures
        )
    }

    private func finishOperation() {
        operationTask = nil
        runActive = false
        let hasFailures = !discoveryFailures.isEmpty || targetRuns.contains { $0.progress.failed > 0 }
        publishAggregate(state: hasFailures ? .idle : .finished)
    }

    private func refreshAvailabilityAndCheckRevisions() {
        if let library {
            canPresent = library.repository != nil &&
                library.timelineVerified(for: .library(.personal)) &&
                library.timelineVerified(for: .favorites(.personal))
        } else {
            canPresent = false
        }
        guard runActive, let library,
              let changed = targetRuns.first(where: {
                  library.snapshotRevision(for: $0.target.collection) != $0.target.revision
              }) else { return }
        staleTimelineMessage = "The \(changed.target.title) timeline changed. Close this window and reopen it to load the latest sections."
        cancel()
    }

    private func shutdownPreparedLoaders() {
        operationTask?.cancel()
        operationTask = nil
        let loaders = targetRuns.map(\.loader)
        if !loaders.isEmpty {
            Task { for loader in loaders { await loader.shutdown() } }
        }
        targetRuns = []
        discoveryFailures = []
    }

}
