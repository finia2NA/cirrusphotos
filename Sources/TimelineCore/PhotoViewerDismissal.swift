import CoreGraphics

/// Pure geometry and thresholds for the fit-zoom two-finger downward swipe-to-dismiss
/// gesture. Coordinates follow the viewer's translation convention (the same values the
/// constrained pan uses), so a downward finger swipe accumulates a negative height and a
/// downward release velocity. The type is intentionally free of AppKit or animation
/// details so the response curve and the commit decision can be tested directly.
public enum PhotoViewerDismissal {
    /// Accumulated travel before a two-finger gesture picks a direction.
    public static let deadZone: CGFloat = 10
    /// Downward displacement, as a fraction of the viewport height, that commits dismissal.
    public static let displacementThreshold: CGFloat = 0.18
    /// Downward release speed, in points per second, that commits dismissal.
    public static let velocityThreshold: CGFloat = 900
    /// Smallest scale the photo reaches at the full-viewport downward limit.
    public static let minimumScale: CGFloat = 0.65

    /// The direction a two-finger gesture has locked into.
    public enum ScrollIntent: Equatable, Sendable {
        /// Not enough travel yet to commit to a direction.
        case undecided
        /// Predominantly horizontal or upward: scroll, never dismiss.
        case scroll
        /// Predominantly downward: interactive dismissal.
        case dismiss
    }

    public struct Metrics: Equatable, Sendable {
        /// Translation actually applied to the photo, clamped to the viewport and to
        /// downward travel only.
        public let translation: CGSize
        public let scale: CGFloat
        public let backdropOpacity: CGFloat
    }

    /// Locks a two-finger gesture to dismissal, scrolling, or neither. A gesture only
    /// becomes dismissal when its downward travel clears the dead zone and dominates any
    /// horizontal travel, so horizontal, upward, and incidental scrolling never dismiss.
    public static func scrollIntent(translation: CGSize) -> ScrollIntent {
        guard translation.width.isFinite, translation.height.isFinite else { return .scroll }
        let downward = -translation.height
        let horizontal = abs(translation.width)
        if downward >= deadZone, downward > horizontal { return .dismiss }
        if horizontal >= deadZone, horizontal > downward { return .scroll }
        if translation.height >= deadZone { return .scroll }
        return .undecided
    }

    /// Whether a translation is a predominantly downward drag past the dead zone.
    public static func beginsInteractiveDismissal(translation: CGSize) -> Bool {
        scrollIntent(translation: translation) == .dismiss
    }

    /// Downward displacement as a fraction of the viewport height, clamped to `0...1`.
    /// Non-finite input yields `0`.
    public static func downwardProgress(translation: CGSize, viewport: CGRect) -> CGFloat {
        let height = viewport.height.isFinite ? abs(viewport.height) : 0
        guard height > 0, translation.height.isFinite else { return 0 }
        return min(1, max(0, -translation.height / height))
    }

    /// Bounded translation, scale, and backdrop opacity for the current downward drag.
    public static func metrics(translation: CGSize, viewport: CGRect) -> Metrics {
        let width = viewport.width.isFinite ? abs(viewport.width) : 0
        let height = viewport.height.isFinite ? abs(viewport.height) : 0
        let x = translation.width.isFinite ? translation.width : 0
        let rawY = translation.height.isFinite ? translation.height : 0
        // Follow downward travel only: upward overshoot rests at the fit frame.
        let applied = CGSize(width: min(max(-width, x), width),
                             height: min(0, max(-height, rawY)))
        let progress = downwardProgress(translation: CGSize(width: x, height: rawY), viewport: viewport)
        let scale = min(1, max(minimumScale, 1 - (1 - minimumScale) * progress))
        let opacity = min(1, max(0, 1 - progress * 1.15))
        return Metrics(translation: applied, scale: scale, backdropOpacity: opacity)
    }

    /// Whether releasing the gesture should dismiss the viewer rather than spring back.
    /// Dismissal requires a predominantly downward gesture that either travelled far
    /// enough or was released with enough downward speed.
    public static func shouldDismiss(translation: CGSize, velocity: CGSize, viewport: CGRect) -> Bool {
        guard beginsInteractiveDismissal(translation: translation) else { return false }
        if downwardProgress(translation: translation, viewport: viewport) >= displacementThreshold {
            return true
        }
        let downwardVelocity = velocity.height.isFinite ? -velocity.height : 0
        return downwardVelocity >= velocityThreshold
    }
}
