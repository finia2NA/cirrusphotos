import Foundation
import SynologyAPI

public struct TimelineSectionCacheProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case canceling
        case finished
    }

    public let total: Int
    public let verified: Int
    public let provisional: Int
    public let failed: Int
    public let remaining: Int
    public let state: State
    public let failures: [String]

    public var processed: Int { verified + provisional + failed }
}

public struct TimelineSectionCacheEmission: Equatable, Sendable {
    public let sectionIndex: Int
    public let items: [PhotoItem]
    public let verified: Bool

    public init(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        self.sectionIndex = sectionIndex
        self.items = items
        self.verified = verified
    }
}

public struct TimelineSectionCacheLoaderEvent: Equatable, Sendable {
    public let progress: TimelineSectionCacheProgress
    public let emission: TimelineSectionCacheEmission?
}

/// Explicitly warms every item-metadata page described by one captured,
/// authoritative collection timeline. The repository remains responsible for
/// cache reads, validation, mutation epochs, shared jobs, and persistence.
public actor TimelineSectionCacheLoader {
    private enum SectionState: Equatable, Sendable { case unseen, provisional, verified, failed }

    private struct QueuedRead: Sendable {
        let index: Int
        let useCachedPages: Bool
    }

    private struct ReadResult: Sendable {
        let index: Int
        let useCachedPages: Bool
        let verified: Bool
        let failure: String?
    }

    private let repository: CachedPhotosRepository
    private let collection: PhotoCollectionDescriptor
    private let snapshot: TimelineSnapshot
    private var states: [SectionState]
    private var pending: [QueuedRead] = []
    private var activeIndices = Set<Int>()
    private var failureMessages: [Int: String] = [:]
    private var failureCachePolicies: [Int: Bool] = [:]
    private var scheduler: Task<Void, Never>?
    private var wasCancelled = false
    private var observers: [UUID: AsyncStream<TimelineSectionCacheLoaderEvent>.Continuation] = [:]

    public init(repository: CachedPhotosRepository,
                collection: PhotoCollectionDescriptor,
                snapshot: TimelineSnapshot) {
        self.repository = repository
        self.collection = collection
        self.snapshot = snapshot
        states = Array(repeating: .unseen, count: snapshot.sections.count)
    }

    deinit { scheduler?.cancel() }

    public func observe() -> AsyncStream<TimelineSectionCacheLoaderEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            observers[id] = continuation
            continuation.yield(.init(progress: makeProgress(), emission: nil))
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeObserver(id) }
            }
        }
    }

    public func progress() -> TimelineSectionCacheProgress { makeProgress() }

    public func loadAll(useCachedPages: Bool = false) {
        guard scheduler == nil else { return }
        wasCancelled = false
        enqueue(states.indices.filter { states[$0] != .verified },
                useCachedPages: useCachedPages)
    }

    public func cancel() async {
        pending.removeAll()
        wasCancelled = true
        let active = scheduler
        active?.cancel()
        if let active { await active.value }
        scheduler = nil
        activeIndices.removeAll()
        publish()
    }

    public func retryFailed() {
        guard scheduler == nil else { return }
        let failed = states.indices.filter { states[$0] == .failed }
        guard !failed.isEmpty else { return }
        wasCancelled = false
        for index in failed {
            states[index] = .unseen
            failureMessages.removeValue(forKey: index)
        }
        for index in failed {
            pending.append(.init(index: index,
                                 useCachedPages: failureCachePolicies[index] ?? true))
        }
        startSchedulerIfNeeded()
    }

    public func shutdown() async {
        await cancel()
        observers.values.forEach { $0.finish() }
        observers.removeAll()
    }

    private func enqueue<S: Sequence>(_ indices: S, useCachedPages: Bool) where S.Element == Int {
        for index in indices where states.indices.contains(index) && states[index] != .verified {
            guard !activeIndices.contains(index), !pending.contains(where: { $0.index == index }) else { continue }
            pending.append(.init(index: index, useCachedPages: useCachedPages))
        }
        startSchedulerIfNeeded()
    }

    private func startSchedulerIfNeeded() {
        guard scheduler == nil, !pending.isEmpty else {
            publish()
            return
        }
        scheduler = Task { await runScheduler() }
        publish()
    }

    private func runScheduler() async {
        while !Task.isCancelled, !pending.isEmpty {
            let group = Array(pending.prefix(2))
            pending.removeFirst(group.count)
            activeIndices.formUnion(group.map(\.index))
            let results = await read(group)
            guard !Task.isCancelled else { break }
            for result in results.sorted(by: { $0.index < $1.index }) {
                activeIndices.remove(result.index)
                if result.verified {
                    states[result.index] = .verified
                    failureMessages.removeValue(forKey: result.index)
                    failureCachePolicies.removeValue(forKey: result.index)
                } else {
                    states[result.index] = .failed
                    failureMessages[result.index] = result.failure ?? "Page validation did not complete."
                    failureCachePolicies[result.index] = result.useCachedPages
                }
                publish()
            }
        }
        activeIndices.removeAll()
        scheduler = nil
        publish()
    }

    private func read(_ reads: [QueuedRead]) async -> [ReadResult] {
        await withTaskGroup(of: ReadResult.self, returning: [ReadResult].self) { tasks in
            for read in reads {
                let section = snapshot.sections[read.index]
                let collection = collection
                tasks.addTask { [repository] in
                    var verified = false
                    var failure: String?
                    for await event in await repository.page(
                        section,
                        collection: collection,
                        useCachedPages: read.useCachedPages,
                        allowNetwork: true,
                        priority: .prefetch
                    ) {
                        guard !Task.isCancelled else { break }
                        switch event {
                        case .value(let items, let isVerified):
                            await self.recordEmission(index: read.index, items: items,
                                                     verified: isVerified)
                            verified = verified || isVerified
                        case .failure(let message):
                            failure = message
                        }
                    }
                    return .init(index: read.index, useCachedPages: read.useCachedPages,
                                 verified: verified, failure: failure)
                }
            }
            var results: [ReadResult] = []
            for await result in tasks { results.append(result) }
            return results
        }
    }

    private func recordEmission(index: Int, items: [PhotoItem], verified: Bool) {
        guard states.indices.contains(index) else { return }
        if verified {
            states[index] = .verified
            failureMessages.removeValue(forKey: index)
            failureCachePolicies.removeValue(forKey: index)
        } else if states[index] != .verified {
            states[index] = .provisional
        }
        publish(emission: .init(sectionIndex: index, items: items, verified: verified))
    }

    private func makeProgress() -> TimelineSectionCacheProgress {
        let verified = states.filter { $0 == .verified }.count
        let provisional = states.filter { $0 == .provisional }.count
        let failed = states.filter { $0 == .failed }.count
        let state: TimelineSectionCacheProgress.State
        if scheduler != nil {
            state = .running
        } else if wasCancelled {
            state = .canceling
        } else if verified == states.count {
            state = .finished
        } else {
            state = .idle
        }
        return .init(total: states.count, verified: verified, provisional: provisional,
                     failed: failed, remaining: states.count - verified,
                     state: state,
                     failures: failureMessages.sorted(by: { $0.key < $1.key }).map {
                         "Section \($0.key + 1): \($0.value)"
                     })
    }

    private func publish(emission: TimelineSectionCacheEmission? = nil) {
        let event = TimelineSectionCacheLoaderEvent(progress: makeProgress(), emission: emission)
        observers.values.forEach { $0.yield(event) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
