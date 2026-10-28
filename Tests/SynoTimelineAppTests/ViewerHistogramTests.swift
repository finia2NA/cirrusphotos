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
        XCTAssertEqual(Array(lowerData), [255, 0, 0, 255, 0, 0, 0, 0])
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

extension ViewerHistogramTests {
    private func sRGBImage(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false,
                                     intent: .defaultIntent))
    }

    func testWhitePeakingIncludesNearNeutralClippedColorButRejectsSaturatedColor() throws {
        let pixels: [UInt8] = [244, 243, 255, 255, 255, 0, 0, 255,
                               255, 241, 255, 255, 254, 254, 254, 255]
        let image = try sRGBImage(width: 4, height: 1, bytes: pixels)
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 100).overlay(for: image))
        let data = try XCTUnwrap(overlay.dataProvider?.data) as Data
        XCTAssertEqual(Array(data), [255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testLowerThresholdAppliesToPeakWhileStillExcludingColor() throws {
        let image = try sRGBImage(width: 3, height: 1, bytes: [230, 230, 230, 255,
                                                               229, 229, 229, 255,
                                                               255, 0, 0, 255])
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 90).overlay(for: image))
        XCTAssertEqual(Array(try XCTUnwrap(overlay.dataProvider?.data) as Data),
                       [255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testHigherPrecisionNearWhiteIsNotRoundedTo100Percent() throws {
        let components: [Float] = [1, 1, 1, 1, 0.99998, 0.99998, 0.99998, 1]
        let raw = components.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: raw as CFData))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
                                          bytesPerRow: 32, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB)),
                                          bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 100).overlay(for: image))
        XCTAssertEqual(Array(try XCTUnwrap(overlay.dataProvider?.data) as Data),
                       [255, 0, 0, 255, 0, 0, 0, 0])
    }

    func testMaskDownsamplingPreservesPartialCoverage() throws {
        let width = 514, height = 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 255 }
        for (x, y) in [(0, 0), (257, 0), (513, 1)] {
            let offset = (y * width + x) * 4
            pixels[offset] = 255; pixels[offset + 1] = 255; pixels[offset + 2] = 255
        }
        let image = try sRGBImage(width: width, height: height, bytes: pixels)
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 100).overlay(for: image, maximumDimension: 257))
        XCTAssertEqual(overlay.width, 257)
        XCTAssertEqual(overlay.height, 1)
        let bytes = Array(try XCTUnwrap(overlay.dataProvider?.data) as Data)
        XCTAssertEqual(bytes[3], 64)
        XCTAssertEqual(bytes[128 * 4 + 3], 64)
        XCTAssertEqual(bytes[256 * 4 + 3], 64)
        XCTAssertEqual(bytes[4 * 4 + 3], 0)
    }

    func testMaskPreservesVerticalOrder() throws {
        let width = 2, height = 514
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 255 }
        for y in [0, 5, 257, 513] {
            let offset = (y * width) * 4
            pixels[offset] = 255; pixels[offset + 1] = 255; pixels[offset + 2] = 255
        }
        let image = try sRGBImage(width: width, height: height, bytes: pixels)
        let overlay = try XCTUnwrap(ViewerInspectionModule.highlightPeaking(threshold: 100).overlay(for: image, maximumDimension: 257))
        let bytes = Array(try XCTUnwrap(overlay.dataProvider?.data) as Data)
        XCTAssertEqual(bytes[3], 64)
        XCTAssertEqual(bytes[2 * 4 + 3], 64)
        XCTAssertEqual(bytes[128 * 4 + 3], 64)
        XCTAssertEqual(bytes[256 * 4 + 3], 64)
        XCTAssertEqual(bytes[4 * 4 + 3], 0)
    }
}
