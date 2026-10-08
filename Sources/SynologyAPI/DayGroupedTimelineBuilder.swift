import Foundation

/// One item observed during a lightweight timeline scan (album contents or the
/// map's location scan). `time` is the capture time encoded exactly like
/// `PhotoItem.time` (epoch-shaped capture-local wall clock).
public struct DayTimelineEntry: Sendable, Equatable {
    public let id: Int64
    public let time: Int64

    public init(id: Int64, time: Int64) {
        self.id = id
        self.time = time
    }
}

/// A synthesized day-grouped timeline plus the exact server-order item IDs behind
/// each generated section.
public struct DayGroupedTimeline: Sendable {
    public let snapshot: TimelineSnapshot
    /// Item IDs in server order for each section; parallel to `snapshot.sections`.
    public let itemIDsBySection: [[Int64]]

    public init(snapshot: TimelineSnapshot, itemIDsBySection: [[Int64]]) {
        self.snapshot = snapshot
        self.itemIDsBySection = itemIDsBySection
    }
}

/// Builds a day-grouped timeline snapshot from a newest-first scan.
///
/// The Synology `Browse.Timeline` endpoint silently ignores `album_id`, so album
/// day grouping is synthesized locally from `Browse.Item list` scans. The map
/// filter reuses the same grouping for an arbitrary item set.
public enum DayGroupedTimelineBuilder {
    /// Maximum items a single generated section may describe.
    public static let defaultSectionLimit = 1000

    public static func build(entries: [DayTimelineEntry],
                             sectionLimit: Int = defaultSectionLimit) -> DayGroupedTimeline {
        let sectionLimit = max(1, sectionLimit)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        struct DayBucket {
            let year: Int
            let month: Int
            let day: Int
            var ids: [Int64] = []
        }

        var days: [DayBucket] = []
        var indexByDayID: [String: Int] = [:]
        for entry in entries {
            let parts = calendar.dateComponents([.year, .month, .day],
                                                from: Date(timeIntervalSince1970: TimeInterval(entry.time)))
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let dayID = String(format: "%04d-%02d-%02d", year, month, day)
            if let index = indexByDayID[dayID] {
                days[index].ids.append(entry.id)
            } else {
                indexByDayID[dayID] = days.count
                days.append(DayBucket(year: year, month: month, day: day, ids: [entry.id]))
            }
        }

        var sections: [TimelineSection] = []
        var itemIDsBySection: [[Int64]] = []
        for day in days {
            let count = day.ids.count
            guard count > 0 else { continue }
            let timelineDay = TimelineDay(year: day.year, month: day.month, day: day.day,
                                          itemCount: count)
            var offset = 0
            while offset < count {
                let limit = min(sectionLimit, count - offset)
                sections.append(TimelineSection(offset: offset, limit: limit, list: [timelineDay]))
                itemIDsBySection.append(Array(day.ids[offset..<(offset + limit)]))
                offset += limit
            }
        }
        return DayGroupedTimeline(snapshot: TimelineSnapshot(sections: sections),
                                  itemIDsBySection: itemIDsBySection)
    }
}
