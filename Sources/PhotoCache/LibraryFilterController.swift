import Foundation
import SynologyAPI

public struct LibraryFilterCatalog: Equatable, Sendable {
    public var cameras: [String] = []
    public var lenses: [String] = []
    public var extensions: [String] = []
    public init() {}
}

public enum LibraryFilterSectionState: String, Sendable { case unseen, provisional, verified, failed }
public enum LibraryFilterScanDirection: Equatable, Sendable { case newer, older }

public struct TimelineSectionLoadProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable { case idle, running, canceling, finished }
    public var total: Int
    public var processed: Int
    public var indexed: Int
    public var verified: Int
    public var provisional: Int
    public var failed: Int
    public var remaining: Int
    public var isDiscoveringCachedPages: Bool
    public var hasInitialUnverifiedSection: Bool
    public var currentSectionLabel: String?
    public var matchCount: Int?
    public var state: State
    public var failures: [String]

    public init(total: Int, processed: Int, indexed: Int = 0, verified: Int, provisional: Int,
                failed: Int, remaining: Int, isDiscoveringCachedPages: Bool = false,
                hasInitialUnverifiedSection: Bool = false, currentSectionLabel: String?,
                matchCount: Int?, state: State, failures: [String]) {
        self.total = total; self.processed = processed; self.indexed = indexed
        self.verified = verified; self.provisional = provisional; self.failed = failed
        self.remaining = remaining; self.isDiscoveringCachedPages = isDiscoveringCachedPages
        self.hasInitialUnverifiedSection = hasInitialUnverifiedSection
        self.currentSectionLabel = currentSectionLabel; self.matchCount = matchCount
        self.state = state; self.failures = failures
    }
}

public struct LibraryFilterReference: Hashable, Sendable {
    public let sourceSectionIndex: Int
    public let sourcePageOffset: Int
    public let itemID: Int64
}

public struct LibraryFilterRegistration: Sendable {
    public let descriptor: PhotoCollectionDescriptor
    public let snapshot: TimelineSnapshot
    public let referencesBySection: [[LibraryFilterReference]]
    public let filter: LibraryFilter
    public let revision: UInt64
}

public struct LibraryFilterControllerEvent: Sendable {
    public let catalog: LibraryFilterCatalog
    public let progress: TimelineSectionLoadProgress
    public let registration: LibraryFilterRegistration?
}

private struct LibraryFilterRecord: Sendable {
    let reference: LibraryFilterReference
    let time: Int64
    let values: LibraryFilterValues
}

public actor LibraryFilterController {
    private struct QueuedRead: Sendable {
        let index: Int
        var useCachedPages: Bool
    }

    private struct ReadResult: Sendable {
        let index: Int
        let useCachedPages: Bool
        let emissions: [(items: [PhotoItem], verified: Bool)]
        let failure: String?
    }

    private let repository: CachedPhotosRepository
    private let sourceSnapshot: TimelineSnapshot
    private var recordsBySection: [Int: [LibraryFilterRecord]] = [:]
    private var states: [LibraryFilterSectionState]
    private var activeFilter: LibraryFilter?
    private var descriptor: PhotoCollectionDescriptor?
    private var revision: UInt64 = 0
    private var observers: [UUID: AsyncStream<LibraryFilterControllerEvent>.Continuation] = [:]
    private var cacheDiscoveryTask: Task<Void, Never>?
    private var cacheDiscoveryComplete = false
    private var scheduler: Task<Void, Never>?
    private var pending: [QueuedRead] = []
    private var activeIndices = Set<Int>()
    private var lastDemand: (direction: LibraryFilterScanDirection, sources: [Int], generation: UInt64)?
    private var failureMessages: [Int: String] = [:]
    private var failureCachePolicies: [Int: Bool] = [:]

    public init(repository: CachedPhotosRepository, snapshot: TimelineSnapshot) {
        self.repository = repository
        sourceSnapshot = snapshot
        states = Array(repeating: .unseen, count: snapshot.sections.count)
    }

    deinit { cacheDiscoveryTask?.cancel(); scheduler?.cancel() }

    public func observe() -> AsyncStream<LibraryFilterControllerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            observers[id] = continuation
            continuation.yield(makeEvent())
            continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }

    public func indexCachedPages() async {
        if cacheDiscoveryComplete { return }
        if cacheDiscoveryTask == nil {
            cacheDiscoveryTask = Task { await self.discoverCachedPages() }
            publish()
        }
        await cacheDiscoveryTask?.value
    }

    public func ingest(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        guard states.indices.contains(sectionIndex) else { return }
        if replace(sectionIndex: sectionIndex, items: items, verified: verified) { publish() }
    }

    public func apply(_ filter: LibraryFilter) async -> LibraryFilterRegistration {
        await indexCachedPages()
        activeFilter = filter
        descriptor = .libraryFilter(UUID())
        revision &+= 1
        let registration = makeRegistration()!
        publish(registration)
        return registration
    }

    public func demandVisibleResultSections(_ syntheticSectionIndices: [Int],
                                            direction: LibraryFilterScanDirection,
                                            userScrollGeneration: UInt64) {
        guard let registration = makeRegistration() else { return }
        let sourceIndices = Array(Set(syntheticSectionIndices.flatMap { synthetic -> [Int] in
            guard registration.referencesBySection.indices.contains(synthetic) else { return [] }
            return registration.referencesBySection[synthetic].map(\.sourceSectionIndex)
        })).sorted()
        guard !sourceIndices.isEmpty else { return }
        if let lastDemand, lastDemand.direction == direction,
           lastDemand.sources == sourceIndices, lastDemand.generation == userScrollGeneration { return }
        lastDemand = (direction, sourceIndices, userScrollGeneration)

        var candidates = sourceIndices.filter { states[$0] != .verified }
        switch direction {
        case .newer:
            if let first = sourceIndices.first, first > 0 {
                candidates.append(contentsOf: stride(from: first - 1, through: 0, by: -1))
            }
        case .older:
            if let last = sourceIndices.last, last + 1 < states.count {
                candidates.append(contentsOf: (last + 1)..<states.count)
            }
        }
        enqueue(candidates, useCachedPages: true, limit: 8)
    }

    public func loadInitialBatch() {
        enqueue(states.indices.filter { states[$0] != .failed }, useCachedPages: true, limit: 8)
    }

    public func loadAll(useCachedPages: Bool = false) async {
        await indexCachedPages()
        enqueue(Array(states.indices), useCachedPages: useCachedPages, limit: nil, upgradePolicy: true)
    }

    public func cancelScan() async {
        pending.removeAll()
        let active = scheduler
        active?.cancel()
        if let active { await active.value }
        scheduler = nil
        activeIndices.removeAll()
        publish()
    }

    public func retryFailed() {
        failureMessages.removeAll()
        for index in states.indices where states[index] == .failed {
            enqueue([index], useCachedPages: failureCachePolicies[index] ?? true, limit: nil)
        }
    }

    public func unregisterFilter() {
        activeFilter = nil
        descriptor = nil
        lastDemand = nil
        revision &+= 1
        publish(nil)
    }

    public func shutdown() {
        cacheDiscoveryTask?.cancel()
        scheduler?.cancel()
        pending.removeAll()
        activeIndices.removeAll()
        observers.values.forEach { $0.finish() }
        observers.removeAll()
    }

    private func discoverCachedPages() async {
        for start in stride(from: 0, to: states.count, by: 2) {
            guard !Task.isCancelled else { break }
            let indices = Array(start..<min(start + 2, states.count)).filter { states[$0] != .verified }
            let results = await read(indices: indices, useCachedPages: true, allowNetwork: false)
            guard !Task.isCancelled else { break }
            for result in results {
                for emission in result.emissions {
                    _ = replace(sectionIndex: result.index, items: emission.items, verified: emission.verified)
                }
            }
            publish()
        }
        guard !Task.isCancelled else { return }
        cacheDiscoveryComplete = true
        cacheDiscoveryTask = nil
        publish()
    }

    private func enqueue(_ indices: [Int], useCachedPages: Bool, limit: Int?, upgradePolicy: Bool = false) {
        var admitted = 0
        for index in indices where states.indices.contains(index) && states[index] != .verified {
            if activeIndices.contains(index) { continue }
            if let position = pending.firstIndex(where: { $0.index == index }) {
                if upgradePolicy && !useCachedPages { pending[position].useCachedPages = false }
                continue
            }
            if let limit, admitted >= limit { break }
            pending.append(.init(index: index, useCachedPages: useCachedPages))
            admitted += 1
        }
        if !pending.isEmpty { startSchedulerIfNeeded() } else { publish() }
    }

    private func startSchedulerIfNeeded() {
        guard scheduler == nil, !pending.isEmpty else { return }
        scheduler = Task { await scan() }
        publish()
    }

    private func scan() async {
        while !Task.isCancelled, !pending.isEmpty {
            let group = Array(pending.prefix(2))
            pending.removeFirst(group.count)
            activeIndices.formUnion(group.map(\.index))
            let cached = group.filter(\.useCachedPages).map(\.index)
            let uncached = group.filter { !$0.useCachedPages }.map(\.index)
            var results = await read(indices: cached, useCachedPages: true, allowNetwork: true)
            results += await read(indices: uncached, useCachedPages: false, allowNetwork: true)
            guard !Task.isCancelled else { break }
            results.sort { $0.index < $1.index }
            for result in results {
                activeIndices.remove(result.index)
                var changed = false
                for emission in result.emissions {
                    changed = replace(sectionIndex: result.index, items: emission.items,
                                      verified: emission.verified) || changed
                }
                if result.emissions.last?.verified != true {
                    states[result.index] = .failed
                    failureMessages[result.index] = result.failure ?? "Page validation did not complete."
                    failureCachePolicies[result.index] = result.useCachedPages
                    revision &+= 1
                    changed = true
                }
                if changed { publish() }
            }
        }
        activeIndices.removeAll()
        scheduler = nil
        publish()
    }

    private func read(indices: [Int], useCachedPages: Bool, allowNetwork: Bool) async -> [ReadResult] {
        await withTaskGroup(of: ReadResult.self, returning: [ReadResult].self) { tasks in
            for index in indices {
                let section = sourceSnapshot.sections[index]
                tasks.addTask { [repository] in
                    var emissions: [(items: [PhotoItem], verified: Bool)] = []
                    var failure: String?
                    for await event in await repository.page(section, collection: .personalLibrary,
                                                              useCachedPages: useCachedPages,
                                                              allowNetwork: allowNetwork,
                                                              priority: .prefetch) {
                        if Task.isCancelled { break }
                        switch event {
                        case .value(let items, let verified): emissions.append((items, verified))
                        case .failure(let message): failure = message
                        }
                    }
                    return .init(index: index, useCachedPages: useCachedPages,
                                 emissions: emissions, failure: failure)
                }
            }
            var result: [ReadResult] = []
            for await value in tasks { result.append(value) }
            return result.sorted { $0.index < $1.index }
        }
    }

    @discardableResult
    private func replace(sectionIndex: Int, items: [PhotoItem], verified: Bool) -> Bool {
        if !verified && states[sectionIndex] == .verified { return false }
        recordsBySection[sectionIndex] = items.enumerated().map {
            LibraryFilterRecord(reference: .init(sourceSectionIndex: sectionIndex,
                                                  sourcePageOffset: $0.offset,
                                                  itemID: $0.element.id),
                                time: $0.element.time, values: LibraryFilterValues($0.element))
        }
        states[sectionIndex] = verified ? .verified : .provisional
        if verified {
            failureMessages.removeValue(forKey: sectionIndex)
            failureCachePolicies.removeValue(forKey: sectionIndex)
        }
        revision &+= 1
        return true
    }

    private func orderedRecords() -> [LibraryFilterRecord] {
        var seen = Set<Int64>()
        return states.indices.flatMap { recordsBySection[$0] ?? [] }.filter {
            seen.insert($0.reference.itemID).inserted
        }
    }

    private func makeRegistration() -> LibraryFilterRegistration? {
        guard let filter = activeFilter, let descriptor else { return nil }
        let matching = orderedRecords().filter { filter.matches($0.values) }
        let entries = matching.map { DayTimelineEntry(id: $0.reference.itemID, time: $0.time) }
        let referencesByID = Dictionary(uniqueKeysWithValues: matching.map {
            ($0.reference.itemID, $0.reference)
        })
        let built = DayGroupedTimelineBuilder.build(entries: entries)
        let refs = built.itemIDsBySection.map { $0.compactMap { referencesByID[$0] } }
        return LibraryFilterRegistration(descriptor: descriptor, snapshot: built.snapshot,
                                         referencesBySection: refs, filter: filter, revision: revision)
    }

    private func makeCatalog() -> LibraryFilterCatalog {
        var cameraByKey: [String: String] = [:], lensByKey: [String: String] = [:]
        var extensions = Set<String>()
        for record in orderedRecords() {
            let values = record.values
            if let camera = values.camera {
                cameraByKey[LibraryFilterParsing.lookupKey(camera), default: camera] = camera
            }
            if let lens = values.lens {
                lensByKey[LibraryFilterParsing.lookupKey(lens), default: lens] = lens
            }
            if let ext = values.fileExtension { extensions.insert(ext) }
        }
        var result = LibraryFilterCatalog()
        result.cameras = cameraByKey.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        result.lenses = lensByKey.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        result.extensions = extensions.sorted()
        return result
    }

    private func makeProgress() -> TimelineSectionLoadProgress {
        let verified = states.filter { $0 == .verified }.count
        let provisional = states.filter { $0 == .provisional }.count
        let failed = states.filter { $0 == .failed }.count
        let processed = verified + provisional + failed
        let discovering = cacheDiscoveryTask != nil && !cacheDiscoveryComplete
        return .init(total: states.count, processed: processed, indexed: recordsBySection.count,
                     verified: verified, provisional: provisional, failed: failed,
                     remaining: states.filter { $0 != .verified }.count,
                     isDiscoveringCachedPages: discovering,
                     hasInitialUnverifiedSection: states.contains { $0 == .unseen || $0 == .provisional },
                     currentSectionLabel: scheduler == nil ? nil : "Loading Personal Library sections",
                     matchCount: makeRegistration()?.referencesBySection.reduce(0) { $0 + $1.count },
                     state: scheduler == nil ? (verified == states.count ? .finished : .idle) : .running,
                     failures: failureMessages.sorted { $0.key < $1.key }.map {
                         "Section \($0.key + 1): \($0.value)"
                     })
    }

    private func makeEvent() -> LibraryFilterControllerEvent {
        .init(catalog: makeCatalog(), progress: makeProgress(), registration: makeRegistration())
    }

    private func publish(_ registration: LibraryFilterRegistration? = nil) {
        let event = LibraryFilterControllerEvent(catalog: makeCatalog(), progress: makeProgress(),
                                                 registration: registration ?? makeRegistration())
        for observer in observers.values { observer.yield(event) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
