import CoreGraphics
import Foundation
import Metal

/// Inspection modules produce a transparent overlay in the source image's coordinates.
enum ViewerInspectionModule {
    case highlightPeaking(threshold: Double)
    case focusEdges(widthTolerance: Double)

    nonisolated func overlay(for image: CGImage, maximumDimension: Int = 2048) -> CGImage? {
        switch self {
        case .highlightPeaking(let threshold):
            let value = threshold.isFinite ? min(100, max(80, threshold)) : 100
            return ViewerGPUImageRenderer.shared.render(image, effect: HighlightPeakingEffect(threshold: Float(value / 100)),
                                                        maximumDimension: maximumDimension)
        case .focusEdges(let tolerance):
            let value = tolerance.isFinite ? min(2.5, max(1, tolerance)) : 1.5
            return ViewerGPUImageRenderer.shared.render(image, effect: FocusEdgeEffect(widthTolerance: Float(value)),
                                                        maximumDimension: maximumDimension)
        }
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
