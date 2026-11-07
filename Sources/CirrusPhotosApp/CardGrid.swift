import SwiftUI

/// Shared layout for grids of square-cover cards (albums, people, subjects, tags, folders).
/// The column count is the thumbnail-size preference, so the toolbar slider scales these like the timeline.
enum CardGrid {
    static let padding: CGFloat = 24
    static let spacing: CGFloat = 20

    static func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .leading), count: max(1, count))
    }

    static func cardWidth(width: CGFloat, count: Int) -> CGFloat {
        let count = CGFloat(max(1, count))
        return max(0, (width - 2 * padding - (count - 1) * spacing) / count)
    }
}
