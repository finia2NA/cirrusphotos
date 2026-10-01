import Foundation
import SynologyAPI
import TimelineCore

/// Compact vertical map. Only the current page window contributes row/item geometry.
public struct LibraryViewportGeometry {
    public struct Row {
        public let y: Double
        public let layout: JustifiedRows.Row
        public let itemIDs: [Int64]
    }
    public struct Slice {
        public let source: LibraryIndex.Slice
        public let heading: Bool
        public let count: Int
        public var y: Double = 0
        public var height: Double = 0
    }
    public struct Anchor {
        public let dayID: String
        public let sectionIndex: Int
        public let itemID: Int64?
        public let localOffset: Double
        public let fraction: Double
    }

    public private(set) var slices: [Slice] = []
    public private(set) var totalHeight: Double = 0
    public private(set) var width: Double
    private var measuredHeights: [Int: Double] = [:]
    private var rows: [Int: [Row]] = [:]
    private var sectionToSlices: [Int: [Int]] = [:]
    private var dayToFirstSlice: [String: Int] = [:]
    private let gap = 6.0
    private let headingHeight = 38.0

    public init(index: LibraryIndex, width: Double) {
        self.width = max(1, width)
        for day in index.dayIDs {
            for source in index.slices(forDay: day) {
                let position = slices.count
                if dayToFirstSlice[day] == nil { dayToFirstSlice[day] = position }
                sectionToSlices[source.sectionIndex, default: []].append(position)
                slices.append(Slice(source: source, heading: position == dayToFirstSlice[day],
                                    count: source.pageRange.count))
            }
        }
        recalculate()
    }

    public mutating func setWidth(_ newWidth: Double, pages: [Int: LibraryPage]) {
        guard newWidth.isFinite, newWidth > 0, abs(width - newWidth) > 0.5 else { return }
        width = newWidth
        measuredHeights.removeAll()
        rows.removeAll()
        for page in pages.values { measure(page) }
        recalculate()
    }

    public mutating func reconcile(pages: [Int: LibraryPage]) {
        let retained = Set(pages.keys)
        rows = rows.filter { retained.contains(slices[$0.key].source.sectionIndex) }
        for page in pages.values { measure(page) }
        recalculate()
    }

    public func sliceRange(y: Double, height: Double) -> Range<Int> {
        guard !slices.isEmpty else { return 0..<0 }
        let first = slice(at: y)
        let last = slice(at: y + max(0, height))
        return first..<min(slices.count, last + 1)
    }

    public func slice(at y: Double) -> Int {
        guard !slices.isEmpty else { return 0 }
        var low = 0, high = slices.count
        while low < high {
            let middle = (low + high) / 2
            if slices[middle].y + slices[middle].height <= y { low = middle + 1 }
            else { high = middle }
        }
        return min(low, slices.count - 1)
    }

    public func y(forDay day: String) -> Double? {
        dayToFirstSlice[day].map { slices[$0].y }
    }

    public func nearestDay(to day: String, orderedDays: [String]) -> String? {
        guard !orderedDays.isEmpty else { return nil }
        return orderedDays.first(where: { $0 <= day }) ?? orderedDays.last
    }

    public func rows(in slice: Int) -> [Row] { rows[slice] ?? [] }

    public func anchor(at y: Double) -> Anchor? {
        guard !slices.isEmpty else { return nil }
        let position = slice(at: y)
        let entry = slices[position]
        let row = rows[position]?.last(where: { entry.y + $0.y <= y })
        let origin = entry.y + (row?.y ?? 0)
        return Anchor(dayID: entry.source.dayID, sectionIndex: entry.source.sectionIndex,
                      itemID: row?.itemIDs.first, localOffset: y - origin,
                      fraction: min(1, max(0, (y - entry.y) / max(1, entry.height))))
    }

    public func y(for anchor: Anchor) -> Double? {
        if let itemID = anchor.itemID {
            if let exact = y(forItem: itemID, offset: anchor.localOffset) { return exact }
        }
        if let position = (sectionToSlices[anchor.sectionIndex] ?? []).first(where: {
            slices[$0].source.dayID == anchor.dayID
        }) {
            return slices[position].y + slices[position].height * anchor.fraction
        }
        return y(forDay: anchor.dayID)
    }

    public func y(forItem itemID: Int64, offset: Double) -> Double? {
        for position in rows.keys {
            if let row = rows[position]?.first(where: { $0.itemIDs.contains(itemID) }) {
                return slices[position].y + row.y + offset
            }
        }
        return nil
    }

    private mutating func measure(_ page: LibraryPage) {
        for position in sectionToSlices[page.sectionIndex] ?? [] {
            let slice = slices[position]
            let items = Array(page.items.dropFirst(slice.source.pageRange.lowerBound)
                .prefix(slice.source.pageRange.count))
            let layouts = JustifiedRows.layout(aspectRatios: items.map(\.displayAspectRatio),
                                               availableWidth: width)
            var y = slice.heading ? headingHeight : 0
            var measuredRows: [Row] = []
            for layout in layouts {
                measuredRows.append(Row(y: y, layout: layout,
                                        itemIDs: layout.cells.map { items[$0.index].id }))
                y += layout.height + gap
            }
            rows[position] = measuredRows
            measuredHeights[position] = max(y, slice.heading ? headingHeight : 20)
        }
    }

    private mutating func recalculate() {
        var y = 0.0
        for position in slices.indices {
            slices[position].y = y
            let count = slices[position].count
            // Representative ratio 1.4 gives a stable initial approximation.
            let perRow = max(1, Int(width / (180 * 1.4 + gap)))
            let estimate = Double((count + perRow - 1) / perRow) * 186
            slices[position].height = measuredHeights[position] ??
                max(slices[position].heading ? headingHeight : 20,
                    estimate + (slices[position].heading ? headingHeight : 0))
            y += slices[position].height
        }
        totalHeight = y
    }
}
