import Foundation
import SynologyAPI

public struct ThumbnailDateRange: Sendable, Equatable {
    public let lowerIndex: Int
    public let upperIndex: Int

    public init(_ firstIndex: Int, _ secondIndex: Int) {
        lowerIndex = min(firstIndex, secondIndex)
        upperIndex = max(firstIndex, secondIndex)
    }

    /// Converts a chronological slider (oldest at zero, newest at the upper bound)
    /// to the timeline's newest-first indices.
    public init(chronologicalLower: Int, chronologicalUpper: Int, dayCount: Int) {
        let last = max(0, dayCount - 1)
        self.init(last - chronologicalUpper, last - chronologicalLower)
    }

    public func clamped(to snapshot: TimelineSnapshot) -> ThumbnailDateRange? {
        guard !snapshot.timeline.days.isEmpty else { return nil }
        let last = snapshot.timeline.days.count - 1
        return ThumbnailDateRange(min(max(0, lowerIndex), last),
                                  min(max(0, upperIndex), last))
    }

    public func dayIDs(in snapshot: TimelineSnapshot) -> [String] {
        guard let range = clamped(to: snapshot) else { return [] }
        return snapshot.timeline.days[range.lowerIndex...range.upperIndex].map(\.id)
    }

    /// Timeline counts include photos and videos; rendition readiness is known only after pages load.
    public func estimatedThumbnailCount(in snapshot: TimelineSnapshot) -> Int {
        guard let range = clamped(to: snapshot) else { return 0 }
        return snapshot.timeline.days[range.lowerIndex...range.upperIndex]
            .reduce(0) { partial, day in
                let result = partial.addingReportingOverflow(max(0, day.count))
                return result.overflow ? Int.max : result.partialValue
            }
    }
}

public struct ThumbnailBatchSummary: Sendable, Equatable {
    public let estimated: Int
    public var processed = 0
    public var fetched = 0
    public var reused = 0
    public var unavailable = 0
    public var errors = 0
    public var interrupted = false
    public var downloadedThumbnails = 0
    public var downloadedBytes: Int64 = 0
    public var downloadElapsedSeconds: TimeInterval = 0

    public init(estimated: Int) { self.estimated = estimated }

    public var averageDownloadedThumbnailBytes: Int64? {
        guard downloadedThumbnails > 0 else { return nil }
        return downloadedBytes / Int64(downloadedThumbnails)
    }

    /// Assumes every unprocessed item will require a download at the observed average payload size.
    public var estimatedDownloadBytes: Int64? {
        guard downloadedThumbnails > 0 else { return nil }
        let remaining = max(0, estimated - processed)
        let average = Double(downloadedBytes) / Double(downloadedThumbnails)
        return downloadedBytes + Int64((Double(remaining) * average).rounded())
    }

    public var bytesPerSecond: Double? {
        guard downloadedBytes > 0, downloadElapsedSeconds > 0 else { return nil }
        return Double(downloadedBytes) / downloadElapsedSeconds
    }

    public var estimatedRemainingSeconds: TimeInterval? {
        guard let estimatedDownloadBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(max(0, estimatedDownloadBytes - downloadedBytes)) / bytesPerSecond
    }
}

public struct ThumbnailRangeDownloader: Sendable {
    private let repository: CachedPhotosRepository
    private let workerCount: Int
    private let now: @Sendable () -> TimeInterval

    public init(repository: CachedPhotosRepository, workerCount: Int = 2,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.repository = repository
        self.workerCount = min(4, max(1, workerCount))
        self.now = now
    }

    /// Processes one metadata page at a time and at most `workerCount` thumbnails at once.
    /// No image bytes or whole-library item arrays are retained by this operation.
    public func download(snapshot: TimelineSnapshot, range: ThumbnailDateRange,
                         size: ThumbnailSize, collection: PhotoCollectionDescriptor,
                         progress: @escaping @Sendable (ThumbnailBatchSummary) async -> Void) async -> ThumbnailBatchSummary {
        guard let selected = range.clamped(to: snapshot) else {
            let empty = ThumbnailBatchSummary(estimated: 0)
            await progress(empty)
            return empty
        }
        var summary = ThumbnailBatchSummary(estimated: selected.estimatedThumbnailCount(in: snapshot))
        guard let metadataToken = try? await repository.captureMetadataWorkToken(
            resource: .transient(collection), jobID: UUID(), collection: collection
        ) else {
            summary.interrupted = true
            await progress(summary)
            return summary
        }
        let index = LibraryIndex(snapshot: snapshot)
        let selectedDays = Set(selected.dayIDs(in: snapshot))
        let sectionIndices = Set(selectedDays.flatMap { index.sectionIndices(forDay: $0) }).sorted()
        await progress(summary)

        for sectionIndex in sectionIndices {
            if Task.isCancelled { break }
            guard await repository.metadataTokenIsCurrent(metadataToken) else {
                summary.interrupted = true
                break
            }
            let descriptor = snapshot.sections[sectionIndex]
            let selectedOffsets = selectedPageOffsets(index: index, sectionIndex: sectionIndex, selectedDays: selectedDays)
            var currentItems: PhotoPageSnapshot?
            var pageFailed = false
            pageRead: for await event in await repository.page(descriptor, collection: collection,
                                                      allowNetwork: true, priority: .prefetch) {
                if Task.isCancelled { break }
                switch event {
                case .value(let items, let verified):
                    currentItems = items
                    if selectedOffsets.allSatisfy({ items.slot(at: $0)?.verified == true }) { break pageRead }
                case .failure:
                    pageFailed = true
                }
            }
            if Task.isCancelled { break }
            guard await repository.metadataTokenIsCurrent(metadataToken) else {
                summary.interrupted = true
                break
            }

            guard let items = currentItems, !pageFailed else {
                summary.errors += selectedOffsets.count
                summary.processed += selectedOffsets.count
                await progress(summary)
                continue
            }

            var candidates: [ThumbnailInfo] = []
            candidates.reserveCapacity(min(selectedOffsets.count, descriptor.limit))
            for offset in selectedOffsets {
                guard let slot = items.slot(at: offset), slot.verified, let item = slot.item else {
                    summary.errors += 1
                    summary.processed += 1
                    continue
                }
                guard let thumbnail = item.additional?.thumbnail,
                      thumbnail.isReady(size) else {
                    summary.unavailable += 1
                    summary.processed += 1
                    continue
                }
                candidates.append(thumbnail)
            }
            await progress(summary)

            for start in stride(from: 0, to: candidates.count, by: workerCount) {
                if Task.isCancelled { break }
                let end = min(start + workerCount, candidates.count)
                let transferStartedAt = now()
                let outcomes = await withTaskGroup(of: ThumbnailCacheMeasurement?.self,
                                                   returning: [ThumbnailCacheMeasurement?].self) { group in
                    for descriptor in candidates[start..<end] {
                        group.addTask {
                            if Task.isCancelled { return nil }
                            return try? await repository.cacheThumbnailMeasurement(
                                descriptor, size: size, collection: collection, priority: .prefetch,
                                validateCached: false)
                        }
                    }
                    var values: [ThumbnailCacheMeasurement?] = []
                    values.reserveCapacity(end - start)
                    for await value in group { values.append(value) }
                    return values
                }
                if Task.isCancelled { break }
                guard await repository.metadataTokenIsCurrent(metadataToken) else {
                    summary.interrupted = true
                    break
                }
                var batchDownloadedBytes: Int64 = 0
                for measurement in outcomes {
                    summary.processed += 1
                    if let downloadedBytes = measurement?.downloadedBytes, downloadedBytes > 0 {
                        summary.downloadedThumbnails += 1
                        summary.downloadedBytes += Int64(downloadedBytes)
                        batchDownloadedBytes += Int64(downloadedBytes)
                    }
                    switch measurement?.outcome {
                    case .fetched?: summary.fetched += 1
                    case .reused?: summary.reused += 1
                    case .cacheWriteFailed?, nil: summary.errors += 1
                    }
                }
                if batchDownloadedBytes > 0 {
                    summary.downloadElapsedSeconds += max(0, now() - transferStartedAt)
                }
                await progress(summary)
            }
        }
        return summary
    }

    private func selectedPageOffsets(index: LibraryIndex, sectionIndex: Int,
                                     selectedDays: Set<String>) -> [Int] {
        var offsets: [Int] = []
        for slice in index.slices(inSection: sectionIndex) where selectedDays.contains(slice.dayID) {
            offsets.append(contentsOf: slice.pageRange)
        }
        return Array(Set(offsets)).sorted()
    }
}
