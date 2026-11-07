import CoreGraphics
import Foundation
import ImageIO

public final class FullImageBitmap: @unchecked Sendable {
    public let image: CGImage
    public var byteCount: Int { image.bytesPerRow * image.height }
    init(_ image: CGImage) { self.image = image }

    /// Applies only the remaining display-orientation delta. The decoder has already
    /// applied the served file's EXIF transform, so this must never be used for
    /// server-generated thumbnails.
    public func rotatedForDisplay(quarterTurns: Int) throws -> FullImageBitmap {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        let swapsAxes = turns % 2 == 1
        let outputWidth = swapsAxes ? image.height : image.width
        let outputHeight = swapsAxes ? image.width : image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FullImageDecodeError.unsupported
        }
        context.translateBy(x: CGFloat(outputWidth) / 2, y: CGFloat(outputHeight) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw FullImageDecodeError.unsupported }
        return FullImageBitmap(result)
    }
}

public enum FullImageDecodeError: LocalizedError {
    case unsupported
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This image could not be decoded."
        case .tooLarge: "This image exceeds the viewer's decode memory limit."
        }
    }
}

/// One running ImageIO decode and one replaceable waiter, shared by viewer windows.
/// Original pixels are preserved; oversized images fail explicitly rather than silently
/// presenting a reduced rendition as full resolution.
public actor FullImageDecoder {
    public static let shared = FullImageDecoder()
    private let maximumBytes: Int
    private var active = false
    private var waiting: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    public init(maximumBytes: Int = 384 * 1_000_000) {
        self.maximumBytes = max(4, maximumBytes)
    }

    public nonisolated static func fileOrientation(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    }

    public func decode(_ data: Data) async throws -> FullImageBitmap {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let budget = maximumBytes
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width.isFinite, height.isFinite, width > 0, height > 0 else {
                throw FullImageDecodeError.unsupported
            }
            let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
            let bytesPerPixel = depth > 8 ? 8.0 : 4.0
            guard width * height * bytesPerPixel <= Double(budget) else {
                throw FullImageDecodeError.tooLarge
            }
            // ImageIO applies the served file's orientation exactly once, at full pixel size.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(width, height)),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ] as CFDictionary) else { throw FullImageDecodeError.unsupported }
            try Task.checkCancellation()
            guard image.bytesPerRow <= budget / max(1, image.height) else {
                throw FullImageDecodeError.tooLarge
            }
            return FullImageBitmap(image)
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !active { active = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiting?.continuation.resume(throwing: CancellationError())
                waiting = (id, continuation)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        guard waiting?.id == id else { return }
        waiting?.continuation.resume(throwing: CancellationError())
        waiting = nil
    }

    private func release() {
        if let waiting {
            self.waiting = nil
            waiting.continuation.resume()
        } else { active = false }
    }
}
