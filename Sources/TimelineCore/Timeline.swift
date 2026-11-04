import Foundation

public struct DayJumpRequest: Equatable, Sendable {
    public let id: UUID
    public let dayID: String

    public init(dayID: String) {
        id = UUID()
        self.dayID = dayID
    }
}

public struct LibraryDay: Identifiable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let count: Int
    public let section: Int
    public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }
    /// Chronological key (`yyyymmdd`) for hot paths; avoids formatting `id` strings.
    var sortKey: Int { year * 10_000 + month * 100 + day }
    public var monthLabel: String { String(format: "%04d / %02d", year, month) }

    public init(year: Int, month: Int, day: Int, count: Int, section: Int) {
        self.year = year; self.month = month; self.day = day
        self.count = count; self.section = section
    }
}

/// Each populated day owns an equal interval, independent of its item count.
public struct Timeline: Sendable {
    public let days: [LibraryDay]
    public let yearStarts: [Int]
    public let monthStarts: [Int]

    public init(days: [LibraryDay]) {
        // A split day can appear in several API sections. Retain its first section
        // and the largest aggregate count reported by any contributing section.
        var unique: [Int: LibraryDay] = [:]
        for day in days {
            let key = day.sortKey
            guard let current = unique[key] else {
                unique[key] = day
                continue
            }
            unique[key] = LibraryDay(year: day.year, month: day.month, day: day.day,
                                     count: max(current.count, day.count),
                                     section: min(current.section, day.section))
        }
        let sorted = unique.values.sorted { $0.sortKey > $1.sortKey }
        self.days = sorted
        yearStarts = sorted.indices.filter { $0 == 0 || sorted[$0].year != sorted[$0 - 1].year }
        monthStarts = sorted.indices.filter {
            $0 == 0 || sorted[$0].year != sorted[$0 - 1].year || sorted[$0].month != sorted[$0 - 1].month
        }
    }

    public func index(at fraction: Double) -> Int? {
        guard !days.isEmpty, fraction.isFinite else { return nil }
        return min(days.count - 1, Int(max(0, min(1, fraction)) * Double(days.count)))
    }

    public func fraction(at index: Int) -> Double {
        guard !days.isEmpty else { return 0 }
        return (Double(index) + 0.5) / Double(days.count)
    }

    /// Keep a selected calendar day across a changed index. Dates are newest first.
    public func index(keeping dayID: String?) -> Int? {
        guard !days.isEmpty else { return nil }
        guard let dayID else { return 0 }
        return days.firstIndex(where: { $0.id <= dayID }) ?? days.count - 1
    }
}
