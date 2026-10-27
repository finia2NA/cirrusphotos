import CryptoKit
import Foundation
import SynologyAPI

/// A complete, immutable map of the current server timeline. Ranges use server item order.
public struct LibraryIndex: Sendable {
    public struct Location: Sendable, Equatable {
        public let sectionIndex: Int
        public let pageOffset: Int
        public let ordinal: Int
        public let dayID: String
        public let dayOffset: Int
    }

    public struct VisualPosition: Sendable, Equatable {
        public let row: Int
        public let column: Int
    }
    public struct Slice: Sendable, Equatable {
        public let dayID: String
        public let sectionIndex: Int
        /// Local offsets in the section response.
        public let pageRange: Range<Int>
        /// Offsets within the complete UTC day.
        public let dayRange: Range<Int>
    }

    public let fingerprint: String
    public let sections: [TimelineSection]
    public let dayIDs: [String]
    public let totalCount: Int
    private let slicesByDay: [String: [Slice]]
    private let slicesBySection: [[Slice]]
    private let dayStarts: [Int]
    private let dayCounts: [Int]
    private let dayLookup: [String: Int]
    private let visualRowStartsByColumns: [Int: [Int]]

    public init(snapshot: TimelineSnapshot) {
        sections = snapshot.sections
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(snapshot.sections)) ?? Data()
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var byDay: [String: [Slice]] = [:]
        var bySection: [[Slice]] = []
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            var slices: [Slice] = []
            let pageStart = max(0, section.offset)
            let pageEnd = pageStart.addingReportingOverflow(max(0, section.limit))
            let safeEnd = pageEnd.overflow ? Int.max : pageEnd.partialValue
            var dayStart = 0
            for day in section.list {
                let count = max(0, day.itemCount)
                let end = dayStart.addingReportingOverflow(count)
                let dayEnd = end.overflow ? Int.max : end.partialValue
                let lower = max(dayStart, pageStart)
                let upper = min(dayEnd, safeEnd)
                if lower < upper {
                    let id = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
                    let slice = Slice(dayID: id, sectionIndex: sectionIndex,
                                      pageRange: (lower - pageStart)..<(upper - pageStart),
                                      dayRange: (lower - dayStart)..<(upper - dayStart))
                    slices.append(slice)
                    byDay[id, default: []].append(slice)
                }
                dayStart = dayEnd
            }
            bySection.append(slices)
        }
        for day in byDay.keys {
            byDay[day]?.sort { $0.dayRange.lowerBound < $1.dayRange.lowerBound }
        }
        slicesByDay = byDay
        slicesBySection = bySection.map { $0.sorted { $0.pageRange.lowerBound < $1.pageRange.lowerBound } }
        dayIDs = snapshot.timeline.days.map(\.id)
        dayCounts = snapshot.timeline.days.map { max(0, $0.count) }
        var starts: [Int] = []
        starts.reserveCapacity(dayCounts.count)
        var running = 0
        for count in dayCounts { starts.append(running); running += count }
        dayStarts = starts
        totalCount = running
        dayLookup = Dictionary(uniqueKeysWithValues: dayIDs.enumerated().map { ($0.element, $0.offset) })
        var rowMaps: [Int: [Int]] = [:]
        for columns in 3...10 {
            var rowStarts: [Int] = [], rows = 0
            for count in dayCounts {
                rowStarts.append(rows)
                rows += (count + columns - 1) / columns
            }
            rowStarts.append(rows)
            rowMaps[columns] = rowStarts
        }
        visualRowStartsByColumns = rowMaps
    }

    public func slices(forDay id: String) -> [Slice] { slicesByDay[id] ?? [] }
    public func slices(inSection index: Int) -> [Slice] {
        guard slicesBySection.indices.contains(index) else { return [] }
        return slicesBySection[index]
    }
    public func sectionIndices(forDay id: String) -> [Int] {
        slices(forDay: id).map(\.sectionIndex)
    }

    public func dayCount(_ dayID: String) -> Int {
        guard let i = dayLookup[dayID] else { return 0 }
        return dayCounts[i]
    }

    public func dayStart(_ dayID: String) -> Int? {
        guard let i = dayLookup[dayID] else { return nil }
        return dayStarts[i]
    }

    public func ordinal(sectionIndex: Int, pageOffset: Int) -> Int? {
        guard slicesBySection.indices.contains(sectionIndex) else { return nil }
        let slices = slicesBySection[sectionIndex]
        guard let slice = Self.slice(containing: pageOffset, in: slices, range: \.pageRange),
              let start = dayStart(slice.dayID) else { return nil }
        return start + slice.dayRange.lowerBound + pageOffset - slice.pageRange.lowerBound
    }

    public func ordinalForLoadedItemID(_ itemID: Int64, pages: [Int: LibraryPage]) -> Int? {
        for (section, page) in pages {
            if let offset = page.slots.firstIndex(where: { $0.itemID == itemID }) {
                return ordinal(sectionIndex: section, pageOffset: offset)
            }
        }
        return nil
    }

    public func location(forOrdinal ordinal: Int) -> Location? {
        guard ordinal >= 0, ordinal < totalCount, let dayIndex = dayIndex(for: ordinal) else { return nil }
        let offset = ordinal - dayStarts[dayIndex]
        let dayID = dayIDs[dayIndex]
        guard let slice = Self.slice(containing: offset, in: slicesByDay[dayID] ?? [], range: \.dayRange) else { return nil }
        return Location(sectionIndex: slice.sectionIndex,
                        pageOffset: slice.pageRange.lowerBound + offset - slice.dayRange.lowerBound,
                        ordinal: ordinal, dayID: dayID, dayOffset: offset)
    }

    public func visualPosition(for ordinal: Int, columns: Int) -> VisualPosition? {
        guard let day = dayIndex(for: ordinal) else { return nil }
        let columnCount = max(1, columns)
        let row = rowStarts(for: columnCount)[day]
        let offset = ordinal - dayStarts[day]
        return VisualPosition(row: row + offset / columnCount, column: offset % columnCount)
    }

    public func destination(from ordinal: Int, direction: LibrarySelectionDirection,
                            columns: Int) -> Int? {
        guard ordinal >= 0, ordinal < totalCount, let position = visualPosition(for: ordinal, columns: columns) else { return nil }
        switch direction {
        case .left: return ordinal > 0 ? ordinal - 1 : nil
        case .right: return ordinal + 1 < totalCount ? ordinal + 1 : nil
        case .up, .down:
            let targetRow = position.row + (direction == .up ? -1 : 1)
            guard targetRow >= 0 else { return nil }
            return self.ordinal(atVisualRow: targetRow, column: position.column, columns: columns)
        }
    }

    public func ordinal(atVisualRow target: Int, column: Int, columns: Int) -> Int? {
        guard target >= 0 else { return nil }
        let columnCount = max(1, columns)
        let starts = rowStarts(for: columnCount)
        guard let day = Self.prefixIndex(containing: target, starts: starts), day < dayIDs.count else { return nil }
        let localRow = target - starts[day]
        let first = localRow * columnCount
        let count = min(columnCount, dayCounts[day] - first)
        guard count > 0 else { return nil }
        return dayStarts[day] + first + min(max(0, column), count - 1)
    }

    private func dayIndex(for ordinal: Int) -> Int? {
        guard ordinal >= 0, ordinal < totalCount else { return nil }
        var low = 0, high = dayStarts.count
        while low < high {
            let middle = (low + high) / 2
            if dayStarts[middle] <= ordinal { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    private func rowStarts(for columns: Int) -> [Int] {
        if let cached = visualRowStartsByColumns[columns] { return cached }
        var starts: [Int] = [], rows = 0
        for count in dayCounts {
            starts.append(rows); rows += (count + columns - 1) / columns
        }
        starts.append(rows)
        return starts
    }

    private static func prefixIndex(containing value: Int, starts: [Int]) -> Int? {
        guard starts.count > 1, value >= starts[0], value < starts[starts.count - 1] else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high) / 2
            if starts[middle + 1] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func slice(containing value: Int, in slices: [Slice],
                              range: KeyPath<Slice, Range<Int>>) -> Slice? {
        var low = 0, high = slices.count
        while low < high {
            let middle = (low + high) / 2
            if slices[middle][keyPath: range].lowerBound <= value { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let candidate = slices[low - 1]
        return candidate[keyPath: range].contains(value) ? candidate : nil
    }
}
