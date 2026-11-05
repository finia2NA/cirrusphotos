import SwiftUI
import Combine
import Foundation
import Network
import PhotoCache
import SynologyAPI

/// Reads every metadata page of the persistent collections and every folder once per
/// run, in the background. Pages already verified, including those proven unchanged by
/// Diff reconciliation, finish without a request; the rest are fetched at prefetch
/// priority so visible work always goes first. The collection on screen is loaded
/// before the others and preempts the one in progress. Starts once Library and
/// Favorites timelines are verified and restarts when a captured timeline changes.
/// Failed sections and collections are retried with backoff, and sooner when the
/// network path comes back, until every target is verified.
@MainActor
final class MetadataSyncModel: ObservableObject {
    struct Progress: Equatable {
        var total = 0
        var verified = 0
        var failed = 0
        var running = false
        var currentTitle: String?
        /// Set while waiting before the next retry round.
        var nextRetry: Date?
    }

    /// One sync target. `queued` targets wait for the ones before them.
    struct CollectionProgress: Equatable {
        enum State: Equatable { case queued, running, done }
        var total: Int
        var verified = 0
        var failed = 0
        var state = State.queued
    }

    /// Totals across every target discovered in the current sync run.
    @Published private(set) var progress = Progress()
    /// Progress of each target of the current sync run.
    @Published private(set) var collections: [PhotoCollectionDescriptor: CollectionProgress] = [:]

    private struct Target {
        let collection: PhotoCollectionDescriptor
        let snapshot: TimelineSnapshot
        let title: String
    }
    private enum Outcome { case verified, incomplete, preempted, cancelled }

    private weak var library: LibraryModel?
    /// Identifies the current library observation; a new library supersedes the old loop.
    private var libraryObservation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var loaders: [TimelineSectionCacheLoader] = []
    /// Library-discovered targets whose timeline revisions trigger a restart.
    private var baseTargets: [TimelineWarmingTarget] = []
    /// Collections fully verified this run; later passes skip them.
    private var verifiedCollections: Set<PhotoCollectionDescriptor> = []
    /// Collections whose timeline could not be read this pass; retried next pass.
    private var unavailableCollections: Set<PhotoCollectionDescriptor> = []
    private var focus: PhotoCollectionDescriptor?
    private var focusChanges = 0
    private var started = false
    private var startedInvalidationRevision: UInt64 = 0
    /// The Activity entry while a pass runs. It has no cancel action and, while running,
    /// cannot be dismissed; it is discarded when the pass ends, so it never enters History.
    private var activityHandle: ActivityHandle?
    private var lastActivityStatus: ContinuousClock.Instant?
    private static let activityStatusInterval: Duration = .seconds(1)
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true
    private var networkReturns = 0
    private static let firstRetryDelay: Duration = .seconds(30)
    private static let maximumRetryDelay: Duration = .seconds(600)

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.receiveNetwork(available: available) }
        }
        pathMonitor.start(queue: .main)
    }

    deinit { pathMonitor.cancel() }

    private func receiveNetwork(available: Bool) {
        if available && !networkAvailable { networkReturns += 1 }
        networkAvailable = available
    }

    func configure(library: LibraryModel) {
        guard self.library !== library else { return }
        self.library = library
        libraryObservation &+= 1
        observeLibrary(libraryObservation)
    }

    /// Re-checks whenever library state read by the check changes. Every library property
    /// the check depends on must be tracked: a guard that returns on an untracked read
    /// registers no dependency, and the check would never run again.
    private func observeLibrary(_ observation: UInt64) {
        guard observation == libraryObservation else { return }
        withObservationTracking {
            startOrRestartIfNeeded()
        } onChange: { [weak self] in
            Task { @MainActor in
                await Task.yield()
                self?.observeLibrary(observation)
            }
        }
    }

    /// The collection on screen. Session-derived collections are ignored.
    func setFocus(_ collection: PhotoCollectionDescriptor?) {
        let next = collection.flatMap { $0.isSessionDerived ? nil : $0 }
        guard next != focus else { return }
        focus = next
        focusChanges += 1
        // A finished run still loads a newly shown collection.
        if started, task == nil, let next, !verifiedCollections.contains(next) { startTask() }
    }

    private func startOrRestartIfNeeded() {
        guard let library, library.repository != nil,
              library.timelineVerified(for: .library(.personal)),
              library.timelineVerified(for: .favorites(.personal)) else {
            // A metadata reset or revalidation withdraws verification; begin again once timelines return.
            if started, library?.metadataInvalidationRevision != startedInvalidationRevision { stop(); started = false }
            return
        }
        if started, library.metadataInvalidationRevision != startedInvalidationRevision { stop(); started = false }
        if started {
            guard baseTargets.contains(where: { library.snapshotRevision(for: $0.collection) != $0.revision }) else { return }
            stop()
        }
        started = true
        startedInvalidationRevision = library.metadataInvalidationRevision
        startTask()
    }

    private func startTask() {
        let includeSharedSpace = UserDefaults.standard.object(forKey: AppPreferences.Key.warmingIncludesSharedSpace) as? Bool ?? true
        let id = UUID()
        taskID = id
        task = Task { [weak self] in
            await self?.run(includeSharedSpace: includeSharedSpace)
            if self?.taskID == id { self?.task = nil }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        let loaders = loaders
        Task { for loader in loaders { await loader.shutdown() } }
        self.loaders = []
        endActivity()
        baseTargets = []
        verifiedCollections = []
        unavailableCollections = []
        progress = Progress()
        collections = [:]
    }

    private func run(includeSharedSpace: Bool) async {
        var delay = Self.firstRetryDelay
        while !Task.isCancelled {
            if await pass(includeSharedSpace: includeSharedSpace) { break }
            guard !Task.isCancelled else { return }
            endActivity()
            progress.running = false
            progress.currentTitle = nil
            progress.nextRetry = Date.now.addingTimeInterval(TimeInterval(delay.components.seconds))
            await waitForRetry(delay)
            delay = min(delay * 2, Self.maximumRetryDelay)
        }
        guard !Task.isCancelled else { return }
        endActivity()
        progress.running = false
        progress.currentTitle = nil
        progress.nextRetry = nil
    }

    /// Waits for the delay, or less when the network path returns or another collection is shown.
    private func waitForRetry(_ delay: Duration) async {
        let returns = networkReturns
        let changes = focusChanges
        let deadline = ContinuousClock.now + delay
        while !Task.isCancelled, ContinuousClock.now < deadline, networkReturns == returns, focusChanges == changes {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// One discovery and loading pass over the shown collection, the library targets and
    /// then the folder tree of each space, discovered breadth-first as it goes. Pages
    /// verified earlier this run finish from the cache without a request. Returns whether
    /// every target was discovered and fully verified.
    private func pass(includeSharedSpace: Bool) async -> Bool {
        guard let library, let repository = library.repository else { return true }
        progress.running = true
        progress.nextRetry = nil
        progress.currentTitle = "Discovering collections"
        beginActivity(library.activity)
        unavailableCollections = []
        var complete = true
        if await runFocusIfNeeded(repository) == .incomplete { complete = false }

        let discovery = await library.discoverTimelineWarmingTargets(includeSharedSpace: includeSharedSpace)
        guard !Task.isCancelled else { return false }
        baseTargets = discovery.targets
        if !discovery.failures.isEmpty { complete = false }
        var pending = discovery.targets.map { Target(collection: $0.collection, snapshot: $0.snapshot, title: $0.title) }
        for target in pending where collections[target.collection] == nil {
            collections[target.collection] = CollectionProgress(total: target.snapshot.sections.count)
        }
        // A child carries its summary from the parent's listing when that listing was verified this run.
        var folders: [(id: Int64, space: PhotoSpace, known: FolderSummary?)] =
            [(0, .personal, nil)] + (includeSharedSpace ? [(0, .shared, nil)] : [])
        while !Task.isCancelled {
            if await runFocusIfNeeded(repository) == .incomplete { complete = false }
            if pending.isEmpty {
                guard !folders.isEmpty else { break }
                let next = folders.removeFirst()
                guard let (directory, verified) = await folderDirectory(repository, id: next.id, space: next.space, known: next.known)
                else { complete = false; continue }
                folders += directory.children.map { ($0.id, next.space, verified ? $0 : nil) }
                let collection = PhotoCollectionDescriptor.folder(directory.folder.id, space: next.space)
                guard !verifiedCollections.contains(collection) else { continue }
                guard let snapshot = await verifiedSnapshot(repository, collection: collection) else { complete = false; continue }
                guard !snapshot.sections.isEmpty else { verifiedCollections.insert(collection); continue }
                let title = next.space == .shared ? "Shared folder \(directory.folder.name)" : "Folder \(directory.folder.name)"
                pending.append(Target(collection: collection, snapshot: snapshot, title: title))
                collections[collection] = collections[collection] ?? CollectionProgress(total: snapshot.sections.count)
                continue
            }
            let target = pending.removeFirst()
            guard !verifiedCollections.contains(target.collection) else { continue }
            switch await load(target, repository: repository) {
            case .verified: break
            case .incomplete: complete = false
            case .preempted: pending.insert(target, at: 0)
            case .cancelled: return false
            }
        }
        return complete && !Task.isCancelled
    }

    /// Loads the shown collection first when it still needs work.
    private func runFocusIfNeeded(_ repository: CachedPhotosRepository) async -> Outcome? {
        guard let focus, !verifiedCollections.contains(focus), !unavailableCollections.contains(focus) else { return nil }
        guard let snapshot = await verifiedSnapshot(repository, collection: focus) else {
            unavailableCollections.insert(focus)
            return .incomplete
        }
        guard focus == self.focus else { return nil }
        if snapshot.sections.isEmpty { verifiedCollections.insert(focus); return .verified }
        if collections[focus] == nil { collections[focus] = CollectionProgress(total: snapshot.sections.count) }
        let title = "Current collection"
        return await load(Target(collection: focus, snapshot: snapshot, title: title), repository: repository)
    }

    private func load(_ target: Target, repository: CachedPhotosRepository) async -> Outcome {
        let loader = TimelineSectionCacheLoader(repository: repository, collection: target.collection, snapshot: target.snapshot)
        loaders.append(loader)
        defer {
            loaders.removeAll { $0 === loader }
            Task { await loader.shutdown() }
        }
        let stream = await loader.observe()
        await loader.loadUnverified()
        var last: TimelineSectionCacheProgress?
        var sawRunning = false
        for await value in stream {
            guard !Task.isCancelled else { return .cancelled }
            last = value
            collections[target.collection] = CollectionProgress(total: value.total, verified: value.verified,
                                                                failed: value.failed, state: .running)
            publish(title: target.title)
            if value.state == .running { sawRunning = true }
            if sawRunning ? value.state != .running : value.state == .finished { break }
            if let focus, focus != target.collection, !verifiedCollections.contains(focus), !unavailableCollections.contains(focus) {
                await loader.cancel()
                collections[target.collection]?.state = .queued
                return .preempted
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        collections[target.collection]?.state = .done
        publish(title: target.title)
        if let last, last.verified == last.total {
            verifiedCollections.insert(target.collection)
            return .verified
        }
        return .incomplete
    }

    private func verifiedSnapshot(_ repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor) async -> TimelineSnapshot? {
        for await event in await repository.timeline(collection: collection) {
            if Task.isCancelled { return nil }
            if case .value(let snapshot, true) = event { return snapshot }
        }
        return nil
    }

    private func folderDirectory(_ repository: CachedPhotosRepository, id: Int64, space: PhotoSpace,
                                 known: FolderSummary?) async -> (FolderDirectory, verified: Bool)? {
        var latest: (FolderDirectory, verified: Bool)?
        for await event in await repository.folderDirectory(id: id, space: space, known: known) {
            if Task.isCancelled { return nil }
            if case .value(let directory, let verified) = event { latest = (directory, verified) }
        }
        return latest
    }

    private func publish(title: String) {
        let values = collections.values
        progress = Progress(total: values.reduce(0) { $0 + $1.total },
                            verified: values.reduce(0) { $0 + $1.verified },
                            failed: values.reduce(0) { $0 + $1.failed },
                            running: true, currentTitle: title)
        updateActivityStatus()
    }

    private func beginActivity(_ center: ActivityCenter) {
        guard activityHandle == nil else { return }
        activityHandle = center.begin(.metadataSync)
        lastActivityStatus = nil
        updateActivityStatus()
    }

    /// At most once a second, so per-page progress does not re-render the Activity panel and toolbar.
    private func updateActivityStatus() {
        guard let activityHandle else { return }
        let now = ContinuousClock.now
        if let lastActivityStatus, now - lastActivityStatus < Self.activityStatusInterval { return }
        lastActivityStatus = now
        let title = progress.currentTitle ?? "Discovering collections"
        activityHandle.status(progress.total > 0 ? "\(title) · \(progress.verified) of \(progress.total) sections" : title)
        activityHandle.progress(fraction: progress.total > 0 ? Double(progress.verified) / Double(progress.total) : nil)
    }

    private func endActivity() {
        activityHandle?.discard()
        activityHandle = nil
    }
}

extension EnvironmentValues {
    /// The sync model without observing it. Views that only call its methods or pass it on
    /// read this instead of `@EnvironmentObject`, so its frequent progress updates do not
    /// re-render them.
    @Entry var metadataSyncModel: MetadataSyncModel?
}
