import CoreImage
import XCTest
@testable import SynoTimelineApp

final class FocusEdgeEffectTests: XCTestCase {
    /// Seeded random rectangles: sharp on the left half, Gaussian-blurred on the right half.
    private func splitFocusImage(width: Int, height: Int, blurSigma: Double, blurredEverywhere: Bool = false) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let base = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: space, bitmapInfo: info))
        base.setFillColor(gray: 0.5, alpha: 1)
        base.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SplitMix64(seed: 37)
        for _ in 0..<(width * height / 4000) {
            let size = CGFloat(Int.random(in: 6...120, using: &generator))
            base.setFillColor(gray: CGFloat.random(in: 0.05...0.95, using: &generator), alpha: 1)
            base.fill(CGRect(x: CGFloat.random(in: 0..<CGFloat(width), using: &generator),
                             y: CGFloat.random(in: 0..<CGFloat(height), using: &generator),
                             width: size, height: size * CGFloat.random(in: 0.3...1.5, using: &generator)))
        }
        let sharp = try XCTUnwrap(base.makeImage())
        let blurred = CIImage(cgImage: sharp).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurSigma])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let blurredImage = try XCTUnwrap(CIContext().createCGImage(blurred, from: blurred.extent))
        let result = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: info))
        result.draw(sharp, in: CGRect(x: 0, y: 0, width: width, height: height))
        if blurredEverywhere { result.clip(to: CGRect(x: 0, y: 0, width: width, height: height)) } else {
        result.clip(to: CGRect(x: width / 2, y: 0, width: width - width / 2, height: height)) }
        result.draw(blurredImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(result.makeImage())
    }

    /// Mean overlay alpha in the left and right halves.
    private func halfCoverage(_ overlay: CGImage) throws -> (left: Double, right: Double) {
        let width = overlay.width, height = overlay.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sums = [0.0, 0.0]
        for y in 0..<height {
            for x in 0..<width { sums[x < width / 2 ? 0 : 1] += Double(pixels[(y * width + x) * 4 + 3]) / 255 }
        }
        let half = Double(width / 2 * height)
        return (sums[0] / half, sums[1] / Double(width - width / 2) / Double(height))
    }

    func testSharpHalfIsMarkedAndBlurredHalfIsNot() throws {
        let image = try splitFocusImage(width: 6000, height: 4000, blurSigma: 4)
        let started = Date()
        let overlay = try XCTUnwrap(ViewerInspectionModule.focusEdges(widthTolerance: 1.5).overlay(for: image))
        print("focus edges 24 MP: \(Date().timeIntervalSince(started)) s, overlay \(overlay.width)x\(overlay.height)")
        // 24 MP is capped to 20 MP (5477×3651), then pooled by blocks of 3 into at most 2048 per side.
        XCTAssertEqual(overlay.width, 1826)
        XCTAssertEqual(overlay.height, 1217)
        let coverage = try halfCoverage(overlay)
        print("coverage sharp \(coverage.left) blurred \(coverage.right)")
        XCTAssertGreaterThan(coverage.left, 0.03)
        XCTAssertLessThan(coverage.right, coverage.left / 20)
    }

    func testSmallImageIsAnalysedAtNativeResolution() throws {
        let image = try splitFocusImage(width: 1200, height: 800, blurSigma: 3)
        let overlay = try XCTUnwrap(ViewerInspectionModule.focusEdges(widthTolerance: 1.5).overlay(for: image))
        XCTAssertEqual(overlay.width, 1200)
        XCTAssertEqual(overlay.height, 800)
        let coverage = try halfCoverage(overlay)
        XCTAssertGreaterThan(coverage.left, 0.02)
        XCTAssertLessThan(coverage.right, coverage.left / 20)
    }

    /// The width limit is relative to the image, so a uniformly soft photo still marks its best edges.
    func testUniformlySoftImageStillMarksItsSharpestEdges() throws {
        let image = try splitFocusImage(width: 1200, height: 800, blurSigma: 3, blurredEverywhere: true)
        let overlay = try XCTUnwrap(ViewerInspectionModule.focusEdges(widthTolerance: 1.5).overlay(for: image))
        let coverage = try halfCoverage(overlay)
        XCTAssertGreaterThan(coverage.left, 0.005)
        XCTAssertGreaterThan(coverage.right, 0.005)
    }

    func testFlatAndNoisyAreasAreNotMarked() throws {
        let width = 1000, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var generator = SplitMix64(seed: 5)
        for index in 0..<(width * height) where index % width >= width / 2 {
            // Gaussian-like luma noise, sigma ≈ 4/255 per channel-equal pixel.
            let value = (0..<4).reduce(0) { total, _ in total + Int.random(in: 0...5, using: &generator) } + 118
            for channel in 0..<3 { pixels[index * 4 + channel] = UInt8(value) }
        }
        for index in 0..<(width * height) where index % width < width / 2 {
            for channel in 0..<3 { pixels[index * 4 + channel] = 128 }
        }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let overlay = try XCTUnwrap(ViewerInspectionModule.focusEdges(widthTolerance: 1.5).overlay(for: image))
        let coverage = try halfCoverage(overlay)
        XCTAssertEqual(coverage.left, 0, accuracy: 0.001)
        XCTAssertLessThan(coverage.right, 0.01)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
