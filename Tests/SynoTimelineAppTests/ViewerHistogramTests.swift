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
            let bins = ViewerHistogram.histogram(try XCTUnwrap(context.makeImage()))
            XCTAssertEqual(bins.count, 64)
            XCTAssertEqual(bins[expectedBin], 256 * 256)
        }
    }
}

extension ViewerHistogramTests {
    func testHighlightPeakingMarksOnlyWhitePixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 1, green: 1, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking.overlay(for: XCTUnwrap(context.makeImage())))
        let data = try XCTUnwrap(overlay.dataProvider?.data) as Data
        XCTAssertEqual(Array(data), [255, 0, 0, 255, 0, 0, 0, 0])
    }
}
