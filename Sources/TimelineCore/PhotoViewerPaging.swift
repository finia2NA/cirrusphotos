import CoreGraphics

public enum PhotoViewerPaging {
    public static let horizontalSensitivity: CGFloat = 1.35
    public static let deadZone: CGFloat = 10
    public static let gap: CGFloat = 24
    public static let displacementThreshold: CGFloat = 0.25
    public static let velocityThreshold: CGFloat = 900

    public enum Direction: Equatable, Sendable {
        case previous
        case next
    }

    public struct Metrics: Equatable, Sendable {
        public let translation: CGSize
        public let progress: CGFloat
    }

    public static func direction(translation: CGSize) -> Direction? {
        guard translation.width.isFinite, translation.height.isFinite else { return nil }
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard horizontal >= deadZone, horizontal > vertical else { return nil }
        return translation.width < 0 ? .next : .previous
    }

    public static func pageDistance(viewport: CGRect, neighborFrame: CGRect) -> CGFloat {
        let viewportWidth = viewport.width.isFinite ? abs(viewport.width) : 0
        let neighborWidth = neighborFrame.width.isFinite ? abs(neighborFrame.width) : 0
        return max(1, (viewportWidth + neighborWidth) / 2 + gap)
    }

    public static func exitDistance(currentFrame: CGRect, viewport: CGRect) -> CGFloat {
        let currentWidth = currentFrame.width.isFinite ? abs(currentFrame.width) : 0
        let viewportWidth = viewport.width.isFinite ? abs(viewport.width) : 0
        return max(1, (currentWidth + viewportWidth) / 2 + gap)
    }

    public static func scaledHorizontal(_ value: CGSize) -> CGSize {
        CGSize(width: value.width * horizontalSensitivity, height: value.height)
    }

    public static func metrics(translation: CGSize, direction: Direction,
                               distance: CGFloat) -> Metrics {
        let distanceValue = max(1, distance.isFinite ? abs(distance) : 0)
        let raw = translation.width.isFinite ? translation.width : 0
        let signed: CGFloat
        switch direction {
        case .next:
            signed = min(0, max(-distanceValue, raw))
        case .previous:
            signed = max(0, min(distanceValue, raw))
        }
        return Metrics(translation: CGSize(width: signed, height: 0),
                       progress: min(1, abs(signed) / distanceValue))
    }

    public static func shouldCommit(direction: Direction, translation: CGSize,
                                    velocity: CGSize, distance: CGFloat) -> Bool {
        let metrics = metrics(translation: translation, direction: direction,
                              distance: distance)
        guard metrics.progress > 0 else { return false }
        if metrics.progress >= displacementThreshold { return true }
        guard velocity.width.isFinite else { return false }
        let along = direction == .next ? -velocity.width : velocity.width
        return along >= velocityThreshold
    }
}
