import Foundation

/// Pure geometry for the library's fixed-column, square-slot presentation.
public enum FixedPhotoGrid {
    public struct Cell: Equatable, Sendable {
        public let x: Double
        public let width: Double
    }

    public struct Row: Equatable, Sendable {
        public let height: Double
        public let gap: Double
        public let cells: [Cell]

        public var width: Double { cells.last.map { $0.x + $0.width } ?? 0 }
    }

    public static func row(itemCount: Int, availableWidth: Double, columns: Int) -> Row {
        let count = min(Self.columns(columns), max(0, itemCount))
        let side = slotWidth(availableWidth: availableWidth, columns: columns)
        return Row(height: side, gap: gap, cells: (0..<count).map {
            Cell(x: Double($0) * (side + gap), width: side)
        })
    }

    public static let columnRange = 3...10
    public static let gap = 8.0

    public static func columns(_ value: Int) -> Int {
        min(columnRange.upperBound, max(columnRange.lowerBound, value))
    }

    public static func slotWidth(availableWidth: Double, columns: Int, gap: Double = gap) -> Double {
        let count = Self.columns(columns)
        return max(1, (max(1, availableWidth) - Double(count - 1) * gap) / Double(count))
    }

    public static func slotFrame(column: Int, rowY: Double, availableWidth: Double,
                                 columns: Int, gap: Double = gap) -> CGRect {
        let side = slotWidth(availableWidth: availableWidth, columns: columns, gap: gap)
        return CGRect(x: Double(column) * (side + gap), y: rowY, width: side, height: side)
    }

    public static func fittedFrame(in slot: CGRect, aspectRatio: Double) -> CGRect {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let width = min(slot.width, slot.height * ratio)
        let height = min(slot.height, slot.width / ratio)
        return CGRect(x: slot.midX - width / 2, y: slot.midY - height / 2,
                      width: width, height: height)
    }

    /// The visible image/interaction rectangle for one item. Square cropping fills the
    /// full slot; otherwise the aspect-fitted frame is centered inside it.
    public static func visibleFrame(in slot: CGRect, aspectRatio: Double,
                                    cropsToSquare: Bool) -> CGRect {
        cropsToSquare ? slot : fittedFrame(in: slot, aspectRatio: aspectRatio)
    }
}
