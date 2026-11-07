import AppKit
import CryptoKit
import ImageIO
import os
import SwiftUI
import SynologyAPI

/// Retains recent failed requests when virtualized rows are recycled. Bounded
/// storage avoids retaining an entry for every item in a large offline library.
@MainActor
final class ThumbnailFailureRegistry {
    private var entries: Set<String> = []
    private var order: [String] = []
    private let limit = 1_024

    func contains(_ key: String) -> Bool { entries.contains(key) }
    func record(_ key: String) {
        guard entries.insert(key).inserted else { return }
        order.append(key)
        if order.count > limit { entries.remove(order.removeFirst()) }
    }
    func clear(_ key: String) {
        guard entries.remove(key) != nil else { return }
        order.removeAll { $0 == key }
    }
}

/// A real button inside an otherwise pass-through photo cell.
final class ThumbnailRetryControl: NSButton {}

/// Badges belong to the stable grid slot rather than the thumbnail's animated, clipped frame.
struct ThumbnailBadgeOverlay: View {
    let item: PhotoItem

    var body: some View {
        ZStack {
            if let duration = item.additional?.videoMeta?.duration,
               item.type == "video", duration.isFinite, duration > 0 {
                Text(Self.formattedDuration(duration))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 3))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .accessibilityLabel("Video duration \(Self.formattedDuration(duration))")
            }
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .accessibilityLabel("Favorite")
            }
        }
        .allowsHitTesting(false)
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Decoded images shared by browser cells, the viewer, Map and album cards. Thread-safe
/// (`NSCache` and a lock for validation state), so loads can stay off the main thread.
final class DecodedImages: @unchecked Sendable {
    static let shared = DecodedImages()

    final class Rendition: @unchecked Sendable {
        let image: NSImage
        let cgImage: CGImage
        let digest: String
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var verified: Bool { lock.withLock { $0 } }
        init(cgImage: CGImage, digest: String, verified: Bool) {
            self.cgImage = cgImage
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.digest = digest
            lock.withLock { $0 = verified }
        }
        func markVerified() { lock.withLock { $0 = true } }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let renditions = NSCache<NSString, Rendition>()
    private let gate = DecodeGate()
    private init() {
        cache.totalCostLimit = 128 * 1_000_000
        renditions.totalCostLimit = 384 * 1_000_000
    }

    func clear() {
        cache.removeAllObjects()
        renditions.removeAllObjects()
    }

    /// A decoded rendition by its caller-defined identity, without touching its bytes.
    func rendition(_ key: String) -> Rendition? { renditions.object(forKey: key as NSString) }

    /// Decodes bytes for an identified rendition. Identical bytes reuse the existing
    /// decoded image and only update its validation state.
    func renditionImage(key: String, data: Data, verified: Bool, maxPixel: Int) async -> Rendition? {
        let digest = Self.digest(data)
        let cacheKey = key as NSString
        if let existing = renditions.object(forKey: cacheKey), existing.digest == digest {
            if verified { existing.markVerified() }
            return existing
        }
        guard let box = await decode(data, maxPixel: maxPixel) else { return nil }
        let rendition = Rendition(cgImage: box.image, digest: digest, verified: verified)
        renditions.setObject(rendition, forKey: cacheKey, cost: box.image.bytesPerRow * box.image.height)
        return rendition
    }

    func image(from data: Data, maxPixel: Int) async -> NSImage? {
        let key = "\(Self.digest(data)):\(maxPixel)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let box = await decode(data, maxPixel: maxPixel) else { return nil }
        let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
        cache.setObject(image, forKey: key, cost: box.image.bytesPerRow * box.image.height)
        return image
    }

    private static func digest(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            bytes.append(hex[Int(byte >> 4)]); bytes.append(hex[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func decode(_ data: Data, maxPixel: Int) async -> CGImageBox? {
        let signposter = SynologyDiagnostics.browserSignposts
        let wait = signposter.beginInterval("Decode wait", id: signposter.makeSignpostID())
        do { try await gate.acquire() } catch {
            signposter.endInterval("Decode wait", wait, "cancelled")
            return nil
        }
        signposter.endInterval("Decode wait", wait)
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        let state = signposter.beginInterval("Decode", id: signposter.makeSignpostID(), "\(data.count) bytes")
        let box = Self.decodeImage(data, maxPixel: maxPixel)
        signposter.endInterval("Decode", state)
        guard !Task.isCancelled else { return nil }
        return box
    }

    /// Images that already fit and need no orientation transform are decoded directly,
    /// which is about twice as fast as ImageIO's thumbnail path for cached thumbnails.
    private static func decodeImage(_ data: Data, maxPixel: Int) -> CGImageBox? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(width, height) <= maxPixel,
           ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1,
           let image = CGImageSourceCreateImageAtIndex(source, 0, [
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            return CGImageBox(image)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary) else { return nil }
        return CGImageBox(image)
    }
}

/// Bounds concurrent decodes. The newest request runs first, so cells that just
/// scrolled into view are not stuck behind work for cells that already left it.
private actor DecodeGate {
    private let limit = 4
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if Task.isCancelled { release(); throw CancellationError() }
    }

    func release() {
        if !waiting.isEmpty {
            let (_, continuation) = waiting.removeLast()
            continuation.resume()
        } else { active = max(0, active - 1) }
    }

    private func cancel(_ id: UUID) {
        if let position = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: position).1.resume(throwing: CancellationError())
        }
    }
}
