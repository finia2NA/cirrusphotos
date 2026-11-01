import Foundation

/// A calendar day in Synology's capture-local, epoch-shaped wall clock.
public struct CaptureDay: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: day)),
              Self.calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { throw CollectionCatalogError.invalidDay }
        self.year = year; self.month = month; self.day = day
    }
    public init(time: Int64) throws {
        // Bound before converting to Date; Foundation accepts dates outside this schema.
        guard time >= -62_135_596_800, time <= 253_402_300_799 else { throw CollectionCatalogError.invalidDay }
        let components = Self.calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(time)))
        try self.init(year: components.year!, month: components.month!, day: components.day!)
    }
    public var startTime: Int64 {
        Int64(Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!.timeIntervalSince1970)
    }
    public var endTime: Int64 { startTime + 86_399 }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(year: values.decode(Int.self, forKey: .year),
                      month: values.decode(Int.self, forKey: .month), day: values.decode(Int.self, forKey: .day))
    }
}

public enum CollectionCatalogError: Error, Sendable {
    case invalidDay, invalidCount, inconsistentCount, invalidCoverage, exceedsLimit, invalidAddress
}
public enum CatalogCompleteness: String, Codable, Sendable { case partial, complete }
public struct CollectionDayCount: Hashable, Codable, Sendable {
    public let day: CaptureDay
    public let count: Int
    public init(day: CaptureDay, count: Int) throws {
        guard count >= 0 else { throw CollectionCatalogError.invalidCount }
        self.day = day; self.count = count
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(day: values.decode(CaptureDay.self, forKey: .day), count: values.decode(Int.self, forKey: .count))
    }
}

public struct CollectionDayCatalog: Codable, Sendable {
    /// Matches the existing bounded metadata enumeration ceiling.
    public static let maximumItems = 2_048_000
    public let days: [CollectionDayCount]
    public let completeness: CatalogCompleteness
    public var itemCount: Int { days.reduce(0) { $0 + $1.count } }
    public init(days: [CollectionDayCount], completeness: CatalogCompleteness) throws {
        var unique: [CaptureDay: Int] = [:]
        var total = 0
        for entry in days {
            if let prior = unique[entry.day] {
                guard prior == entry.count else { throw CollectionCatalogError.inconsistentCount }
            } else {
                guard entry.count <= Self.maximumItems - total else { throw CollectionCatalogError.exceedsLimit }
                total += entry.count
                unique[entry.day] = entry.count
            }
        }
        self.days = try unique.filter { $0.value > 0 }.map { try CollectionDayCount(day: $0.key, count: $0.value) }.sorted { $0.day > $1.day }
        self.completeness = completeness
    }
    /// NAS packets may pack days and repeat whole-day counts across split packets.
    /// Validate disjoint range-relative coverage, not merely total item equality.
    public init(sections: [TimelineSection], completeness: CatalogCompleteness) throws {
        var entries: [CollectionDayCount] = []
        var coverage: [CaptureDay: [Range<Int>]] = [:]
        for section in sections {
            guard section.offset >= 0, section.limit > 0, !section.list.isEmpty else { throw CollectionCatalogError.invalidCoverage }
            var prefix = 0
            var prior: CaptureDay?
            var covered = 0
            let (end, overflow) = section.offset.addingReportingOverflow(section.limit)
            guard !overflow else { throw CollectionCatalogError.exceedsLimit }
            for raw in section.list {
                let day = try CaptureDay(year: raw.year, month: raw.month, day: raw.day)
                guard prior == nil || day < prior! else { throw CollectionCatalogError.invalidCoverage }
                prior = day
                let entry = try CollectionDayCount(day: day, count: raw.itemCount)
                entries.append(entry)
                guard raw.itemCount <= Self.maximumItems - prefix else { throw CollectionCatalogError.exceedsLimit }
                let next = prefix + raw.itemCount
                let lower = max(prefix, section.offset), upper = min(next, end)
                if lower < upper {
                    coverage[day, default: []].append((lower - prefix)..<(upper - prefix))
                    covered += upper - lower
                }
                prefix = next
            }
            guard covered == section.limit else { throw CollectionCatalogError.invalidCoverage }
        }
        try self.init(days: entries, completeness: completeness)
        for entry in days {
            var end = 0
            for range in coverage[entry.day, default: []].sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard range.lowerBound >= end else { throw CollectionCatalogError.invalidCoverage }
                if completeness == .complete, range.lowerBound != end { throw CollectionCatalogError.invalidCoverage }
                end = range.upperBound
            }
            if completeness == .complete, end != entry.count { throw CollectionCatalogError.invalidCoverage }
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(days: values.decode([CollectionDayCount].self, forKey: .days),
                      completeness: values.decode(CatalogCompleteness.self, forKey: .completeness))
    }
}

public enum CollectionOrder: String, Codable, Sendable { case timeline, takenTimeDescending, derived }
public struct DayPageAddress: Hashable, Codable, Sendable {
    public let collection: PhotoCollectionDescriptor
    public let day: CaptureDay
    public let offset: Int
    public let capacity: Int
    public let order: CollectionOrder
    public init(collection: PhotoCollectionDescriptor, day: CaptureDay, offset: Int,
                capacity: Int = CollectionDayPager.capacity, order: CollectionOrder? = nil) throws {
        guard capacity > 0, capacity <= 1000, offset >= 0, offset % capacity == 0,
              offset < CollectionDayCatalog.maximumItems else { throw CollectionCatalogError.invalidAddress }
        self.collection = collection; self.day = day; self.offset = offset; self.capacity = capacity
        self.order = order ?? (collection.isSessionDerived ? .derived : (!collection.usesItemCatalog ? .timeline : .takenTimeDescending))
    }
    public init(section: TimelineSection, collection: PhotoCollectionDescriptor) throws {
        guard section.list.count == 1, let raw = section.list.first,
              section.limit > 0, section.limit == min(CollectionDayPager.capacity, raw.itemCount - section.offset) else {
            throw CollectionCatalogError.invalidAddress
        }
        try self.init(collection: collection, day: CaptureDay(year: raw.year, month: raw.month, day: raw.day), offset: section.offset)
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(collection: values.decode(PhotoCollectionDescriptor.self, forKey: .collection),
                      day: values.decode(CaptureDay.self, forKey: .day), offset: values.decode(Int.self, forKey: .offset),
                      capacity: values.decode(Int.self, forKey: .capacity), order: values.decode(CollectionOrder.self, forKey: .order))
    }
}
public enum CollectionDayPager {
    public static let capacity = 250
    public static func snapshot(catalog: CollectionDayCatalog, capacity: Int = capacity) throws -> TimelineSnapshot {
        guard capacity > 0, capacity <= 1000 else { throw CollectionCatalogError.invalidAddress }
        return TimelineSnapshot(sections: catalog.days.flatMap { entry in
            stride(from: 0, to: entry.count, by: capacity).map { offset in
                TimelineSection(offset: offset, limit: min(capacity, entry.count - offset),
                                list: [TimelineDay(year: entry.day.year, month: entry.day.month, day: entry.day.day, itemCount: entry.count)])
            }
        })
    }
}
