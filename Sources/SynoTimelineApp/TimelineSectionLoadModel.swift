import Combine
import Foundation
import PhotoCache
import SynologyAPI

struct TimelineSectionLoadPresentationProgress: Equatable {
    enum State: Equatable { case idle, running, cancelled, finished }

    var total = 0
    var processed = 0
    var verified = 0
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
    private struct Target {
        let collection: PhotoCollectionDescriptor
        let snapshot: TimelineSnapshot
        let revision: Int
        let title: String
    }

    @Published private(set) var canPresent = false
    @Published private(set) var targetTitle: String?
    @Published private(set) var staleTimelineMessage: String?
    @Published private(set) var progress = TimelineSectionLoadPresentationProgress()

    private weak var library: LibraryModel?
    private weak var filter: LibraryFilterModel?
    private var sourceTarget: Target?
    private var capturedTarget: Target?
    private var loader: TimelineSectionCacheLoader?
    private var loaderObserver: Task<Void, Never>?
    private var libraryObserver: AnyCancellable?
    private var runActive = false
    private var runRequestPending = false

    func configure(library: LibraryModel, filter: LibraryFilterModel) {
        if self.library !== library {
            self.library = library
            libraryObserver = library.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.checkCapturedRevision()
                }
            }
        }
        if self.filter !== filter {
            self.filter = filter
        }
    }

    /// Updates command eligibility without changing an already prepared operation.
    func updateSource(collection: PhotoCollectionDescriptor?) {
        guard let library else {
            sourceTarget = nil
            canPresent = false
            return
        }
        checkCapturedRevision()
        let normalized: PhotoCollectionDescriptor?
        switch collection {
        case .some(.libraryFilter): normalized = .personalLibrary
        case .some(.personalLibrary), .some(.favorites), .some(.album): normalized = collection
        case .some(.mapFilter), .none: normalized = nil
        }
        guard let normalized,
              let snapshot = library.snapshot(for: normalized),
              library.timelineVerified(for: normalized),
              library.repository != nil else {
            sourceTarget = nil
            canPresent = false
            return
        }
        sourceTarget = Target(collection: normalized, snapshot: snapshot,
                              revision: library.snapshotRevision(for: normalized),
                              title: Self.title(for: normalized, library: library))
        canPresent = true
    }

    /// Freezes the currently eligible source before the load window is opened.
    @discardableResult
    func prepareCurrentTarget() -> Bool {
        guard let target = sourceTarget, let library, let repository = library.repository else { return false }
        if runActive { return true }

        let oldLoader = loader
        loaderObserver?.cancel()
        loaderObserver = nil
        loader = nil
        if let oldLoader { Task { await oldLoader.shutdown() } }

        capturedTarget = target
        runActive = false
        runRequestPending = false
        targetTitle = target.title
        staleTimelineMessage = nil
        progress = .init(total: target.snapshot.sections.count,
                         remaining: target.snapshot.sections.count)
        let pageEmission: TimelineSectionCacheLoader.PageEmission?
        if target.collection == .personalLibrary {
            filter?.configure(library: library)
            pageEmission = { [weak filter] sectionIndex, items, verified in
                let ingestion = await MainActor.run {
                    filter?.ingest(sectionIndex: sectionIndex, items: items, verified: verified)
                }
                await ingestion?.value
            }
        } else {
            pageEmission = nil
        }
        let loader = TimelineSectionCacheLoader(repository: repository,
                                                collection: target.collection,
                                                snapshot: target.snapshot,
                                                collectionLabel: target.title,
                                                pageEmission: pageEmission)
        self.loader = loader
        loaderObserver = Task { [weak self] in
            for await value in await loader.observe() {
                guard !Task.isCancelled else { return }
                self?.receive(value)
            }
        }
        return true
    }

    func start(useCachedPages: Bool) {
        guard staleTimelineMessage == nil, capturedTarget != nil else { return }
        if let loader {
            runActive = true
            runRequestPending = true
            progress.state = .running
            Task { await loader.loadAll(useCachedPages: useCachedPages) }
        }
    }

    func cancel() {
        guard capturedTarget != nil else { return }
        if let loader {
            runActive = false
            runRequestPending = false
            Task { await loader.cancel() }
        }
    }

    func retryFailed() {
        guard staleTimelineMessage == nil, capturedTarget != nil else { return }
        if let loader {
            runActive = true
            runRequestPending = true
            progress.state = .running
            Task { await loader.retryFailed() }
        }
    }

    private func receive(_ value: TimelineSectionCacheLoadProgress) {
        guard staleTimelineMessage == nil else { return }
        if runRequestPending, value.state == .idle { return }
        runRequestPending = false
        runActive = value.state == .running
        progress = .init(total: value.total, processed: value.processed,
                         verified: value.verified, provisional: value.provisional,
                         failed: value.failed, remaining: value.remaining,
                         currentSectionLabel: value.state == .running
                             ? "Loading \(value.collectionLabel) sections" : nil,
                         matchCount: nil, state: Self.presentation(value.state),
                         failures: value.failures)
    }

    private func checkCapturedRevision() {
        guard let target = capturedTarget, runActive, let library,
              library.snapshotRevision(for: target.collection) != target.revision else { return }
        staleTimelineMessage = "The \(target.title) timeline changed. Close this window and reopen it to load the latest sections."
        progress.state = .cancelled
        cancel()
    }

    private static func title(for collection: PhotoCollectionDescriptor,
                              library: LibraryModel) -> String {
        switch collection {
        case .personalLibrary: "Personal Library"
        case .favorites: "Favorites"
        case .album(let id): library.albumName(for: collection) ?? "Album \(id)"
        case .mapFilter, .libraryFilter: "Personal Library"
        }
    }

    private static func presentation(_ value: TimelineSectionCacheLoadProgress.State) -> TimelineSectionLoadPresentationProgress.State {
        switch value {
        case .idle: .idle
        case .running: .running
        case .cancelled: .cancelled
        case .finished: .finished
        }
    }
}
