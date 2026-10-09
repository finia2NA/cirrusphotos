import Foundation
import SynologyAPI

public struct LibraryFilterCatalog: Equatable, Sendable {
    public var cameras: [String] = []
    public var lenses: [String] = []
    public var extensions: [String] = []
    public init() {}
}

public enum LibraryFilterSectionState: String, Sendable { case unseen, provisional, verified, failed }

public struct TimelineSectionLoadProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable { case idle, running, canceling, finished }
    public var total: Int
    public var processed: Int
    public var verified: Int
    public var provisional: Int
    public var failed: Int
    public var remaining: Int
    public var currentSectionLabel: String?
    public var matchCount: Int?
    public var state: State
    public var failures: [String]

    public init(total: Int, processed: Int, verified: Int, provisional: Int, failed: Int,
                remaining: Int, currentSectionLabel: String?, matchCount: Int?,
                state: State, failures: [String]) {
        self.total = total; self.processed = processed; self.verified = verified
        self.provisional = provisional; self.failed = failed; self.remaining = remaining
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
    private let repository: CachedPhotosRepository
    private let sourceSnapshot: TimelineSnapshot
    private var recordsBySection: [Int: [LibraryFilterRecord]] = [:]
    private var states: [LibraryFilterSectionState]
    private var activeFilter: LibraryFilter?
    private var descriptor: PhotoCollectionDescriptor?
    private var revision: UInt64 = 0
    private var observers: [UUID: AsyncStream<LibraryFilterControllerEvent>.Continuation] = [:]
    private var scheduler: Task<Void, Never>?
    private var target = 0
    private var loadAllRequested = false
    private var scanUsesCachedPages = true
    private var failureMessages: [Int: String] = [:]

    public init(repository: CachedPhotosRepository, snapshot: TimelineSnapshot) {
        self.repository = repository
        sourceSnapshot = snapshot
        states = Array(repeating: .unseen, count: snapshot.sections.count)
    }

    deinit { scheduler?.cancel() }

    public func observe() -> AsyncStream<LibraryFilterControllerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            observers[id] = continuation
            continuation.yield(makeEvent())
            continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }

    public func ingest(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        guard states.indices.contains(sectionIndex) else { return }
        replace(sectionIndex: sectionIndex, items: items, verified: verified)
        publish()
    }

    public func apply(_ filter: LibraryFilter) async -> LibraryFilterRegistration {
        activeFilter = filter
        descriptor = .libraryFilter(UUID())
        revision &+= 1
        let registration = makeRegistration()!
        publish(registration)
        return registration
    }

    public func loadNextBatch() {
        // Failed sections remain retryable but must not prevent the user from
        // continuing into older unseen sections. `retryFailed()` handles them
        // explicitly without making ordinary tail loading repeat failures.
        let firstUnseen = states.firstIndex { $0 == .unseen } ?? states.count
        target = max(target, min(states.count, firstUnseen + 8))
        if scheduler == nil { scanUsesCachedPages = true }
        startSchedulerIfNeeded()
    }

    public func loadAll(useCachedPages: Bool = false) {
        for index in states.indices where states[index] == .provisional || states[index] == .failed {
            states[index] = .unseen
        }
        loadAllRequested = true
        target = states.count
        if scheduler == nil { scanUsesCachedPages = useCachedPages }
        startSchedulerIfNeeded()
    }

    public func cancelScan() async {
        let active = scheduler
        active?.cancel()
        if let active { await active.value }
        scheduler = nil
        loadAllRequested = false
        publish()
    }

    public func retryFailed() {
        for index in states.indices where states[index] == .failed { states[index] = .unseen }
        failureMessages.removeAll()
        loadAll(useCachedPages: scanUsesCachedPages)
    }

    public func unregisterFilter() {
        activeFilter = nil
        descriptor = nil
        revision &+= 1
        publish(nil)
    }

    private func startSchedulerIfNeeded() {
        guard scheduler == nil else { return }
        scheduler = Task { await scan() }
        publish()
    }

    private struct ScanResult: Sendable {
        let index: Int
        let emissions: [(items: [PhotoItem], verified: Bool)]
        let failure: String?
    }

    private func scan() async {
        while !Task.isCancelled {
            // A failed request settles this scheduler run. Retrying is an explicit
            // state transition through `retryFailed()` or a later `loadAll()` call;
            // otherwise a persistent transport failure would spin forever.
            let candidates = states.indices.filter { $0 < target && states[$0] == .unseen }
            guard !candidates.isEmpty else { break }
            let group = Array(candidates.prefix(2))
            let useCachedPages = scanUsesCachedPages
            let results = await withTaskGroup(of: ScanResult.self, returning: [ScanResult].self) { tasks in
                for index in group {
                    let section = sourceSnapshot.sections[index]
                    tasks.addTask { [repository, useCachedPages] in
                        var emissions: [(items: [PhotoItem], verified: Bool)] = []
                        var failure: String?
                        for await event in await repository.page(section, collection: .personalLibrary,
                                                                  useCachedPages: useCachedPages,
                                                                  allowNetwork: true, priority: .prefetch) {
                            if Task.isCancelled { break }
                            switch event {
                            case .value(let items, let isVerified): emissions.append((items, isVerified))
                            case .failure(let message): failure = message
                            }
                        }
                        return ScanResult(index: index, emissions: emissions, failure: failure)
                    }
                }
                var results: [ScanResult] = []
                for await result in tasks { results.append(result) }
                return results.sorted { $0.index < $1.index }
            }
            for result in results {
                for emission in result.emissions {
                    replace(sectionIndex: result.index, items: emission.items, verified: emission.verified)
                    publish()
                }
                let verified = result.emissions.last?.verified == true
                if !verified {
                    states[result.index] = result.failure != nil ? .failed : (result.emissions.isEmpty ? .failed : .provisional)
                    if let failure = result.failure { failureMessages[result.index] = failure }
                }
            }
            revision &+= 1
            publish()
        }
        scheduler = nil
        loadAllRequested = false
        publish()
    }

    private func replace(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        recordsBySection[sectionIndex] = items.enumerated().map {
            LibraryFilterRecord(reference: .init(sourceSectionIndex: sectionIndex,
                                                  sourcePageOffset: $0.offset, itemID: $0.element.id),
                                time: $0.element.time, values: LibraryFilterValues($0.element))
        }
        states[sectionIndex] = verified ? .verified : .provisional
        if verified { failureMessages.removeValue(forKey: sectionIndex) }
        revision &+= 1
    }

    private func makeRegistration() -> LibraryFilterRegistration? {
        guard let filter = activeFilter, let descriptor else { return nil }
        var entries: [DayTimelineEntry] = []
        var referencesByID: [Int64: LibraryFilterReference] = [:]
        let contiguous = states.prefix { $0 != .unseen && $0 != .failed }.count
        var includedCount = contiguous
        if includedCount < sourceSnapshot.sections.count, includedCount > 0,
           sharesDay(sourceSnapshot.sections[includedCount - 1], sourceSnapshot.sections[includedCount]) {
            while includedCount > 0 && sharesDay(sourceSnapshot.sections[includedCount - 1], sourceSnapshot.sections[includedCount]) {
                includedCount -= 1
            }
        }
        for index in 0..<includedCount {
            for record in recordsBySection[index, default: []] where filter.matches(record.values) {
                entries.append(.init(id: record.reference.itemID, time: record.time))
                referencesByID[record.reference.itemID] = record.reference
            }
        }
        let built = DayGroupedTimelineBuilder.build(entries: entries)
        let refs = built.itemIDsBySection.map { $0.compactMap { referencesByID[$0] } }
        return LibraryFilterRegistration(descriptor: descriptor, snapshot: built.snapshot,
                                         referencesBySection: refs, filter: filter, revision: revision)
    }

    private func sharesDay(_ lhs: TimelineSection, _ rhs: TimelineSection) -> Bool {
        guard let old = lhs.list.last, let new = rhs.list.first else { return false }
        return old.year == new.year && old.month == new.month && old.day == new.day
    }

    private func makeCatalog() -> LibraryFilterCatalog {
        var cameraByKey: [String: String] = [:], lensByKey: [String: String] = [:]
        var extensions = Set<String>()
        for records in recordsBySection.values {
            for record in records {
                let values = record.values
                if let camera = values.camera { cameraByKey[LibraryFilterParsing.lookupKey(camera), default: camera] = camera }
                if let lens = values.lens { lensByKey[LibraryFilterParsing.lookupKey(lens), default: lens] = lens }
                if let ext = values.fileExtension { extensions.insert(ext) }
            }
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
        return .init(total: states.count, processed: processed, verified: verified,
                     provisional: provisional, failed: failed, remaining: states.filter { $0 != .verified }.count,
                     currentSectionLabel: scheduler == nil ? nil : "Section \(min(processed + 1, states.count))",
                     matchCount: makeRegistration()?.referencesBySection.reduce(0) { $0 + $1.count },
                     state: scheduler == nil ? (verified == states.count ? .finished : .idle) : .running,
                     failures: failureMessages.sorted { $0.key < $1.key }.map { "Section \($0.key + 1): \($0.value)" })
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
