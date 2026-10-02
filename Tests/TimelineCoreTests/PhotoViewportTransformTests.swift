import CoreGraphics
import Foundation
import XCTest
@testable import TimelineCore

final class PhotoViewportTransformTests: XCTestCase {
    func testFitExcludesSidebarAndToolbarForBothAspectRatios() {
        let visible = CGRect(x: 210, y: 52, width: 900, height: 700)
        for size in [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000)] {
            let transform = PhotoViewportTransform(imageSize: size, viewport: visible)
            XCTAssertTrue(visible.contains(transform.imageFrame))
            XCTAssertEqual(transform.imageFrame.midX, visible.midX, accuracy: 0.001)
            XCTAssertEqual(transform.imageFrame.midY, visible.midY, accuracy: 0.001)
            XCTAssertEqual(transform.imageFrame.width / transform.imageFrame.height,
                           size.width / size.height, accuracy: 0.001)
        }
    }

    func testPointerAnchoredZoomAndPanBounds() {
        var transform = PhotoViewportTransform(imageSize: CGSize(width: 1000, height: 1000),
                                               viewport: CGRect(x: 200, y: 50, width: 600, height: 600))
        let anchor = CGPoint(x: 400, y: 250)
        let before = transform.imageFrame
        let unitX = (anchor.x - before.minX) / before.width
        let unitY = (anchor.y - before.minY) / before.height
        transform.setZoom(2, anchoredAt: anchor)
        XCTAssertEqual((anchor.x - transform.imageFrame.minX) / transform.imageFrame.width, unitX, accuracy: 0.001)
        XCTAssertEqual((anchor.y - transform.imageFrame.minY) / transform.imageFrame.height, unitY, accuracy: 0.001)
        XCTAssertLessThan(transform.imageFrame.minX, transform.viewport.minX)
        XCTAssertLessThan(transform.imageFrame.minY, transform.viewport.minY)
        transform.translate(by: CGSize(width: 100_000, height: -100_000))
        XCTAssertEqual(transform.imageFrame.minX, transform.viewport.minX, accuracy: 0.001)
        XCTAssertEqual(transform.imageFrame.maxY, transform.viewport.maxY, accuracy: 0.001)
        transform.setZoom(1)
        XCTAssertEqual(transform.pan, .zero)
    }

    func testResizeAndImageUpgradePreserveZoomAndFiniteGeometry() {
        var transform = PhotoViewportTransform(imageSize: CGSize(width: 400, height: 300),
                                               viewport: CGRect(x: 200, y: 50, width: 600, height: 700))
        transform.setZoom(3)
        let frame = transform.imageFrame
        transform.configure(imageSize: CGSize(width: 4000, height: 3000), viewport: transform.viewport)
        XCTAssertEqual(transform.imageFrame, frame)
        transform.configure(imageSize: transform.imageSize, viewport: CGRect(x: 0, y: 50, width: 800, height: 700))
        XCTAssertEqual(transform.zoom, 3)
        transform.setZoom(.infinity)
        transform.translate(by: CGSize(width: CGFloat.nan, height: 1))
        XCTAssertTrue(transform.imageFrame.width.isFinite)
        transform.reset()
        XCTAssertEqual(transform.zoom, 1)
        XCTAssertEqual(transform.pan, .zero)
    }
}
