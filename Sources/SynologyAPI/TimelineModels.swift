import Foundation
import TimelineCore

public struct TimelineSnapshot: Codable, Sendable {
    public let timeline: Timeline
    public let sections: [TimelineSection]
    public var sectionCount: Int { sections.count }

    public init(sections: [TimelineSection]) {
        self.sections = sections
        let days = sections.enumerated().flatMap { sectionIndex, section in
            section.list.map {
                LibraryDay(year: $0.year, month: $0.month, day: $0.day,
                           count: $0.itemCount, section: sectionIndex)
            }
        }
        timeline = Timeline(days: days)
    }

    private enum CodingKeys: String, CodingKey { case sections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sections: try container.decode([TimelineSection].self, forKey: .sections))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sections, forKey: .sections)
    }
}

public struct TimelineSection: Codable, Sendable, Equatable, Hashable {
    public let offset: Int
    public let limit: Int
    public let list: [TimelineDay]

    public init(offset: Int, limit: Int, list: [TimelineDay]) {
        self.offset = offset
        self.limit = limit
        self.list = list
    }
}

public struct TimelineDay: Codable, Sendable, Equatable, Hashable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case year, month, day
        case itemCount = "item_count"
    }

    public init(year: Int, month: Int, day: Int, itemCount: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.itemCount = itemCount
    }
}

public extension TimelineSection {
    var dateBounds: (start: Int64, end: Int64)? {
        guard let newest = list.first, let oldest = list.last else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let startDate = calendar.date(from: DateComponents(year: oldest.year, month: oldest.month, day: oldest.day)),
              let endDate = calendar.date(from: DateComponents(year: newest.year, month: newest.month, day: newest.day)) else { return nil }
        return (Int64(startDate.timeIntervalSince1970), Int64(endDate.timeIntervalSince1970) + 86_399)
    }
}
