import Foundation
import SynologyAPI

/// Calendar-date selection for explicit warming across isolated libraries.
/// The combined timeline is presentation geometry only, never stored or fetched.
public enum ThumbnailWarmingPlan {
    public static func combinedSnapshot(_ snapshots: [TimelineSnapshot]) -> TimelineSnapshot {
        var days: [CaptureDay: Int] = [:]
        for snapshot in snapshots {
            let catalog = try? CollectionDayCatalog(sections: snapshot.sections, completeness: .complete)
            for entry in catalog?.days ?? [] { days[entry.day, default: 0] += entry.count }
        }
        return TimelineSnapshot(sections: days.sorted { $0.key > $1.key }.map { day, count in
            TimelineSection(offset: 0, limit: count,
                list: [TimelineDay(year: day.year, month: day.month, day: day.day, itemCount: count)])
        })
    }

    public static func range(in snapshot: TimelineSnapshot, from firstDate: String,
                             through lastDate: String) -> ThumbnailDateRange? {
        let indices = snapshot.timeline.days.indices.filter {
            let id = snapshot.timeline.days[$0].id
            return id >= firstDate && id <= lastDate
        }
        guard let first = indices.first, let last = indices.last else { return nil }
        return ThumbnailDateRange(first, last)
    }
}

extension ThumbnailBatchSummary {
    public func adding(_ other: ThumbnailBatchSummary, estimated: Int) -> ThumbnailBatchSummary {
        var result = ThumbnailBatchSummary(estimated: estimated)
        result.processed = processed + other.processed
        result.fetched = fetched + other.fetched
        result.reused = reused + other.reused
        result.unavailable = unavailable + other.unavailable
        result.errors = errors + other.errors
        result.interrupted = interrupted || other.interrupted
        result.budgetReached = budgetReached || other.budgetReached
        result.downloadedThumbnails = downloadedThumbnails + other.downloadedThumbnails
        result.downloadedBytes = downloadedBytes + other.downloadedBytes
        result.elapsedSeconds = elapsedSeconds + other.elapsedSeconds
        return result
    }
}
