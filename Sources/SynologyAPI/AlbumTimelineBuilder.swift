import Foundation

/// One item observed during a lightweight album scan. `time` is the capture time
/// encoded exactly like `PhotoItem.time` (epoch-shaped capture-local wall clock).
public struct AlbumScanEntry: Sendable, Equatable {
    public let id: Int64
    public let time: Int64

    public init(id: Int64, time: Int64) {
        self.id = id
        self.time = time
    }
}

/// Builds a day-grouped timeline snapshot from a newest-first album scan.
///
/// The Synology `Browse.Timeline` endpoint silently ignores `album_id`, so album
/// day grouping is synthesized locally from `Browse.Item list` scans.
public enum AlbumTimelineBuilder {
    /// Maximum items a single generated section may describe.
    public static let daySectionLimit = 1000

    public static func snapshot(entries: [AlbumScanEntry]) -> TimelineSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var days: [TimelineDay] = []
        var indexByDayID: [String: Int] = [:]
        for entry in entries {
            let parts = calendar.dateComponents([.year, .month, .day],
                                                from: Date(timeIntervalSince1970: TimeInterval(entry.time)))
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let dayID = String(format: "%04d-%02d-%02d", year, month, day)
            if let index = indexByDayID[dayID] {
                let existing = days[index]
                days[index] = TimelineDay(year: existing.year, month: existing.month,
                                          day: existing.day, itemCount: existing.itemCount + 1)
            } else {
                indexByDayID[dayID] = days.count
                days.append(TimelineDay(year: year, month: month, day: day, itemCount: 1))
            }
        }

        var sections: [TimelineSection] = []
        for day in days {
            let count = max(0, day.itemCount)
            guard count > 0 else { continue }
            if count <= daySectionLimit {
                sections.append(TimelineSection(offset: 0, limit: count, list: [day]))
                continue
            }
            var offset = 0
            while offset < count {
                let limit = min(daySectionLimit, count - offset)
                sections.append(TimelineSection(offset: offset, limit: limit, list: [day]))
                offset += limit
            }
        }
        return TimelineSnapshot(sections: sections)
    }
}
