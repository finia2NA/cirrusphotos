import CoreGraphics
import Foundation

/// Image geometry in window-content coordinates. The viewport excludes navigation chrome;
/// the resulting image frame may extend beyond it when magnified.
public struct PhotoViewportTransform: Equatable, Sendable {
    public private(set) var imageSize: CGSize
    public private(set) var viewport: CGRect
    public private(set) var zoom: CGFloat = 1
    public private(set) var pan: CGPoint = .zero
    public let maximumZoom: CGFloat

    public init(imageSize: CGSize, viewport: CGRect, maximumZoom: CGFloat = 16) {
        self.imageSize = Self.validSize(imageSize)
        self.viewport = Self.validRect(viewport)
        self.maximumZoom = maximumZoom.isFinite ? max(1, maximumZoom) : 16
    }

    public var fitSize: CGSize {
        let factor = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }

    public var imageFrame: CGRect {
        let size = CGSize(width: fitSize.width * zoom, height: fitSize.height * zoom)
        return CGRect(x: viewport.midX + pan.x - size.width / 2,
                      y: viewport.midY + pan.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    public mutating func configure(imageSize: CGSize, viewport: CGRect) {
        self.imageSize = Self.validSize(imageSize)
        self.viewport = Self.validRect(viewport)
        constrainPan()
    }

    public mutating func reset() { zoom = 1; pan = .zero }

    /// Keep the image point under the pointer stationary, subject to the pan bounds.
    public mutating func setZoom(_ value: CGFloat, anchoredAt point: CGPoint? = nil) {
        guard value.isFinite else { return }
        let target = min(maximumZoom, max(1, value))
        let anchor = point ?? CGPoint(x: viewport.midX, y: viewport.midY)
        guard anchor.x.isFinite, anchor.y.isFinite else { return }
        let ratio = target / zoom
        pan = CGPoint(x: anchor.x - viewport.midX - (anchor.x - viewport.midX - pan.x) * ratio,
                      y: anchor.y - viewport.midY - (anchor.y - viewport.midY - pan.y) * ratio)
        zoom = target
        constrainPan()
    }

    public mutating func translate(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        pan.x += delta.width
        pan.y += delta.height
        constrainPan()
    }

    private mutating func constrainPan() {
        let x = max(0, (fitSize.width * zoom - viewport.width) / 2)
        let y = max(0, (fitSize.height * zoom - viewport.height) / 2)
        pan.x = min(x, max(-x, pan.x))
        pan.y = min(y, max(-y, pan.y))
    }

    private static func validSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return size
    }

    private static func validRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.isFinite ? rect.minX : 0, y: rect.minY.isFinite ? rect.minY : 0,
               width: rect.width.isFinite ? max(1, rect.width) : 1,
               height: rect.height.isFinite ? max(1, rect.height) : 1)
    }
}
