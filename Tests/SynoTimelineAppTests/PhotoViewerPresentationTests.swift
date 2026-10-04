import AppKit
import Foundation
import ImageIO
import PhotoCache
import SynologyAPI
import UniformTypeIdentifiers
import XCTest
@testable import SynoTimelineApp

private actor PresentationTransport: PhotosTransport {
    let preview: Data
    private var releasedThumbnails: Set<Int64> = [1]
    private(set) var timelineCalls: [(PhotoCollectionDescriptor, Bool)] = []

    init(preview: Data) { self.preview = preview }
    func releaseThumbnail(_ id: Int64) { releasedThumbnails.insert(id) }
    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {}
    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        timelineCalls.append((collection, initial))
        return TimelineSnapshot(sections: [])
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        while !releasedThumbnails.contains(descriptor.unitID) {
            try await Task.sleep(for: .milliseconds(2))
        }
        return ThumbnailResponse(data: preview, etag: nil, lastModified: nil)
    }
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse {
        FullImageResponse(data: Data("unsupported original".utf8), etag: nil, lastModified: nil)
    }
}

private actor ProgressivePresentationTransport: PhotosTransport {
    let configuredThumbnail: Data
    let preview: Data
    let original: Data
    private var configuredReleased = false
    private var previewReleased = false
    private var originalReleased = false
    private(set) var thumbnailSizes: [ThumbnailSize] = []
    private(set) var fullCalls = 0

    init(configuredThumbnail: Data, preview: Data, original: Data) {
        self.configuredThumbnail = configuredThumbnail
        self.preview = preview
        self.original = original
    }

    func releaseConfiguredThumbnail() { configuredReleased = true }
    func releasePreview() { previewReleased = true }
    func releaseOriginal() { originalReleased = true }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        thumbnailSizes.append(size)
        if size == .xl {
            while !previewReleased { try await Task.sleep(for: .milliseconds(2)) }
            return ThumbnailResponse(data: preview, etag: nil, lastModified: nil)
        }
        while !configuredReleased { try await Task.sleep(for: .milliseconds(2)) }
        return ThumbnailResponse(data: configuredThumbnail, etag: nil, lastModified: nil)
    }
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse {
        fullCalls += 1
        while !originalReleased { try await Task.sleep(for: .milliseconds(2)) }
        return FullImageResponse(data: original, etag: nil, lastModified: nil)
    }
}

@MainActor
class PhotoViewerPresentationTestCase: XCTestCase {
    fileprivate func previewData(width: Int = 12, height: Int = 8) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    fileprivate func item(_ id: Int, favorite: Bool = false) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(id).jpg","time":1711929600,"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key-\(id)","m":"ready","xl":"ready"},"favorite":\(favorite)}}
        """.utf8))
    }

    fileprivate func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return false
    }
}

@MainActor
final class PhotoViewerPresentationTests: PhotoViewerPresentationTestCase {
    func testLateThumbnailRemainsAvailableAfterOriginalDecodeFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try previewData()
        let transport = PresentationTransport(preview: preview)
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://presentation.example.invalid")!, cacheRoot: root, transport: transport)
        let items = try [item(1), item(2)]
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])])
        let source = PhotoViewerSourceAnchor()
        let seedImage = try XCTUnwrap(NSImage(data: preview))
        source.update(itemID: 1, image: seedImage)
        let viewer = PhotoViewerPresentation(repository: repository, index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: items[0], page: items, pageVerified: true), source: source),
            thumbnailSize: .m, allowNetwork: true, snapshotRevision: 1)
        XCTAssertTrue(viewer.image === seedImage, "The clicked thumbnail must be available synchronously")
        let firstFailed = await waitUntil { viewer.decodeFailure != nil }
        XCTAssertTrue(firstFailed)
        XCTAssertNotNil(viewer.image)
        viewer.navigateNext()
        let secondFailed = await waitUntil { viewer.state?.item?.id == 2 && viewer.decodeFailure != nil }
        XCTAssertTrue(secondFailed)
        XCTAssertNil(viewer.image)
        await transport.releaseThumbnail(2)
        let fallbackAppeared = await waitUntil { viewer.image != nil }
        XCTAssertTrue(fallbackAppeared, "Full-image decode failure must not suppress a later valid thumbnail")
        XCTAssertNotNil(viewer.decodeFailure)
        XCTAssertTrue(viewer.close())
        XCTAssertFalse(viewer.close(), "Close must be idempotent during the collapse transition")
        await viewer.session.close()
    }

    func testConfiguredThumbnailThenLargePreviewThenOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clicked = try previewData(width: 6, height: 4)
        let preview = try previewData(width: 12, height: 8)
        let original = try previewData(width: 30, height: 20)
        let transport = ProgressivePresentationTransport(
            configuredThumbnail: clicked, preview: preview, original: original
        )
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://progressive.example.invalid")!, cacheRoot: root, transport: transport)
        let selected = try item(1)
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])])
        let viewer = PhotoViewerPresentation(repository: repository, index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: selected, page: [selected], pageVerified: true), source: PhotoViewerSourceAnchor()),
            thumbnailSize: .m, loadsLargePreviews: true,
            allowNetwork: true, snapshotRevision: 1)

        var bothStarted = false
        for _ in 0..<500 {
            let sizes = await transport.thumbnailSizes
            let fullCalls = await transport.fullCalls
            if sizes.contains(.m), sizes.contains(.xl), fullCalls > 0 { bothStarted = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(bothStarted)
        XCTAssertTrue(viewer.detailLine.hasSuffix("Loading large preview and full resolution"))
        await transport.releaseConfiguredThumbnail()
        let configuredDisplayed = await waitUntil { viewer.image?.size.width == 6 }
        XCTAssertTrue(configuredDisplayed)
        XCTAssertTrue(viewer.detailLine.hasSuffix("Loading large preview and full resolution"))
        await transport.releasePreview()
        let previewDisplayed = await waitUntil { viewer.image?.size.width == 12 }
        XCTAssertTrue(previewDisplayed)
        XCTAssertTrue(viewer.detailLine.hasSuffix("Loading full resolution"))
        let sizes = await transport.thumbnailSizes
        XCTAssertEqual(sizes.first, .m)
        XCTAssertTrue(sizes.contains(.xl))

        await transport.releaseOriginal()
        let originalDisplayed = await waitUntil { viewer.image?.size.width == 30 }
        XCTAssertTrue(originalDisplayed)
        XCTAssertTrue(viewer.close())
        await viewer.session.close()
    }

    func testLargePreviewRejectsLateConfiguredThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ProgressivePresentationTransport(
            configuredThumbnail: try previewData(width: 6, height: 4),
            preview: try previewData(width: 12, height: 8),
            original: try previewData(width: 30, height: 20))
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://late-configured.example.invalid")!, cacheRoot: root,
            transport: transport)
        let selected = try item(1)
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])])
        let viewer = PhotoViewerPresentation(repository: repository, index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: selected, page: [selected], pageVerified: true), source: PhotoViewerSourceAnchor()),
            thumbnailSize: .m, loadsLargePreviews: true,
            allowNetwork: true, snapshotRevision: 1)

        var bothStarted = false
        for _ in 0..<500 {
            let sizes = await transport.thumbnailSizes
            if sizes.contains(.m), sizes.contains(.xl) { bothStarted = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(bothStarted)
        await transport.releasePreview()
        let previewDisplayed = await waitUntil { viewer.image?.size.width == 12 }
        XCTAssertTrue(previewDisplayed)
        await transport.releaseConfiguredThumbnail()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(viewer.image?.size.width, 12)
        XCTAssertTrue(viewer.close())
        await viewer.session.close()
    }

    func testDecodedOriginalRejectsLateLargePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ProgressivePresentationTransport(
            configuredThumbnail: try previewData(width: 6, height: 4),
            preview: try previewData(width: 12, height: 8),
            original: try previewData(width: 30, height: 20))
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://late-preview.example.invalid")!, cacheRoot: root, transport: transport)
        let selected = try item(1)
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])])
        let viewer = PhotoViewerPresentation(repository: repository, index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: selected, page: [selected], pageVerified: true), source: PhotoViewerSourceAnchor()),
            thumbnailSize: .m, loadsLargePreviews: true,
            allowNetwork: true, snapshotRevision: 1)

        var bothStarted = false
        for _ in 0..<500 {
            let sizes = await transport.thumbnailSizes
            let fullCalls = await transport.fullCalls
            if sizes.contains(.m), sizes.contains(.xl), fullCalls > 0 { bothStarted = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(bothStarted)
        await transport.releaseOriginal()
        let originalDisplayed = await waitUntil { viewer.image?.size.width == 30 }
        XCTAssertTrue(originalDisplayed)
        await transport.releaseConfiguredThumbnail()
        await transport.releasePreview()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(viewer.image?.size.width, 30)
        XCTAssertTrue(viewer.close())
        await viewer.session.close()
    }

    func testSourceCanActivateRepeatedlyWithoutRetainingItsRowView() {
        final class SourceView: NSView, PhotoViewerSourceActivating {
            var activations = 0
            func activateViewerSource(_ anchor: PhotoViewerSourceAnchor) { activations += 1 }
        }
        let source = PhotoViewerSourceAnchor()
        var rowView: SourceView? = SourceView()
        weak let weakRow = rowView
        source.attach(rowView!)
        source.activate()
        source.activate()
        XCTAssertEqual(rowView?.activations, 2)
        rowView = nil
        XCTAssertNil(weakRow, "An open viewer must not pin an evicted row and its page closures")
        source.activate()
    }

    func testAlreadyFavoritedSeedHydratesViewerPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try previewData()
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://presentation.example.invalid")!, cacheRoot: root,
            transport: PresentationTransport(preview: preview))
        let favored = try item(7, favorite: true)
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])])
        let viewer = PhotoViewerPresentation(repository: repository, index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: favored, page: [favored], pageVerified: true), source: PhotoViewerSourceAnchor()),
            thumbnailSize: .m, allowNetwork: true, snapshotRevision: 1)

        let hydratedFavorite = await waitUntil {
            viewer.state?.item?.isFavorite == true && viewer.canToggleFavorite
        }
        XCTAssertTrue(hydratedFavorite)
        XCTAssertTrue(viewer.close())
        await viewer.session.close()
    }
}

@MainActor
final class LibraryModelTests: PhotoViewerPresentationTestCase {
    func testLibraryModelEagerlyLoadsBothCollectionTimelines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoModel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PresentationTransport(preview: try previewData())
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://model.example.invalid")!, cacheRoot: root,
            transport: transport)
        let model = LibraryModel(repository: repository)

        await model.load()

        let calls = await transport.timelineCalls
        XCTAssertTrue(calls.contains { $0.0 == .personalLibrary })
        XCTAssertTrue(calls.contains { $0.0 == .favorites && !$0.1 })
        XCTAssertFalse(calls.contains { $0.0 == .favorites && $0.1 })
        XCTAssertNotNil(model.snapshot(for: .personalLibrary))
        XCTAssertNotNil(model.snapshot(for: .favorites))
    }

    func testLocalFavoritesRefreshUpdatesBrowserWithoutInvalidatingViewerIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoModel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PresentationTransport(preview: try previewData())
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://model.example.invalid")!, cacheRoot: root,
            transport: transport)
        let model = LibraryModel(repository: repository)
        await model.load()
        let browserRevision = model.snapshotRevision(for: .favorites)
        let viewerRevision = model.viewerSnapshotRevision(for: .favorites)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])

        try await repository.setFavorite(itemID: 77, item: try item(77), in: section, to: true)
        let refreshed = await waitUntil {
            model.snapshotRevision(for: .favorites) > browserRevision
        }

        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.viewerSnapshotRevision(for: .favorites), viewerRevision)
    }
}
