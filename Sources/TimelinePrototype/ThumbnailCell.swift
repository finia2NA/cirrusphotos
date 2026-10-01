import AppKit
import CryptoKit
import ImageIO
import PhotoCache
import SwiftUI
import SynologyAPI

/// A reusable, demand-loaded thumbnail for a frame supplied by its parent row.
struct ThumbnailCell: View {
    let item: PhotoItem
    let repository: CachedPhotosRepository?
    let size: ThumbnailSize
    let allowNetwork: Bool
    @State private var image: NSImage?
    @State private var displayedRendition: String?
    @State private var failed = false

    private var descriptor: ThumbnailInfo? { item.additional?.thumbnail }
    private var renditionIdentity: String {
        "\(item.id):\(descriptor?.unitID ?? 0):\(descriptor?.cacheKey ?? "missing"):\(size.rawValue)"
    }
    private var taskIdentity: String { "\(renditionIdentity):\(allowNetwork)" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: taskIdentity) { await load() }
    }

    private func load() async {
        if displayedRendition != renditionIdentity {
            image = nil
            displayedRendition = renditionIdentity
        }
        guard let descriptor, descriptor.isReady(size), let repository else {
            failed = true; return
        }
        failed = false
        for await event in await repository.thumbnail(descriptor, size: size, allowNetwork: allowNetwork) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let data, _):
                if let decoded = await DecodedImages.shared.image(from: data, maxPixel: 520) {
                    guard !Task.isCancelled else { return }
                    image = decoded
                } else if !Task.isCancelled { failed = true }
            case .failure:
                if image == nil { failed = true }
            }
        }
    }
}

private final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

@MainActor
final class DecodedImages {
    static let shared = DecodedImages()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.totalCostLimit = 100 * 1_000_000 }

    func clear() { cache.removeAllObjects() }

    func image(from data: Data, maxPixel: Int) async -> NSImage? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "\(digest):\(maxPixel)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let box = await Task.detached(priority: .utility) { () -> CGImageBox? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                  ] as CFDictionary) else { return nil }
            return CGImageBox(cg)
        }.value
        guard let box else { return nil }
        let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
        cache.setObject(image, forKey: key, cost: box.image.bytesPerRow * box.image.height)
        return image
    }
}
