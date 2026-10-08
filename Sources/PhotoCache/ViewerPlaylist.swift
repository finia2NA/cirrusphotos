import Foundation
import SynologyAPI

/// A small, session-local overlay that keeps a Favorites viewer's membership stable
/// while the authoritative Favorites collection changes underneath it.
struct ViewerPlaylist: Sendable {
    struct Entry: Sendable {
        let item: PhotoItem
        let dayID: String
        let dayOffset: Int
        /// Optimistic heart value shown by the viewer.
        var isFavorite: Bool
        /// Membership the live Favorites endpoint is expected to expose. This only
        /// advances after the write succeeds; pending writes still read the server's
        /// previous filtered ordering.
        var serverMembership: Bool
    }

    struct PagePlan: Sendable {
        let liveSection: TimelineSection
        let originalLimit: Int
        let insertions: [(offset: Int, item: PhotoItem)]
        let excludedIDs: Set<Int64>
    }

    private(set) var entries: [Int64: Entry] = [:]

    var hasEntries: Bool { !entries.isEmpty }

    mutating func record(item: PhotoItem, dayID: String, dayOffset: Int, isFavorite: Bool) {
        if var existing = entries[item.id] {
            existing.isFavorite = isFavorite
            entries[item.id] = existing
        } else {
            entries[item.id] = Entry(item: item, dayID: dayID,
                                     dayOffset: dayOffset, isFavorite: isFavorite,
                                     serverMembership: item.isFavorite)
        }
    }

    mutating func commit(itemID: Int64, isFavorite: Bool) {
        guard var existing = entries[itemID] else { return }
        existing.isFavorite = isFavorite
        existing.serverMembership = isFavorite
        entries[itemID] = existing
    }

    mutating func restore(_ previous: Entry?, itemID: Int64) {
        entries[itemID] = previous
    }

    func entry(for itemID: Int64) -> Entry? { entries[itemID] }

    func plan(for section: TimelineSection) -> PagePlan {
        var dayBases: [String: Int] = [:]
        var base = 0
        for day in section.list {
            dayBases[Self.dayID(day)] = base
            base += max(0, day.itemCount)
        }

        let lower = max(0, section.offset)
        let upper = lower + max(0, section.limit)
        var displacedBefore = 0
        var displacedWithin = 0
        var insertions: [(offset: Int, item: PhotoItem)] = []
        var excluded: Set<Int64> = []

        for (itemID, entry) in entries {
            guard let dayBase = dayBases[entry.dayID] else { continue }
            let position = dayBase + entry.dayOffset
            // Favorites is a filter over the underlying chronological order. Only
            // entries absent from the server's current membership shift live offsets.
            // We still exclude/reinsert a present entry when its frozen position is
            // inside this page to preserve status and avoid duplicates.
            if !entry.serverMembership, position < lower { displacedBefore += 1 }
            guard lower..<upper ~= position else { continue }
            if !entry.serverMembership { displacedWithin += 1 }
            insertions.append((position - lower, entry.item.withFavorite(entry.isFavorite)))
            excluded.insert(itemID)
        }

        insertions.sort { lhs, rhs in
            lhs.offset == rhs.offset ? lhs.item.id < rhs.item.id : lhs.offset < rhs.offset
        }
        let live = TimelineSection(offset: max(0, lower - displacedBefore),
                                   limit: max(0, section.limit - displacedWithin),
                                   list: section.list)
        return PagePlan(liveSection: live, originalLimit: max(0, section.limit),
                        insertions: insertions, excludedIDs: excluded)
    }

    func reconstruct(_ liveItems: [PhotoItem], using plan: PagePlan) -> [PhotoItem] {
        var result = liveItems.filter { !plan.excludedIDs.contains($0.id) }
        for insertion in plan.insertions {
            result.insert(insertion.item, at: min(max(0, insertion.offset), result.count))
        }
        return Array(result.prefix(plan.originalLimit))
    }

    private static func dayID(_ day: TimelineDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }
}
