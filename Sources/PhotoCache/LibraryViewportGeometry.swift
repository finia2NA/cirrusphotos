import Foundation
import SynologyAPI
import TimelineCore

/// Compact vertical map. Only the current page window contributes row/item geometry.
public struct LibraryViewportGeometry {
    public struct RowItem {
        public let photo: PhotoItem
        public let verified: Bool
    }
    public struct Row {
        public let y: Double
        public let layout: JustifiedRows.Row
        public let items: [RowItem]
        public var itemIDs: [Int64] { items.map { $0.photo.id } }
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
    public private(set) var targetRowHeight: Double
    private var measuredHeights: [Int: Double] = [:]
    private var rows: [Int: [Row]] = [:]
    /// Incomplete rows at API boundaries. Entries are kept only around retained pages,
    /// letting an evicted look-behind page keep the next page stable without library-wide growth.
    private var boundaryCarry: [Int: [RowItem]] = [:]
    private var sectionSignatures: [Int: Int] = [:]
    private var sectionToSlices: [Int: [Int]] = [:]
    private var dayToFirstSlice: [String: Int] = [:]
    private let gap = 6.0
    private let headingHeight = 38.0

    public init(index: LibraryIndex, width: Double, targetRowHeight: Double = 180) {
        self.width = max(1, width)
        self.targetRowHeight = Self.validTargetHeight(targetRowHeight)
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

    @discardableResult
    public mutating func setLayout(width newWidth: Double, targetRowHeight newTargetRowHeight: Double,
                                   pages: [Int: LibraryPage]) -> Bool {
        guard newWidth.isFinite, newWidth > 0 else { return false }
        let target = Self.validTargetHeight(newTargetRowHeight)
        guard abs(width - newWidth) > 0.5 || abs(targetRowHeight - target) > 0.5 else { return false }
        width = newWidth
        targetRowHeight = target
        measuredHeights.removeAll()
        rows.removeAll()
        boundaryCarry.removeAll()
        sectionSignatures = Dictionary(uniqueKeysWithValues: pages.map { section, page in
            (section, Self.signature(page))
        })
        measure(pages)
        recalculate()
        return true
    }

    public mutating func setWidth(_ newWidth: Double, pages: [Int: LibraryPage]) {
        setLayout(width: newWidth, targetRowHeight: targetRowHeight, pages: pages)
    }

    public mutating func reconcile(pages: [Int: LibraryPage]) {
        let signatures = Dictionary(uniqueKeysWithValues: pages.map { section, page in
            (section, Self.signature(page))
        })
        let changedPositions = signatures.compactMap { section, signature -> Int? in
            guard sectionSignatures[section] != nil, sectionSignatures[section] != signature else { return nil }
            return sectionToSlices[section]?.first
        }
        if let earliest = changedPositions.min() {
            boundaryCarry = boundaryCarry.filter { $0.key <= earliest }
        }
        sectionSignatures = signatures
        rows.removeAll(keepingCapacity: true)
        measure(pages)
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
                let visibleOffset = min(max(0, offset), max(0, row.layout.height - 1))
                return slices[position].y + row.y + visibleOffset
            }
        }
        return nil
    }

    private mutating func measure(_ pages: [Int: LibraryPage]) {
        let loaded = slices.indices.filter { pages[slices[$0].source.sectionIndex] != nil }
        var cursor = 0
        while cursor < loaded.count {
            let start = loaded[cursor]
            var end = cursor + 1
            while end < loaded.count,
                  loaded[end] == loaded[end - 1] + 1,
                  slices[loaded[end]].source.dayID == slices[start].source.dayID {
                end += 1
            }
            measureRun(Array(loaded[cursor..<end]), pages: pages)
            cursor = end
        }
        // Full PhotoItem values are retained only for boundaries touching the bounded
        // page window. Distant slices keep scalar heights, not item metadata.
        let allowedCarry = Set(loaded + loaded.map { $0 + 1 }.filter { $0 < slices.count })
        boundaryCarry = boundaryCarry.filter { allowedCarry.contains($0.key) }
    }

    private mutating func measureRun(_ positions: [Int], pages: [Int: LibraryPage]) {
        guard let first = positions.first, let last = positions.last else { return }
        var pending = boundaryCarry[first] ?? []
        for position in positions {
            let slice = slices[position]
            guard let page = pages[slice.source.sectionIndex] else { continue }
            let pageItems = page.items.dropFirst(slice.source.pageRange.lowerBound)
                .prefix(slice.source.pageRange.count)
                .map { RowItem(photo: $0, verified: page.verified) }
            let candidates = pending + pageItems
            let isDayEnd = position + 1 >= slices.count ||
                slices[position + 1].source.dayID != slice.source.dayID
            let result = JustifiedRows.layoutPrefix(
                aspectRatios: candidates.map { $0.photo.displayAspectRatio },
                availableWidth: width, targetHeight: targetRowHeight, finalize: isDayEnd
            )
            append(result.rows, from: candidates, completingAt: position)
            pending = result.pendingRange.map { candidates[$0] }
            if position + 1 < slices.count { boundaryCarry[position + 1] = pending }
        }

        // The next page is not retained yet. Paint the bounded pending row provisionally;
        // it will be replaced with a justified cross-page row when that page arrives.
        let reachesDayEnd = last + 1 >= slices.count ||
            slices[last + 1].source.dayID != slices[last].source.dayID
        if !reachesDayEnd, !pending.isEmpty {
            let provisional = JustifiedRows.layout(
                aspectRatios: pending.map { $0.photo.displayAspectRatio }, availableWidth: width,
                targetHeight: targetRowHeight
            )
            append(provisional, from: pending, completingAt: last)
        }

        for position in positions {
            var y = slices[position].heading ? headingHeight : 0
            let measuredRows = rows[position] ?? []
            var relocated: [Row] = []
            for row in measuredRows {
                relocated.append(Row(y: y, layout: row.layout, items: row.items))
                y += row.layout.height + gap
            }
            rows[position] = relocated
            measuredHeights[position] = max(y, slices[position].heading ? headingHeight : 0)
        }
    }

    private mutating func append(_ layouts: [JustifiedRows.Row], from candidates: [RowItem],
                                 completingAt position: Int) {
        for layout in layouts {
            let selected = layout.cells.map { candidates[$0.index] }
            rows[position, default: []].append(Row(y: 0, layout: layout,
                                                   items: selected))
        }
    }

    private static func signature(_ page: LibraryPage) -> Int {
        var hash = Hasher()
        hash.combine(page.verified)
        for item in page.items {
            hash.combine(item.id)
            hash.combine(item.displayAspectRatio)
        }
        return hash.finalize()
    }

    private static func validTargetHeight(_ height: Double) -> Double {
        guard height.isFinite else { return 180 }
        return min(max(height, 100), 300)
    }

    private mutating func recalculate() {
        var y = 0.0
        for position in slices.indices {
            slices[position].y = y
            let count = slices[position].count
            // Representative ratio 1.4 gives a stable initial approximation.
            let perRow = max(1, Int(ceil((width + gap) / (targetRowHeight * 1.4 + gap))))
            let estimate = Double((count + perRow - 1) / perRow) * (targetRowHeight + gap)
            slices[position].height = measuredHeights[position] ??
                max(slices[position].heading ? headingHeight : 20,
                    estimate + (slices[position].heading ? headingHeight : 0))
            y += slices[position].height
        }
        totalHeight = y
    }
}
