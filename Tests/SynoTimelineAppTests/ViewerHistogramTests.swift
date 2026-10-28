import AppKit
import XCTest
@testable import SynoTimelineApp

final class ViewerHistogramTests: XCTestCase {
    func testUniformBlackAndWhiteImagesLandAtOppositeEnds() throws {
        for (component, expectedBin) in [(CGFloat(0), 0), (CGFloat(1), 63)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                                 bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: component, green: component, blue: component, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let histogram = try XCTUnwrap(ViewerHistogram.histogram(try XCTUnwrap(context.makeImage())))
            let bins = histogram.luminance
            XCTAssertEqual(histogram.red[expectedBin], 256 * 256)
            XCTAssertEqual(histogram.green[expectedBin], 256 * 256)
            XCTAssertEqual(histogram.blue[expectedBin], 256 * 256)
            XCTAssertEqual(bins.count, 64)
            XCTAssertEqual(bins[expectedBin], 256 * 256)
        }
    }
}

extension ViewerHistogramTests {
    func testHistogramSnapUsesProjectedMomentumFromClampedReleasePosition() {
        let available = CGSize(width: 800, height: 600)
        let origin = HistogramSnap.origin(for: .bottomTrailing, available: available)
        let drag = CGSize(width: -300, height: -200)
        XCTAssertEqual(HistogramSnap.target(origin: origin, drag: drag, translation: drag,
                                            predicted: drag, available: available), .bottomTrailing)
        XCTAssertEqual(HistogramSnap.target(origin: origin, drag: drag, translation: drag,
                                            predicted: CGSize(width: -300, height: -400), available: available), .topTrailing)
        XCTAssertEqual(HistogramSnap.target(origin: origin, drag: CGSize(width: -800, height: -600),
                                            translation: CGSize(width: -1100, height: -900),
                                            predicted: CGSize(width: -1100, height: -900), available: available), .topLeading)
    }

    func testHighlightPeakingMarksOnlyWhitePixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 1, green: 1, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 100).overlay(for: image))
        let data = try XCTUnwrap(overlay.dataProvider?.data) as Data
        XCTAssertEqual(Array(data), [255, 0, 0, 255, 0, 0, 0, 0])
        let lowerOverlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 90).overlay(for: image))
        let lowerData = try XCTUnwrap(lowerOverlay.dataProvider?.data) as Data
        XCTAssertEqual(Array(lowerData), [255, 0, 0, 255, 255, 0, 0, 255])
    }
}

extension ViewerHistogramTests {
    func testRGBHistogramSeparatesChannels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let bins = try XCTUnwrap(ViewerHistogram.histogram(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(bins.red[63], 256 * 256)
        XCTAssertEqual(bins.green[0], 256 * 256)
        XCTAssertEqual(bins.blue[0], 256 * 256)
    }

    func testHighlightOverlayPreservesMoreThan1024Pixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 100).overlay(for: XCTUnwrap(context.makeImage())))
        XCTAssertEqual(overlay.width, 2048)
    }
}
