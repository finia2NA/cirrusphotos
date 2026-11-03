import Foundation
import SynologyAPI

public struct LibraryFilterCatalog: Codable, Equatable, Sendable {
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
    public var sourceVerified: Bool = true
}

public struct LibraryFilterRegistration: Sendable {
    public let descriptor: PhotoCollectionDescriptor
    public let snapshot: TimelineSnapshot
    public let referencesBySection: [[LibraryFilterReference]]
    public let filter: LibraryFilter
    public let revision: UInt64
    public let sourceFingerprint: String
    public let sourceCollection: PhotoCollectionDescriptor
}

public struct LibraryFilterControllerEvent: Sendable {
    public let catalog: LibraryFilterCatalog
    public let progress: TimelineSectionLoadProgress
    public let registration: LibraryFilterRegistration?
}

private struct LibraryFilterRecord: Equatable, Sendable {
    let reference: LibraryFilterReference
    let time: Int64
    let values: LibraryFilterValues
}

public actor LibraryFilterController {
    private struct QueuedRead: Sendable {
        let index: Int
        let useCachedPages: Bool
    }

    private struct ReadResult: Sendable {
        let index: Int
        let useCachedPages: Bool
        let emissions: [(items: [PhotoItem?], verified: Bool)]
        let failure: String?
    }

    private static let cacheReadBatchSize = 64
    private static let scanGroupSize = 64
    private static let demandLimit = 8
    private let repository: CachedPhotosRepository
    private let sourceFingerprint: String
    private let sourceCollection: PhotoCollectionDescriptor
    private let sourceSnapshot: TimelineSnapshot
    private let sectionIndexByAddress: [DayPageAddress: Int]
    private var recordsBySection: [Int: [LibraryFilterRecord]] = [:]
    private var cachedCatalog: LibraryFilterCatalog?
    private var persistedCatalog = LibraryFilterCatalog()
    private var catalogAdmission: MetadataStoreAdmission?
    private var catalogWriteTask: Task<Void, Never>?
    private var cachedRegistration: LibraryFilterRegistration?
    private var states: [LibraryFilterSectionState]
    private var activeFilter: LibraryFilter?
    private var descriptor: PhotoCollectionDescriptor?
    private var revision: UInt64 = 0
    private var observers: [UUID: AsyncStream<LibraryFilterControllerEvent>.Continuation] = [:]
    private var cacheDiscoveryTask: Task<Void, Never>?
    private var cacheDiscoveryComplete = false
    private var pageObservation: CollectionPageObservation?
    private var pageObservationTask: Task<Void, Never>?
    private var invalidationTask: Task<Void, Never>?
    private var stopped = false
    private var scheduler: Task<Void, Never>?
    private var pending: [QueuedRead] = []
    private var activeIndices = Set<Int>()
    private var lastDemand: (direction: LibraryFilterScanDirection, sources: [Int], generation: UInt64)?
    private var failureMessages: [Int: String] = [:]
    private var failureCachePolicies: [Int: Bool] = [:]
    private var networkAllowed: Bool
    private var scanDirty = false

    public init(repository: CachedPhotosRepository, snapshot: TimelineSnapshot, sourceCollection: PhotoCollectionDescriptor,
                networkAllowed: Bool = true) {
        self.repository = repository
        self.networkAllowed = networkAllowed
        self.sourceCollection = sourceCollection
        sourceSnapshot = snapshot
        sectionIndexByAddress = Dictionary(snapshot.sections.enumerated().compactMap { index, section in
            (try? DayPageAddress(section: section, collection: sourceCollection)).map { ($0, index) }
        }, uniquingKeysWith: { first, _ in first })
        sourceFingerprint = LibraryIndex(snapshot: snapshot).fingerprint
        states = Array(repeating: .unseen, count: snapshot.sections.count)
    }

    deinit { cacheDiscoveryTask?.cancel(); scheduler?.cancel(); pageObservationTask?.cancel(); invalidationTask?.cancel(); catalogWriteTask?.cancel() }

    public func observe() -> AsyncStream<LibraryFilterControllerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            observers[id] = continuation
            continuation.yield(makeEvent())
            continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }

    public func indexCachedPages(reconcile: Bool = false) async {
        guard !stopped else { return }
        startCacheDiscovery(reconcile: reconcile)
        await cacheDiscoveryTask?.value
    }

    private func startCacheDiscovery(reconcile: Bool = false) {
        guard !stopped, !(cacheDiscoveryComplete && !reconcile) else { return }
        if cacheDiscoveryTask == nil {
            cacheDiscoveryComplete = false
            cacheDiscoveryTask = Task {
                await self.loadCachedCatalog()
                await self.observePagesIfNeeded()
                await self.discoverCachedPages()
            }
            publish()
        }
    }

    func ingest(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        guard !stopped, states.indices.contains(sectionIndex) else { return }
        if replace(sectionIndex: sectionIndex, items: items.map(Optional.some), verified: verified) { publish() }
    }

    public func apply(_ filter: LibraryFilter) -> LibraryFilterRegistration {
        startCacheDiscovery()
        pending.removeAll()
        activeFilter = filter
        descriptor = .libraryFilter(UUID(), scope: sourceCollection.contentScope)
        revision &+= 1
        cachedRegistration = nil
        let registration = makeRegistration()!
        publish(registration)
        return registration
    }

    public func currentEvent() -> LibraryFilterControllerEvent { makeEvent() }

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
        enqueue(candidates.filter { states[$0] != .failed }, useCachedPages: true, limit: Self.demandLimit, front: true)
    }

    public func loadInitialBatch() {
        enqueue(states.indices.filter { states[$0] != .failed }, useCachedPages: true, limit: Self.demandLimit)
    }

    public func setNetworkAllowed(_ allowed: Bool) {
        guard allowed != networkAllowed else { return }
        networkAllowed = allowed
        guard allowed, !stopped else { return }
        // The source timeline is now verified this run, so Diff-proven cached pages
        // can be reread as verified without a request.
        if cacheDiscoveryTask == nil { startCacheDiscovery(reconcile: true) }
        if !pending.isEmpty { startSchedulerIfNeeded() }
    }

    public func retryFailed() {
        failureMessages.removeAll()
        for index in states.indices where states[index] == .failed {
            enqueue([index], useCachedPages: failureCachePolicies[index] ?? true, limit: nil)
        }
    }

    public func unregisterFilter() {
        pending.removeAll()
        activeFilter = nil
        descriptor = nil
        cachedRegistration = nil
        lastDemand = nil
        revision &+= 1
        publish(nil)
    }

    public func shutdown() async {
        let finalCatalog = cacheDiscoveryComplete ? makeCatalog() : nil
        let admission = catalogAdmission
        stopped = true
        cacheDiscoveryTask?.cancel()
        pageObservationTask?.cancel()
        invalidationTask?.cancel()
        catalogWriteTask?.cancel()
        if let pageObservation { await repository.removeCollectionPageObserver(pageObservation.id) }
        pageObservation = nil
        scheduler?.cancel()
        pending.removeAll()
        activeIndices.removeAll()
        observers.values.forEach { $0.finish() }
        observers.removeAll()
        if let finalCatalog, let admission {
            try? await repository.storeFilterOptionCatalog(finalCatalog, for: sourceCollection, originalAdmission: admission)
        }
    }

    private func discoverCachedPages() async {
        if sourceCollection.isSessionDerived { await discoverCachedPagesByReading() }
        else if let pages = try? await repository.cachedFilterPages(collection: sourceCollection, days: nil) {
            guard !stopped, !Task.isCancelled else { return }
            if applyCachedFilterPages(pages) { publish() }
        }
        guard !stopped, !Task.isCancelled else { return }
        cacheDiscoveryComplete = true
        cachedCatalog = nil
        persistedCatalog = makeCatalog()
        await persistCatalog()
        guard !stopped, !Task.isCancelled else { return }
        cacheDiscoveryTask = nil
        publish()
    }

    private func discoverCachedPagesByReading() async {
        for start in stride(from: 0, to: states.count, by: Self.cacheReadBatchSize) {
            guard !stopped, !Task.isCancelled else { break }
            let indices = Array(start..<min(start + Self.cacheReadBatchSize, states.count))
            let results = await read(indices.map { .init(index: $0, useCachedPages: true) }, allowNetwork: false)
            guard !stopped, !Task.isCancelled else { break }
            var changed = false
            for result in results {
                for emission in result.emissions {
                    changed = replace(sectionIndex: result.index, items: emission.items,
                                      verified: emission.verified) || changed
                }
            }
            if changed { publish() }
        }
    }

    private func applyCachedFilterPages(_ pages: [MetadataFilterPage], only indices: Set<Int>? = nil) -> Bool {
        var changed = false
        for page in pages {
            guard let index = sectionIndexByAddress[page.address], indices?.contains(index) ?? true else { continue }
            let records = page.entries.compactMap { entry -> LibraryFilterRecord? in
                guard let time = entry.time else { return nil }
                return LibraryFilterRecord(reference: .init(sourceSectionIndex: index, sourcePageOffset: entry.ordinal,
                                                            itemID: entry.itemID, sourceVerified: page.verified),
                                           time: time, values: entry.values)
            }
            changed = replace(sectionIndex: index, records: records, verified: page.verified) || changed
        }
        return changed
    }

    private func observePagesIfNeeded() async {
        guard pageObservation == nil, !stopped else { return }
        let observation = await repository.observeCollectionPages(collection: sourceCollection, sections: Set(sourceSnapshot.sections))
        guard !stopped, !Task.isCancelled else {
            await repository.removeCollectionPageObserver(observation.id)
            return
        }
        pageObservation = observation
        let invalidations = await repository.observeMetadataChanges(collection: sourceCollection)
        guard !stopped, !Task.isCancelled else { return }
        invalidationTask = Task { [weak self, repository] in
            for await _ in invalidations.changes {
                guard !Task.isCancelled else { break }
                if let change = await repository.takeMetadataChanges(invalidations.id) {
                    await self?.invalidateSource(change)
                }
            }
        }
        pageObservationTask = Task { [weak self, repository] in
            for await _ in observation.changes {
                guard !Task.isCancelled else { break }
                let sections = await repository.takeCollectionPageChanges(observation.id)
                await self?.receiveCachedPages(sections)
            }
        }
    }

    private func invalidateSource(_ change: MetadataCollectionInvalidation) {
        var invalidated: [Int] = []
        for index in states.indices {
            guard let raw = sourceSnapshot.sections[index].list.first,
                  let day = try? CaptureDay(year: raw.year, month: raw.month, day: raw.day),
                  change.days == nil || change.days!.contains(day),
                  states[index] == .verified else { continue }
            states[index] = .provisional
            recordsBySection[index] = recordsBySection[index]?.map { record in
                var reference = record.reference
                reference.sourceVerified = false
                return LibraryFilterRecord(reference: reference, time: record.time, values: record.values)
            }
            invalidated.append(index)
        }
        guard !invalidated.isEmpty else { return }
        revision &+= 1
        cachedRegistration = nil
        publish()
        if activeFilter != nil { enqueue(invalidated, useCachedPages: true, limit: Self.demandLimit) }
    }

    private func receiveCachedPages(_ sections: Set<TimelineSection>) async {
        let indices = sourceSnapshot.sections.indices.filter { sections.contains(sourceSnapshot.sections[$0]) }
        if !sourceCollection.isSessionDerived {
            let days = Set(indices.compactMap { index in
                sourceSnapshot.sections[index].list.first.flatMap { try? CaptureDay(year: $0.year, month: $0.month, day: $0.day) }
            })
            guard !days.isEmpty, let pages = try? await repository.cachedFilterPages(collection: sourceCollection, days: days) else { return }
            guard !stopped, !Task.isCancelled else { return }
            if applyCachedFilterPages(pages, only: Set(indices)) { publish() }
            return
        }
        for start in stride(from: 0, to: indices.count, by: Self.cacheReadBatchSize) {
            guard !stopped, !Task.isCancelled else { return }
            let batch = Array(indices[start..<min(start + Self.cacheReadBatchSize, indices.count)])
            let results = await read(batch.map { .init(index: $0, useCachedPages: true) }, allowNetwork: false)
            guard !stopped, !Task.isCancelled else { return }
            var changed = false
            for result in results {
                for emission in result.emissions {
                    changed = replace(sectionIndex: result.index, items: emission.items,
                                      verified: emission.verified) || changed
                }
            }
            if changed { publish() }
        }
    }

    private func enqueue(_ indices: [Int], useCachedPages: Bool, limit: Int?, front: Bool = false) {
        guard !stopped else { return }
        var admitted = 0
        var added: [QueuedRead] = []
        for index in indices where states.indices.contains(index) && states[index] != .verified {
            if activeIndices.contains(index) { continue }
            if pending.contains(where: { $0.index == index }) { continue }
            if let limit, admitted >= limit { break }
            added.append(.init(index: index, useCachedPages: useCachedPages))
            admitted += 1
        }
        if front { pending.insert(contentsOf: added, at: 0) } else { pending.append(contentsOf: added) }
        if !pending.isEmpty { startSchedulerIfNeeded() } else { publish() }
    }

    private func startSchedulerIfNeeded() {
        guard networkAllowed, scheduler == nil, !pending.isEmpty else { return }
        scheduler = Task { await scan() }
        publish()
    }

    private func scan() async {
        while !Task.isCancelled, !pending.isEmpty {
            let group = Array(pending.prefix(Self.scanGroupSize))
            pending.removeFirst(group.count)
            activeIndices.formUnion(group.map(\.index))
            let results = await read(group, allowNetwork: true)
            guard !Task.isCancelled else { break }
            var groupChanged = scanDirty
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
                groupChanged = groupChanged || changed
            }
            scanDirty = false
            if groupChanged { publish() }
        }
        activeIndices.removeAll()
        scheduler = nil
        publish()
    }

    private func read(_ reads: [QueuedRead], allowNetwork: Bool) async -> [ReadResult] {
        let batch = allowNetwork
            ? await repository.beginMetadataPageDemandBatch(reads.map { sourceSnapshot.sections[$0.index] }, collection: sourceCollection)
            : nil
        let results = await withTaskGroup(of: ReadResult.self, returning: [ReadResult].self) { tasks in
            for read in reads {
                let index = read.index, useCachedPages = read.useCachedPages
                let section = sourceSnapshot.sections[index]
                tasks.addTask { [repository] in
                    var emissions: [(items: [PhotoItem?], verified: Bool)] = []
                    var failure: String?
                    for await event in await repository.page(section, collection: self.sourceCollection,
                                                              useCachedPages: useCachedPages,
                                                              allowNetwork: allowNetwork,
                                                              priority: .prefetch) {
                        if Task.isCancelled { break }
                        switch event {
                        case .value(let items, let verified):
                            let slots = items.slots.map(\.item)
                            emissions.append((slots, verified))
                            if allowNetwork { await self.receiveScanEmission(index: index, items: slots, verified: verified) }
                        case .failure(let message): failure = message.localizedDescription
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
        if let batch { await repository.endMetadataPageDemandBatch(batch) }
        return results
    }

    private func receiveScanEmission(index: Int, items: [PhotoItem?], verified: Bool) {
        guard !stopped, !Task.isCancelled else { return }
        if replace(sectionIndex: index, items: items, verified: verified) { scanDirty = true }
    }

    @discardableResult
    private func replace(sectionIndex: Int, items: [PhotoItem?], verified: Bool) -> Bool {
        if !verified && states[sectionIndex] == .verified { return false }
        let records = items.enumerated().compactMap { offset, optional -> LibraryFilterRecord? in
            guard let item = optional else { return nil }
            guard let time = sourceCollection.membershipTime(for: item) else { return nil }
            return LibraryFilterRecord(reference: .init(sourceSectionIndex: sectionIndex, sourcePageOffset: offset, itemID: item.id, sourceVerified: verified),
                                       time: time, values: LibraryFilterValues(item))
        }
        return replace(sectionIndex: sectionIndex, records: records, verified: verified)
    }

    @discardableResult
    private func replace(sectionIndex: Int, records: [LibraryFilterRecord], verified: Bool) -> Bool {
        if !verified && states[sectionIndex] == .verified { return false }
        let nextState: LibraryFilterSectionState = verified ? .verified : .provisional
        guard recordsBySection[sectionIndex] != records || states[sectionIndex] != nextState else { return false }
        recordsBySection[sectionIndex] = records
        cachedCatalog = nil
        cachedRegistration = nil
        states[sectionIndex] = nextState
        if verified {
            failureMessages.removeValue(forKey: sectionIndex)
            failureCachePolicies.removeValue(forKey: sectionIndex)
        }
        revision &+= 1
        if cacheDiscoveryComplete { scheduleCatalogWrite() }
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
        if let cachedRegistration { return cachedRegistration }
        let matching = orderedRecords().filter { filter.matches($0.values) }
        let entries = matching.map { DayTimelineEntry(id: $0.reference.itemID, time: $0.time) }
        let referencesByID = Dictionary(uniqueKeysWithValues: matching.map {
            ($0.reference.itemID, $0.reference)
        })
        let built = DayGroupedTimelineBuilder.build(entries: entries)
        let refs = built.itemIDsBySection.map { $0.compactMap { referencesByID[$0] } }
        let registration = LibraryFilterRegistration(descriptor: descriptor, snapshot: built.snapshot,
                                         referencesBySection: refs, filter: filter, revision: revision, sourceFingerprint: sourceFingerprint, sourceCollection: sourceCollection)
        cachedRegistration = registration
        return registration
    }

    private func makeCatalog() -> LibraryFilterCatalog {
        if let cachedCatalog { return cachedCatalog }
        let complete = cacheDiscoveryComplete && states.indices.allSatisfy { index in
            states[index] != .unseen && recordsBySection[index]?.count == sourceSnapshot.sections[index].limit
        }
        var cameraByKey: [String: String] = [:], lensByKey: [String: String] = [:]
        var extensions = Set<String>()
        if !complete {
            for value in persistedCatalog.cameras { cameraByKey[LibraryFilterParsing.lookupKey(value)] = value }
            for value in persistedCatalog.lenses { lensByKey[LibraryFilterParsing.lookupKey(value)] = value }
            extensions.formUnion(persistedCatalog.extensions)
        }
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
        cachedCatalog = result
        return result
    }

    private func loadCachedCatalog() async {
        do {
            let (catalog, admission) = try await repository.loadFilterOptionCatalog(for: sourceCollection)
            guard !stopped, !Task.isCancelled else { return }
            catalogAdmission = admission
            if let catalog {
                persistedCatalog = catalog
                cachedCatalog = nil
                publish()
            }
        } catch { /* Discovery remains usable if this optional cache cannot be read. */ }
    }

    private func scheduleCatalogWrite() {
        catalogWriteTask?.cancel()
        catalogWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.persistCatalog()
        }
    }

    private func persistCatalog() async {
        guard !stopped, !Task.isCancelled, let admission = catalogAdmission else { return }
        let catalog = makeCatalog()
        do {
            try await repository.storeFilterOptionCatalog(catalog, for: sourceCollection, originalAdmission: admission)
            guard !stopped, !Task.isCancelled else { return }
            persistedCatalog = catalog
        } catch { /* A reset or unavailable cache must not block filtering. */ }
    }

    private func makeProgress(registration: LibraryFilterRegistration?) -> TimelineSectionLoadProgress {
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
                     currentSectionLabel: scheduler == nil ? nil : "Loading collection sections",
                     matchCount: registration?.referencesBySection.reduce(0) { $0 + $1.count },
                     state: scheduler == nil ? (verified == states.count ? .finished : .idle) : .running,
                     failures: failureMessages.sorted { $0.key < $1.key }.map {
                         "Section \($0.key + 1): \($0.value)"
                     })
    }

    private func makeEvent() -> LibraryFilterControllerEvent {
        let registration = makeRegistration()
        return .init(catalog: makeCatalog(), progress: makeProgress(registration: registration), registration: registration)
    }

    private func publish(_ registration: LibraryFilterRegistration? = nil) {
        let registration = registration ?? makeRegistration()
        let event = LibraryFilterControllerEvent(catalog: makeCatalog(), progress: makeProgress(registration: registration),
                                                 registration: registration)
        for observer in observers.values { observer.yield(event) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
