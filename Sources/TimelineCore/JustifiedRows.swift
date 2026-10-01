import Foundation

/// Geometry for a sequence of images in their existing order. The caller owns day boundaries.
public enum JustifiedRows {
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
        guard availableWidth.isFinite, availableWidth > 0, !aspectRatios.isEmpty else { return [] }
        let target = targetHeight.isFinite && targetHeight > 0 ? targetHeight : 180
        let spacing = gap.isFinite ? min(max(0, gap), availableWidth / 4) : 0
        var rows: [Row] = []
        var start = 0
        var ratioSum = 0.0

        for index in aspectRatios.indices {
            let ratio = validRatio(aspectRatios[index])
            ratioSum += ratio
            let count = index - start + 1
            if ratioSum * target + Double(count - 1) * spacing >= availableWidth {
                rows.append(makeRow(aspectRatios, start: start, end: index + 1,
                                    ratioSum: ratioSum, width: availableWidth,
                                    target: target, gap: spacing, final: false))
                start = index + 1
                ratioSum = 0
            }
        }
        if start < aspectRatios.count {
            rows.append(makeRow(aspectRatios, start: start, end: aspectRatios.count,
                                ratioSum: ratioSum, width: availableWidth,
                                target: target, gap: spacing, final: true))
        }
        return rows
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
