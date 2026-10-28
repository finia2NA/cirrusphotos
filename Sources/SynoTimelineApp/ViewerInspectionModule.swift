import CoreGraphics
import Foundation

/// Inspection modules produce a transparent overlay in the source image's coordinates.
enum ViewerInspectionModule {
    case highlightPeaking(threshold: Double)

    nonisolated func overlay(for image: CGImage) -> CGImage? {
        let scale = min(1, 4096.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let minimum: UInt8
        switch self {
        case .highlightPeaking(let threshold):
            let value = threshold.isFinite ? min(100, max(80, threshold)) : 100
            minimum = UInt8((value * 255 / 100).rounded(.up))
        }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if offset.isMultiple(of: width * 4), Task.isCancelled { return nil }
            switch self {
            case .highlightPeaking:
                let clipped = pixels[offset] >= minimum && pixels[offset + 1] >= minimum && pixels[offset + 2] >= minimum
                pixels[offset] = clipped ? 255 : 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = clipped ? 255 : 0
            }
        }
        return context.makeImage()
    }
}

/// Serializes inspection work and drops requests cancelled while waiting.
actor ViewerInspectionEngine {
    static let shared = ViewerInspectionEngine()

    func histogram(_ image: CGImage) -> HistogramBins? {
        guard !Task.isCancelled else { return nil }
        return ViewerHistogram.histogram(image)
    }

    func overlay(for image: CGImage, module: ViewerInspectionModule) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return module.overlay(for: image)
    }
}
