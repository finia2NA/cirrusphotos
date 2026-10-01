import Foundation

/// Geometry for a sequence of images in their existing order. The caller owns day boundaries.
public enum JustifiedRows {
    /// Prevents corrupt/extreme metadata from growing a pending boundary row without limit.
    private static let maximumCellsPerRow = 32
    public struct LayoutResult: Equatable, Sendable {
        public let rows: [Row]
        /// Items not yet wide enough to complete a row when `finalize` is false.
        public let pendingRange: Range<Int>
    }

    public struct Cell: Equatable, Sendable {
        public let index: Int
        public let x: Double
        public let width: Double
    }

    public struct Row: Equatable, Sendable {
        public let height: Double
        public let gap: Double
        public let cells: [Cell]

        public var width: Double {
            guard let last = cells.last else { return 0 }
            return last.x + last.width
        }
    }

    public static func layout(
        aspectRatios: [Double], availableWidth: Double,
        targetHeight: Double = 180, gap: Double = 6
    ) -> [Row] {
        layoutPrefix(aspectRatios: aspectRatios, availableWidth: availableWidth,
                     targetHeight: targetHeight, gap: gap, finalize: true).rows
    }

    /// Lays out every complete row and optionally finalizes the trailing partial row.
    /// Callers can prepend `pendingRange` to the next bounded chunk to preserve flow.
    public static func layoutPrefix(
        aspectRatios: [Double], availableWidth: Double,
        targetHeight: Double = 180, gap: Double = 6, finalize: Bool
    ) -> LayoutResult {
        guard availableWidth.isFinite, availableWidth > 0, !aspectRatios.isEmpty else {
            return LayoutResult(rows: [], pendingRange: 0..<0)
        }
        let target = targetHeight.isFinite && targetHeight > 0 ? targetHeight : 180
        let spacing = gap.isFinite ? min(max(0, gap), availableWidth / 4) : 0
        var rows: [Row] = []
        var start = 0
        var ratioSum = 0.0

        for index in aspectRatios.indices {
            let ratio = validRatio(aspectRatios[index])
            ratioSum += ratio
            let count = index - start + 1
            let reachesWidth = ratioSum * target + Double(count - 1) * spacing >= availableWidth
            let reachesLimit = count >= maximumCellsPerRow
            if reachesWidth || reachesLimit {
                rows.append(makeRow(aspectRatios, start: start, end: index + 1,
                                    ratioSum: ratioSum, width: availableWidth,
                                    target: target, gap: spacing,
                                    final: reachesLimit && !reachesWidth))
                start = index + 1
                ratioSum = 0
            }
        }
        if finalize, start < aspectRatios.count {
            rows.append(makeRow(aspectRatios, start: start, end: aspectRatios.count,
                                ratioSum: ratioSum, width: availableWidth,
                                target: target, gap: spacing, final: true))
            start = aspectRatios.count
        }
        return LayoutResult(rows: rows, pendingRange: start..<aspectRatios.count)
    }

    private static func validRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        // Int-backed photo dimensions cannot exceed these bounds. Keep sums finite
        // even if a caller passes a synthetic floating-point extreme.
        return min(1e20, max(1e-20, ratio))
    }

    private static func makeRow(
        _ ratios: [Double], start: Int, end: Int, ratioSum: Double,
        width: Double, target: Double, gap: Double, final: Bool
    ) -> Row {
        let gaps = Double(end - start - 1) * gap
        let fillHeight = (width - gaps) / ratioSum
        let height = max(0, final ? min(target, fillHeight) : fillHeight)
        var x = 0.0
        var cells: [Cell] = []
        cells.reserveCapacity(end - start)
        for index in start..<end {
            let cellWidth = min(max(0, width - x), validRatio(ratios[index]) * height)
            cells.append(Cell(index: index, x: x, width: cellWidth))
            x += cellWidth + gap
        }
        return Row(height: height, gap: gap, cells: cells)
    }
}
