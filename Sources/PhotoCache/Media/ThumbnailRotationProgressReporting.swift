import Foundation
import SynologyAPI

/// Batch progress for a thumbnail rotation run. Within one photo, downloads map to
/// 0–½, local analysis and encoding to ½–⅔, and the upload to ⅔–1.
struct ThumbnailRotationReporter: Sendable {
    let continuation: AsyncStream<ThumbnailRotationProgress>.Continuation
    let total: Int
    var completed = 0
    var failures: [String] = []
    var activity: [String] = []

    func report(_ stage: ThumbnailRotationProgress.Stage, itemID: Int64?, progress: Double = 0, detail: String? = nil) {
        continuation.yield(.init(completedItems: completed, totalItems: total, itemID: itemID, stage: stage,
                                 failures: failures, itemProgress: progress, activity: activity, detail: detail))
    }

    mutating func record(failure: String, activity entry: String) {
        failures.append(failure)
        activity.append(entry)
    }

    /// Ends a run that failed before processing any photo.
    func finishWithoutStarting(_ error: any Error) {
        let message: String, failure: String
        if let start = error as? ThumbnailRotationStartFailure {
            (message, failure) = (start.message, start.underlying.localizedDescription)
        } else {
            (message, failure) = (error.localizedDescription, error.localizedDescription)
        }
        continuation.yield(.init(completedItems: 0, totalItems: total, itemID: nil, stage: .finished,
                                 failures: [failure], activity: [message]))
        continuation.finish()
    }

    static func rotationDescription(_ turns: Int) -> String {
        switch (turns % 4 + 4) % 4 {
        case 0: "no rotation"
        case 1: "90° right"
        case 2: "180°"
        default: "90° left"
        }
    }
}

struct ThumbnailRotationStartFailure: Error {
    let message: String
    let underlying: any Error
}

/// Estimates one photo's download half from fixed thumbnail sizes and the original's
/// metadata filesize, replaced by the HTTP expected length once known.
struct ThumbnailRotationDownloadEstimate: Sendable {
    private static let fallbackOriginalBytes: Int64 = 5_000_000
    private let thumbnailBytes: Int64
    private let originalBytes: Int64
    private let includesOriginal: Bool
    private var completedThumbnailBytes: Int64 = 0

    init(item: PhotoItem, includesOriginal: Bool) {
        thumbnailBytes = ThumbnailSize.allCases.reduce(0) { $0 + Self.estimatedBytes(for: $1) }
        originalBytes = item.filesize.flatMap { $0 > 0 ? $0 : nil } ?? Self.fallbackOriginalBytes
        self.includesOriginal = includesOriginal
    }

    mutating func completeThumbnail(_ size: ThumbnailSize) { completedThumbnailBytes += Self.estimatedBytes(for: size) }

    var thumbnailProgress: Double {
        Self.downloadHalf(completedThumbnailBytes, of: thumbnailBytes + (includesOriginal ? originalBytes : 0))
    }

    func originalProgress(_ transfer: TransferProgress) -> Double {
        let fullBytes = transfer.totalBytes ?? originalBytes
        return Self.downloadHalf(completedThumbnailBytes + min(transfer.completedBytes, fullBytes), of: thumbnailBytes + fullBytes)
    }

    static func name(for size: ThumbnailSize) -> String {
        switch size {
        case .sm: "small"
        case .m: "medium"
        case .xl: "large"
        }
    }

    private static func estimatedBytes(for size: ThumbnailSize) -> Int64 {
        switch size {
        case .sm: 60_000
        case .m: 150_000
        case .xl: 1_000_000
        }
    }

    private static func downloadHalf(_ completed: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return 0.5 * min(1, max(0, Double(completed) / Double(total)))
    }
}
