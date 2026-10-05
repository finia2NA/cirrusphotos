import Foundation
import SynologyAPI

/// A summary of the selected items for the info panel.
public struct SelectionInfo: Sendable, Equatable {
    public let itemCount: Int
    public let newestDayID: String?
    public let oldestDayID: String?
    public let resolvedCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let cumulativeSize: Int64?
    public let isComplete: Bool
    public let hadFailure: Bool
    public let singleItem: PhotoItem?

    public init(itemCount: Int, newestDayID: String?, oldestDayID: String?,
                resolvedCount: Int, photoCount: Int, videoCount: Int,
                cumulativeSize: Int64?, isComplete: Bool, hadFailure: Bool,
                singleItem: PhotoItem?) {
        self.itemCount = itemCount
        self.newestDayID = newestDayID
        self.oldestDayID = oldestDayID
        self.resolvedCount = resolvedCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.cumulativeSize = cumulativeSize
        self.isComplete = isComplete
        self.hadFailure = hadFailure
        self.singleItem = singleItem
    }
}

/// Resolves a selection's exact size and type counts by reading only the timeline
/// sections that contain selected ordinals, at most two at a time, with compact
/// per-section item retention.
public struct SelectionInfoResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) {
        self.repository = repository
    }

    public func resolve(collection: PhotoCollectionDescriptor,
                        snapshot: TimelineSnapshot,
                        selectedOrdinals: IndexSet) -> AsyncStream<SelectionInfo> {
        let repository = self.repository
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let producer = StreamProducer()
            producer.task = Task {
                await Self.produce(repository: repository, collection: collection,
                                   snapshot: snapshot, selectedOrdinals: selectedOrdinals,
                                   continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    private static func produce(repository: CachedPhotosRepository,
                                collection: PhotoCollectionDescriptor,
                                snapshot: TimelineSnapshot,
                                selectedOrdinals: IndexSet,
                                continuation: AsyncStream<SelectionInfo>.Continuation) async {
        guard !selectedOrdinals.isEmpty else {
            continuation.yield(SelectionInfo(itemCount: 0, newestDayID: nil, oldestDayID: nil,
                                             resolvedCount: 0, photoCount: 0, videoCount: 0,
                                             cumulativeSize: nil, isComplete: true,
                                             hadFailure: false, singleItem: nil))
            return
        }
        let index = LibraryIndex(snapshot: snapshot)
        let locations = selectedOrdinals.compactMap { index.location(forOrdinal: $0) }
        guard locations.count == selectedOrdinals.count else {
            continuation.yield(SelectionInfo(itemCount: selectedOrdinals.count,
                                             newestDayID: nil, oldestDayID: nil,
                                             resolvedCount: 0, photoCount: 0, videoCount: 0,
                                             cumulativeSize: nil, isComplete: true,
                                             hadFailure: true, singleItem: nil))
            return
        }

        var locationsBySection: [Int: [LibraryIndex.Location]] = [:]
        for location in locations {
            locationsBySection[location.sectionIndex, default: []].append(location)
        }
        let singleLocation = selectedOrdinals.count == 1 ? locations.first : nil
        let accumulator = SelectionInfoAccumulator(
            itemCount: selectedOrdinals.count,
            newestDayID: locations.map(\.dayID).max(),
            oldestDayID: locations.map(\.dayID).min(),
            singleLocation: singleLocation.map {
                SelectionInfoAccumulator.SingleLocation(sectionIndex: $0.sectionIndex,
                                                        pageOffset: $0.pageOffset)
            },
            sectionCount: locationsBySection.count
        )
        if let initial = await accumulator.initial() { continuation.yield(initial) }

        let sectionIndices = locationsBySection.keys.sorted()
        let concurrency = 2
        var cursor = 0
        while cursor < sectionIndices.count {
            if Task.isCancelled { return }
            let end = min(cursor + concurrency, sectionIndices.count)
            let chunk = Array(sectionIndices[cursor..<end])
            cursor = end
            let (updates, updatesContinuation) = AsyncStream<SectionUpdate>.makeStream()
            let consumer = Task {
                for await update in updates {
                    if let info = await accumulator.apply(update) { continuation.yield(info) }
                }
            }
            await withTaskGroup(of: Void.self) { group in
                for sectionIndex in chunk {
                    let descriptor = index.sections[sectionIndex]
                    let offsets = (locationsBySection[sectionIndex] ?? []).map(\.pageOffset)
                    group.addTask {
                        var delivered = false
                        for await event in await repository.page(descriptor, collection: collection,
                                                                 allowNetwork: true,
                                                                 priority: .prefetch) {
                            if Task.isCancelled { break }
                            switch event {
                            case .value(let items, _):
                                delivered = true
                                updatesContinuation.yield(.value(sectionIndex: sectionIndex,
                                                                 items: items, offsets: offsets))
                            case .failure:
                                delivered = true
                                updatesContinuation.yield(.failure(sectionIndex: sectionIndex))
                            }
                        }
                        if !delivered {
                            updatesContinuation.yield(.failure(sectionIndex: sectionIndex))
                        }
                    }
                }
            }
            updatesContinuation.finish()
            await consumer.value
        }

        let latest = await repository.latestTimelineSnapshot(collection: collection)
        let fingerprintChanged = latest.map {
            LibraryIndex(snapshot: $0).fingerprint != index.fingerprint
        } ?? false
        if let final = await accumulator.finalize(fingerprintChanged: fingerprintChanged) {
            continuation.yield(final)
        }
    }
}

private enum SectionUpdate: Sendable {
    case value(sectionIndex: Int, items: [PhotoItem], offsets: [Int])
    case failure(sectionIndex: Int)
}

private actor SelectionInfoAccumulator {
    struct SingleLocation: Sendable {
        let sectionIndex: Int
        let pageOffset: Int
    }

    private struct Contribution {
        var resolvedCount = 0
        var photoCount = 0
        var videoCount = 0
        var sizeTotal: Int64 = 0
        var missingSize = false

        mutating func add(_ other: Contribution) {
            resolvedCount += other.resolvedCount
            photoCount += other.photoCount
            videoCount += other.videoCount
            sizeTotal += other.sizeTotal
            missingSize = missingSize || other.missingSize
        }

        mutating func subtract(_ other: Contribution) {
            resolvedCount -= other.resolvedCount
            photoCount -= other.photoCount
            videoCount -= other.videoCount
            sizeTotal -= other.sizeTotal
        }
    }

    private let itemCount: Int
    private let newestDayID: String?
    private let oldestDayID: String?
    private let singleLocation: SingleLocation?
    private let sectionCount: Int
    private var contributions: [Int: Contribution] = [:]
    private var itemsBySection: [Int: [Int: PhotoItem]] = [:]
    private var settledSections: Set<Int> = []
    private var failedSections: Set<Int> = []
    private var sectionsWithMissingItems: Set<Int> = []
    private var fingerprintChanged = false
    private var aggregate = Contribution()
    private var lastEmitted: SelectionInfo?

    init(itemCount: Int, newestDayID: String?, oldestDayID: String?,
         singleLocation: SingleLocation?, sectionCount: Int) {
        self.itemCount = itemCount
        self.newestDayID = newestDayID
        self.oldestDayID = oldestDayID
        self.singleLocation = singleLocation
        self.sectionCount = sectionCount
    }

    func initial() -> SelectionInfo? {
        emit(isComplete: false)
    }

    func apply(_ update: SectionUpdate) -> SelectionInfo? {
        switch update {
        case .value(let sectionIndex, let items, let offsets):
            var resolved: [Int: PhotoItem] = [:]
            var missing = false
            for offset in offsets {
                guard items.indices.contains(offset) else { missing = true; continue }
                resolved[offset] = items[offset]
            }
            itemsBySection[sectionIndex] = resolved
            if missing { sectionsWithMissingItems.insert(sectionIndex) }
            else { sectionsWithMissingItems.remove(sectionIndex) }
            install(contribution(from: resolved.values), for: sectionIndex)
            settledSections.insert(sectionIndex)
        case .failure(let sectionIndex):
            failedSections.insert(sectionIndex)
            settledSections.insert(sectionIndex)
        }
        return emit(isComplete: settledSections.count == sectionCount)
    }

    func finalize(fingerprintChanged: Bool) -> SelectionInfo? {
        self.fingerprintChanged = self.fingerprintChanged || fingerprintChanged
        return emit(isComplete: true)
    }

    private func install(_ next: Contribution, for sectionIndex: Int) {
        let previous = contributions[sectionIndex] ?? Contribution()
        aggregate.subtract(previous)
        aggregate.add(next)
        contributions[sectionIndex] = next
    }

    private func contribution<S: Sequence>(from items: S) -> Contribution where S.Element == PhotoItem {
        var result = Contribution()
        for item in items {
            result.resolvedCount += 1
            if item.isVideo { result.videoCount += 1 }
            else if item.hasDisplayableStillImage { result.photoCount += 1 }
            if let size = item.filesize { result.sizeTotal += size }
            else { result.missingSize = true }
        }
        return result
    }

    private func emit(isComplete: Bool) -> SelectionInfo? {
        let hadFailure = !failedSections.isEmpty || !sectionsWithMissingItems.isEmpty || fingerprintChanged
        let cumulativeSize: Int64?
        if isComplete, !hadFailure, aggregate.resolvedCount == itemCount, !aggregate.missingSize {
            cumulativeSize = aggregate.sizeTotal
        } else {
            cumulativeSize = nil
        }
        let singleItem = singleLocation.flatMap { itemsBySection[$0.sectionIndex]?[$0.pageOffset] }
        let info = SelectionInfo(itemCount: itemCount,
                                 newestDayID: newestDayID,
                                 oldestDayID: oldestDayID,
                                 resolvedCount: aggregate.resolvedCount,
                                 photoCount: aggregate.photoCount,
                                 videoCount: aggregate.videoCount,
                                 cumulativeSize: cumulativeSize,
                                 isComplete: isComplete,
                                 hadFailure: hadFailure,
                                 singleItem: singleItem)
        guard info != lastEmitted else { return nil }
        lastEmitted = info
        return info
    }
}
