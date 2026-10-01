import CryptoKit
import Foundation
import SynologyAPI

/// A complete, immutable map of the current server timeline. Ranges use server item order.
public struct LibraryIndex: Sendable {
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
    private let slicesByDay: [String: [Slice]]
    private let slicesBySection: [[Slice]]

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
        slicesByDay = byDay
        slicesBySection = bySection
        dayIDs = snapshot.timeline.days.map(\.id)
    }

    public func slices(forDay id: String) -> [Slice] { slicesByDay[id] ?? [] }
    public func slices(inSection index: Int) -> [Slice] {
        guard slicesBySection.indices.contains(index) else { return [] }
        return slicesBySection[index]
    }
    public func sectionIndices(forDay id: String) -> [Int] {
        slices(forDay: id).map(\.sectionIndex)
    }
}
