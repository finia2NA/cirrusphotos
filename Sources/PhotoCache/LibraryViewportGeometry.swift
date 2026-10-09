import Foundation
import SynologyAPI
import TimelineCore

/// Exact fixed-grid geometry derived from descriptor counts. Retained pages only add item
/// metadata; they never change row placement or document height.
public struct LibraryViewportGeometry {
    public struct RowItem {
        public let photo: PhotoItem
        public let verified: Bool
        public let sectionIndex: Int
        public let pageOffset: Int
        public let ordinal: Int

        public init(photo: PhotoItem, verified: Bool, sectionIndex: Int, pageOffset: Int, ordinal: Int) {
            self.photo = photo; self.verified = verified; self.sectionIndex = sectionIndex
            self.pageOffset = pageOffset; self.ordinal = ordinal
        }
    }
    public struct Row {
        public let y: Double
        public let layout: FixedPhotoGrid.Row
        public let slots: [RowItem?]
        public var items: [RowItem] { slots.compactMap { $0 } }
        public var itemIDs: [Int64] { items.map { $0.photo.id } }
        public let firstOrdinal: Int
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

        public init(dayID: String, sectionIndex: Int, itemID: Int64?, localOffset: Double, fraction: Double) {
            self.dayID = dayID; self.sectionIndex = sectionIndex; self.itemID = itemID
            self.localOffset = localOffset; self.fraction = fraction
        }
    }

    public private(set) var slices: [Slice] = []
    public private(set) var totalHeight = 0.0
    public private(set) var width: Double
    public private(set) var itemsPerRow: Int
    /// When true, each loaded item's materialized interaction/image frame is the full
    /// square slot rather than an aspect-fitted rectangle inside it.
    public private(set) var cropsThumbnailsToSquare: Bool

    private let index: LibraryIndex
    private var pages: [Int: LibraryPage] = [:]
    private var materializedRows: [Int: [Row]] = [:]
    private var sectionToSlices: [Int: [Int]] = [:]
    private var dayToFirstSlice: [String: Int] = [:]
    private var dayOrigins: [String: Double] = [:]
    private struct DayLayout {
        let id: String
        let origin: Double
        let height: Double
        let startOrdinal: Int
        let count: Int
    }
    private var dayLayouts: [DayLayout] = []
    private var itemFrames: [Int64: CGRect] = [:]
    private var itemSlotFrames: [Int64: CGRect] = [:]
    private let headingHeight = 38.0
    private let gap = FixedPhotoGrid.gap

    public init(index: LibraryIndex, width: Double, itemsPerRow: Int = 6,
                cropsThumbnailsToSquare: Bool = false) {
        self.index = index
        self.width = max(1, width)
        self.itemsPerRow = FixedPhotoGrid.columns(itemsPerRow)
        self.cropsThumbnailsToSquare = cropsThumbnailsToSquare
        buildSlices()
        recalculate()
    }

    public var slotSide: Double {
        FixedPhotoGrid.slotWidth(availableWidth: width, columns: itemsPerRow, gap: gap)
    }

    @discardableResult
    public mutating func setLayout(width newWidth: Double, itemsPerRow newCount: Int,
                                   cropsThumbnailsToSquare newCrops: Bool? = nil,
                                   pages: [Int: LibraryPage]) -> Bool {
        guard newWidth.isFinite, newWidth > 0 else { return false }
        let count = FixedPhotoGrid.columns(newCount)
        let crops = newCrops ?? cropsThumbnailsToSquare
        guard abs(width - newWidth) > 0.5 || itemsPerRow != count || crops != cropsThumbnailsToSquare
        else { return false }
        width = newWidth; itemsPerRow = count; cropsThumbnailsToSquare = crops; self.pages = pages
        recalculate()
        return true
    }

    public mutating func setWidth(_ newWidth: Double, pages: [Int: LibraryPage]) {
        _ = setLayout(width: newWidth, itemsPerRow: itemsPerRow, pages: pages)
    }

    public mutating func reconcile(pages: [Int: LibraryPage]) {
        self.pages = pages
        materializeRows()
    }

    public func rows(in slice: Int) -> [Row] { materializedRows[slice] ?? [] }

    public func sliceRange(y: Double, height: Double) -> Range<Int> {
        guard !slices.isEmpty else { return 0..<0 }
        let first = slice(at: y), last = slice(at: y + max(0, height))
        return first..<min(slices.count, last + 1)
    }

    public func slice(at y: Double) -> Int {
        guard !slices.isEmpty else { return 0 }
        var low = 0, high = slices.count
        while low < high {
            let middle = (low + high) / 2
            if slices[middle].y + slices[middle].height <= y { low = middle + 1 } else { high = middle }
        }
        return min(low, slices.count - 1)
    }

    public func y(forDay day: String) -> Double? { dayOrigins[day] }
    public func nearestDay(to day: String, orderedDays: [String]) -> String? {
        guard !orderedDays.isEmpty else { return nil }
        return orderedDays.first(where: { $0 <= day }) ?? orderedDays.last
    }

    public func anchor(at y: Double) -> Anchor? {
        guard !slices.isEmpty else { return nil }
        let position = slice(at: y), entry = slices[position]
        let row = materializedRows[position]?.last(where: { entry.y + $0.y <= y })
        let origin = entry.y + (row?.y ?? 0)
        return Anchor(dayID: entry.source.dayID, sectionIndex: entry.source.sectionIndex,
                      itemID: row?.items.first?.photo.id, localOffset: y - origin,
                      fraction: min(1, max(0, (y - entry.y) / max(1, entry.height))))
    }

    public func y(for anchor: Anchor) -> Double? {
        if let id = anchor.itemID, let exact = y(forItem: id, offset: anchor.localOffset) { return exact }
        if let position = (sectionToSlices[anchor.sectionIndex] ?? []).first(where: {
            slices[$0].source.dayID == anchor.dayID
        }) { return slices[position].y + slices[position].height * anchor.fraction }
        return y(forDay: anchor.dayID)
    }

    public func y(forItem itemID: Int64, offset: Double) -> Double? {
        guard let frame = itemSlotFrames[itemID] else { return nil }
        return frame.minY + min(max(0, offset), max(0, frame.height - 1))
    }
    public func frame(forItem itemID: Int64) -> CGRect? { itemFrames[itemID] }
    public func frames(for selection: IndexSet) -> [CGRect] {
        materializedRows.values.flatMap { rows in
            rows.flatMap { row in
                row.slots.compactMap { item in
                    guard let item, selection.contains(item.ordinal) else { return nil }
                    return itemFrames[item.photo.id]
                }
            }
        }
    }
    public func loadedFramesByOrdinal() -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        for rows in materializedRows.values {
            for row in rows {
                for item in row.slots.compactMap({ $0 }) {
                    if let frame = itemFrames[item.photo.id] { result[item.ordinal] = frame }
                }
            }
        }
        return result
    }

    public func slotFrame(for ordinal: Int) -> CGRect? {
        guard let location = index.location(forOrdinal: ordinal), let dayY = dayOrigins[location.dayID] else { return nil }
        return FixedPhotoGrid.slotFrame(column: location.dayOffset % itemsPerRow,
            rowY: dayY + headingHeight + Double(location.dayOffset / itemsPerRow) * (slotSide + gap),
            availableWidth: width, columns: itemsPerRow, gap: gap)
    }

    public func firstOrdinal(inVerticalRange range: ClosedRange<Double>) -> Int? {
        guard !dayLayouts.isEmpty else { return nil }
        var day = firstDay(overlapping: range.lowerBound)
        while day < dayLayouts.count, dayLayouts[day].origin <= range.upperBound {
            let layout = dayLayouts[day]
            if let rows = visibleRows(in: layout, lower: range.lowerBound, upper: range.upperBound) {
                return layout.startOrdinal + rows.lowerBound * itemsPerRow
            }
            day += 1
        }
        return nil
    }

    public func ordinal(at point: CGPoint, fittedImagesOnly: Bool = true) -> Int? {
        for sliceRows in materializedRows.values {
            for row in sliceRows {
                for item in row.slots.compactMap({ $0 }) {
                    let frame = fittedImagesOnly ? itemFrames[item.photo.id] : slotFrame(for: item.ordinal)
                    if frame?.contains(point) == true { return item.ordinal }
                }
            }
        }
        return nil
    }

    public func ordinals(intersecting rect: CGRect, fittedImagesOnly: Bool = true) -> IndexSet {
        var result = IndexSet()
        for sliceRows in materializedRows.values {
            for row in sliceRows {
                for item in row.slots.compactMap({ $0 }) {
                    let frame = fittedImagesOnly ? itemFrames[item.photo.id] : slotFrame(for: item.ordinal)
                    if frame?.intersects(rect) == true { result.insert(item.ordinal) }
                }
            }
        }
        return result
    }

    public func sectionIndices(y: Double, height: Double) -> [Int] {
        let lower = y, upper = y + max(0, height)
        var result: [Int] = []
        guard !dayLayouts.isEmpty else { return result }
        var day = firstDay(overlapping: lower)
        while day < dayLayouts.count, dayLayouts[day].origin <= upper {
            let layout = dayLayouts[day]
            if let rows = visibleRows(in: layout, lower: lower, upper: upper) {
                for row in rows {
                    for ordinal in (layout.startOrdinal + row * itemsPerRow)..<min(
                        layout.startOrdinal + layout.count,
                        layout.startOrdinal + (row + 1) * itemsPerRow) {
                    if let section = index.location(forOrdinal: ordinal)?.sectionIndex,
                       !result.contains(section) { result.append(section) }
                    }
                }
            }
            day += 1
        }
        return result
    }

    private mutating func buildSlices() {
        for day in index.dayIDs {
            for source in index.slices(forDay: day) {
                let position = slices.count
                if dayToFirstSlice[day] == nil { dayToFirstSlice[day] = position }
                sectionToSlices[source.sectionIndex, default: []].append(position)
                slices.append(Slice(source: source, heading: position == dayToFirstSlice[day], count: source.pageRange.count))
            }
        }
    }

    private mutating func recalculate() {
        materializedRows.removeAll(); itemFrames.removeAll(); itemSlotFrames.removeAll()
        dayOrigins.removeAll(); dayLayouts.removeAll(keepingCapacity: true)
        var y = 0.0
        for dayID in index.dayIDs {
            dayOrigins[dayID] = y
            let count = index.dayCount(dayID)
            let rowCount = (count + itemsPerRow - 1) / itemsPerRow
            let dayHeight = headingHeight + Double(rowCount) * (slotSide + gap)
            if let start = index.dayStart(dayID) {
                dayLayouts.append(DayLayout(id: dayID, origin: y, height: dayHeight,
                                            startOrdinal: start, count: count))
            }
            for source in index.slices(forDay: dayID) {
                guard let position = slicePosition(source: source) else { continue }
                slices[position].y = y
                let firstRow = (source.dayRange.lowerBound + itemsPerRow - 1) / itemsPerRow
                let lastRow = source.dayRange.isEmpty ? firstRow - 1 : (source.dayRange.upperBound - 1) / itemsPerRow
                let rowStarts = max(0, lastRow - firstRow + 1)
                slices[position].height = (slices[position].heading ? headingHeight : 0) +
                    Double(rowStarts) * (slotSide + gap)
                y += slices[position].height
            }
        }
        totalHeight = y
        materializeRows()
    }

    private func firstDay(overlapping y: Double) -> Int {
        var low = 0, high = dayLayouts.count
        while low < high {
            let middle = (low + high) / 2
            if dayLayouts[middle].origin + dayLayouts[middle].height < y { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    private func visibleRows(in day: DayLayout, lower: Double, upper: Double) -> Range<Int>? {
        let rowCount = (day.count + itemsPerRow - 1) / itemsPerRow
        guard rowCount > 0 else { return nil }
        let stride = slotSide + gap
        let first = max(0, Int(ceil((lower - day.origin - headingHeight - slotSide) / stride)))
        let last = min(rowCount - 1, Int(floor((upper - day.origin - headingHeight) / stride)))
        return first <= last ? first..<(last + 1) : nil
    }

    private mutating func materializeRows() {
        materializedRows.removeAll(keepingCapacity: true)
        itemFrames.removeAll(keepingCapacity: true); itemSlotFrames.removeAll(keepingCapacity: true)
        var loaded: [Int: RowItem] = [:], starts = Set<Int>()
        for (section, page) in pages {
            for (offset, photo) in page.items.enumerated() {
                guard let ordinal = index.ordinal(sectionIndex: section, pageOffset: offset),
                      let location = index.location(forOrdinal: ordinal), let dayStart = index.dayStart(location.dayID) else { continue }
                loaded[ordinal] = RowItem(photo: photo, verified: page.verified, sectionIndex: section,
                                          pageOffset: offset, ordinal: ordinal)
                starts.insert(dayStart + (location.dayOffset / itemsPerRow) * itemsPerRow)
            }
        }
        for start in starts.sorted() {
            guard let location = index.location(forOrdinal: start), let dayY = dayOrigins[location.dayID] else { continue }
            let count = min(itemsPerRow, index.dayCount(location.dayID) - location.dayOffset), side = slotSide
            let layout = FixedPhotoGrid.row(itemCount: count, availableWidth: width,
                                           columns: itemsPerRow)
            let absoluteY = dayY + headingHeight + Double(location.dayOffset / itemsPerRow) * (side + gap)
            let slots = (0..<count).map { loaded[start + $0] }
            guard let owner = slicePosition(containing: location) else { continue }
            materializedRows[owner, default: []].append(Row(y: absoluteY - slices[owner].y,
                                                            layout: layout, slots: slots, firstOrdinal: start))
            for (position, item) in slots.enumerated() {
                guard let item else { continue }
                let slot = FixedPhotoGrid.slotFrame(column: position, rowY: absoluteY,
                    availableWidth: width, columns: itemsPerRow, gap: gap)
                itemSlotFrames[item.photo.id] = slot
                itemFrames[item.photo.id] = FixedPhotoGrid.visibleFrame(
                    in: slot, aspectRatio: item.photo.displayAspectRatio,
                    cropsToSquare: cropsThumbnailsToSquare)
            }
        }
    }

    private func slicePosition(source: LibraryIndex.Slice) -> Int? {
        (sectionToSlices[source.sectionIndex] ?? []).first { slices[$0].source == source }
    }
    private func slicePosition(containing location: LibraryIndex.Location) -> Int? {
        (sectionToSlices[location.sectionIndex] ?? []).first {
            slices[$0].source.dayID == location.dayID && slices[$0].source.pageRange.contains(location.pageOffset)
        }
    }
}
