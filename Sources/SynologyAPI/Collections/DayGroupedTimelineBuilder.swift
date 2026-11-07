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
    public static let defaultSectionLimit = CollectionDayPager.capacity

    public static func build(entries: [DayTimelineEntry],
                             sectionLimit: Int = defaultSectionLimit) -> DayGroupedTimeline {
        // Inputs come from bounded, validated server enumerations or repository-owned
        // derived membership. The same pager defines every collection's geometry.
        var ids: [CaptureDay: [Int64]] = [:]
        for entry in entries {
            guard let day = try? CaptureDay(time: entry.time) else { continue }
            ids[day, default: []].append(entry.id)
        }
        guard let counts = try? ids.map({ try CollectionDayCount(day: $0.key, count: $0.value.count) }),
              let catalog = try? CollectionDayCatalog(days: counts, completeness: .complete),
              let snapshot = try? CollectionDayPager.snapshot(catalog: catalog, capacity: sectionLimit) else {
            return DayGroupedTimeline(snapshot: TimelineSnapshot(sections: []), itemIDsBySection: [])
        }
        let memberships = snapshot.sections.map { section -> [Int64] in
            let raw = section.list[0]
            let day = try! CaptureDay(year: raw.year, month: raw.month, day: raw.day)
            return Array(ids[day]![section.offset..<(section.offset + section.limit)])
        }
        return DayGroupedTimeline(snapshot: snapshot, itemIDsBySection: memberships)
    }
}
