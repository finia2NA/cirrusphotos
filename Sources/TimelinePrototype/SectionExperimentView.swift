import AppKit
import CryptoKit
import ImageIO
import PhotoCache
import SwiftUI
import SynologyAPI

struct SectionExperimentView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var items: [PhotoItem] = []
    @State private var pageVerified = false
    @State private var loadedSectionKey: String?
    @State private var status = "Waiting for timeline…"
    @State private var error: String?

    private var section: TimelineSection? {
        guard let sections = library.snapshot?.sections, sections.indices.contains(207) else { return nil }
        return sections[207]
    }
    private var sectionIdentity: String {
        guard let section, let bounds = section.dateBounds else { return "missing" }
        return "\(bounds.start):\(bounds.end):\(section.offset):\(section.limit):\(library.timelineVerified)"
    }

    var body: some View {
        Group {
            if let section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Section 207").font(.title2.weight(.semibold))
                        Spacer()
                        Text(status).foregroundStyle(.secondary)
                        if let error { Image(systemName: "exclamationmark.circle").help(error) }
                    }
                    Text("\(items.count) of \(section.limit) items · \(library.thumbnailSize.rawValue.uppercased()) thumbnails")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)], spacing: 6) {
                            ForEach(items) { item in
                                ThumbnailCell(item: item, repository: library.repository,
                                              size: library.thumbnailSize, allowNetwork: pageVerified)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    if let error, items.isEmpty { Text(error).foregroundStyle(.secondary) }
                }
                .padding(20)
                .task(id: sectionIdentity) { await load(section) }
                .onChange(of: library.error) { _, newError in
                    if newError != nil, !pageVerified { status = items.isEmpty ? "Unavailable" : "Offline copy" }
                }
            } else if library.snapshot != nil, library.timelineVerified {
                ContentUnavailableView("Section 207 is unavailable", systemImage: "square.grid.3x3",
                                       description: Text("The current timeline contains fewer than 208 sections."))
            } else {
                ProgressView("Waiting for full timeline…")
            }
        }
        .background(Color(red: 0.065, green: 0.065, blue: 0.07))
    }

    private func load(_ section: TimelineSection) async {
        guard let repository = library.repository else { return }
        if let bounds = section.dateBounds {
            let key = "\(bounds.start):\(bounds.end):\(section.offset):\(section.limit)"
            if loadedSectionKey != key { items = []; loadedSectionKey = key }
        }
        pageVerified = false
        status = "Checking section…"
        error = nil
        for await event in await repository.page(section, allowNetwork: library.timelineVerified) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let page, let verified):
                items = page
                pageVerified = verified
                status = verified ? "Current" : (library.error == nil ? "Cached · Checking" : "Offline copy")
            case .failure(let message):
                error = message
                status = items.isEmpty ? "Could not load" : "Offline copy"
            }
        }
        await library.refreshUsage()
    }
}

private struct ThumbnailCell: View {
    let item: PhotoItem
    let repository: CachedPhotosRepository?
    let size: ThumbnailSize
    let allowNetwork: Bool
    @State private var image: NSImage?
    @State private var failed = false

    private var descriptor: ThumbnailInfo? { item.additional?.thumbnail }
    private var identity: String {
        "\(descriptor?.unitID ?? 0):\(descriptor?.cacheKey ?? "missing"):\(size.rawValue):\(allowNetwork)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(height: 170)
        .clipped()
        .task(id: identity) { await load() }
    }

    private func load() async {
        guard let descriptor, descriptor.isReady(size), let repository else {
            failed = true; return
        }
        failed = false
        for await event in await repository.thumbnail(descriptor, size: size, allowNetwork: allowNetwork) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let data, _):
                if let decoded = await DecodedImages.shared.image(from: data, maxPixel: 520) {
                    image = decoded
                } else { failed = true }
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

struct CacheSettingsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        Form {
            Picker("Thumbnail size", selection: $library.thumbnailSize) {
                Text("Small").tag(ThumbnailSize.sm)
                Text("Medium").tag(ThumbnailSize.m)
                Text("Large").tag(ThumbnailSize.xl)
            }
            HStack {
                Text("Maximum cache")
                Slider(value: $library.budgetFraction, in: 0...1)
                Text(ByteCountFormatter.string(fromByteCount: CacheBudget.bytes(at: library.budgetFraction), countStyle: .file))
                    .frame(width: 90, alignment: .trailing)
            }
            HStack {
                Text("Stored data")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: library.cacheUsage, countStyle: .file))
                Button("Clear Cache") { Task { await library.clearCache() } }
            }
        }
        .padding(24).frame(width: 500)
        .task { await library.refreshUsage() }
    }
}
