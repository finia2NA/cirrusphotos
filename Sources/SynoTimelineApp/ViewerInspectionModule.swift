import CoreGraphics
import Foundation

/// Inspection modules produce a transparent overlay in the source image's coordinates.
enum ViewerInspectionModule {
    case highlightPeaking

    nonisolated func overlay(for image: CGImage) -> CGImage? {
        let scale = min(1, 1024.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            switch self {
            case .highlightPeaking:
                let clipped = pixels[offset] == 255 && pixels[offset + 1] == 255 && pixels[offset + 2] == 255
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

    func histogram(_ image: CGImage) -> [Int] {
        guard !Task.isCancelled else { return [] }
        return ViewerHistogram.histogram(image)
    }

    func overlay(for image: CGImage, module: ViewerInspectionModule) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return module.overlay(for: image)
    }
}
