import AppKit
import Combine
import Foundation
import ImageIO
import PhotoCache
import SynologyAPI
import UniformTypeIdentifiers
import XCTest
@testable import SynoTimelineApp

private actor PresentationTransport: PhotosTransport {
    let preview: Data
    private var previews: [Int64: Data] = [:]
    private var releasedThumbnails: Set<Int64> = [1]
    private(set) var timelineCalls: [(PhotoCollectionDescriptor, Bool)] = []
    private(set) var albumListCalls = 0
    private(set) var incomingListCalls = 0

    init(preview: Data) { self.preview = preview }
    func releaseThumbnail(_ id: Int64) { releasedThumbnails.insert(id) }
    func setPreview(_ data: Data, for id: Int64) { previews[id] = data }
    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {}
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        timelineCalls.append((collection, initial))
        return try fixtureDayCatalog(TimelineSnapshot(sections: []), initial: initial)
    }
    func albums() async throws -> [AlbumSummary] {
        albumListCalls += 1
        return []
    }
    func incomingAlbums() async throws -> [IncomingAlbum] {
        incomingListCalls += 1
        return []
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        while !releasedThumbnails.contains(descriptor.unitID) {
            try await Task.sleep(for: .milliseconds(2))
        }
        return ThumbnailResponse(data: previews[descriptor.unitID] ?? preview, etag: nil, lastModified: nil)
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
                   space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
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
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
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

    func testArrowNavigationReusesPrefetchedNeighborImageWithoutBlanking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPreview = try previewData(width: 6, height: 4)
        let nextPreview = try previewData(width: 12, height: 8)
        let transport = PresentationTransport(preview: firstPreview)
        await transport.setPreview(nextPreview, for: 2)
        await transport.releaseThumbnail(2)
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://instant-navigation.example.invalid")!, cacheRoot: root,
            transport: transport)
        let items = try [item(1), item(2)]
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])])
        let source = PhotoViewerSourceAnchor()
        source.update(itemID: 1, image: try XCTUnwrap(NSImage(data: firstPreview)))
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: items[0], page: items, pageVerified: true), source: source),
            thumbnailSize: .m, allowNetwork: true, snapshotRevision: 1)

        let neighborDataReady = await waitUntil {
            viewer.state?.nextNeighbor?.itemID == 2 && viewer.state?.nextNeighbor?.thumbnailData != nil
        }
        XCTAssertTrue(neighborDataReady)
        let identity = try XCTUnwrap(viewer.state?.nextNeighbor?.thumbnailIdentity)
        let neighborDecoded = await waitUntil { viewer.decodedThumbnailIdentities.contains(identity) }
        XCTAssertTrue(neighborDecoded)
        XCTAssertNotNil(viewer.nextNeighborImage)
        XCTAssertEqual(viewer.nextNeighborItemID, 2)
        XCTAssertNil(viewer.previousNeighborItemID)

        var observedImages: [NSImage?] = []
        let cancellable = viewer.$image.sink { observedImages.append($0) }
        defer { cancellable.cancel() }

        viewer.navigateNext()
        let navigated = await waitUntil { viewer.state?.selection.itemID == 2 }
        XCTAssertTrue(navigated)
        XCTAssertFalse(observedImages.contains { $0 == nil },
                       "Cached arrow navigation must not clear the displayed image")
        XCTAssertEqual(viewer.image?.size.width, 12)
        XCTAssertEqual(viewer.image?.size.height, 8)
        XCTAssertTrue(viewer.close())
        await viewer.session.close()
    }

    func testPrefetchedLargePreviewUpgradesNeighborAndSurvivesNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ProgressivePresentationTransport(
            configuredThumbnail: try previewData(width: 6, height: 4),
            preview: try previewData(width: 12, height: 8),
            original: try previewData(width: 30, height: 20))
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://neighbor-preview.example.invalid")!, cacheRoot: root,
            transport: transport)
        let items = try [item(1), item(2)]
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])])
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: items[0], page: items, pageVerified: true), source: PhotoViewerSourceAnchor()),
            thumbnailSize: .m, loadsLargePreviews: true, allowNetwork: true, snapshotRevision: 1)
        await transport.releaseConfiguredThumbnail()
        let thumbnailReady = await waitUntil { viewer.nextNeighborImage?.size.width == 6 }
        XCTAssertTrue(thumbnailReady)
        await transport.releasePreview()
        let previewReady = await waitUntil { viewer.nextNeighborImage?.size.width == 12 }
        XCTAssertTrue(previewReady)
        var widths: [CGFloat] = []
        let subscription = viewer.$image.sink { if let width = $0?.size.width { widths.append(width) } }
        viewer.navigateNext()
        let selected = await waitUntil { viewer.state?.selection.itemID == 2 }
        XCTAssertTrue(selected)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(viewer.image?.size.width, 12)
        XCTAssertFalse(widths.suffix(from: min(1, widths.count)).contains(6))
        subscription.cancel()
        XCTAssertTrue(viewer.close())
        await viewer.session.close()
    }

    func testLateNeighborDecodeInstallsTheNowCurrentImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPreview = try previewData(width: 6, height: 4)
        let nextPreview = try previewData(width: 12, height: 8)
        let transport = PresentationTransport(preview: firstPreview)
        await transport.setPreview(nextPreview, for: 2)
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://late-neighbor.example.invalid")!, cacheRoot: root,
            transport: transport)
        let items = try [item(1), item(2)]
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])])
        let source = PhotoViewerSourceAnchor()
        source.update(itemID: 1, image: try XCTUnwrap(NSImage(data: firstPreview)))
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
            request: PhotoViewerOpenRequest(seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                item: items[0], page: items, pageVerified: true), source: source),
            thumbnailSize: .m, allowNetwork: true, snapshotRevision: 1)

        viewer.navigateNext()
        let navigated = await waitUntil { viewer.state?.selection.itemID == 2 }
        XCTAssertTrue(navigated)
        XCTAssertNil(viewer.image)
        let identity = try XCTUnwrap(viewer.state?.thumbnailIdentity)
        let decoded = try XCTUnwrap(NSImage(data: nextPreview))

        viewer.finishNeighborThumbnailDecode(decoded, identity: identity)

        XCTAssertTrue(viewer.image === decoded)
        XCTAssertFalse(viewer.isDisplayingFullResolution)
        XCTAssertTrue(viewer.close())
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
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
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
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
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
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
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
        let viewer = PhotoViewerPresentation(repository: repository, collection: .library(.personal), index: LibraryIndex(snapshot: snapshot),
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
    func testLibraryModelEagerlyLoadsTimelinesAndLazilyLoadsAlbumList() async throws {
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
        XCTAssertTrue(calls.contains { $0.0 == .library(.personal) })
        XCTAssertTrue(calls.contains { $0.0 == .favorites(.personal) && !$0.1 })
        XCTAssertFalse(calls.contains { $0.0 == .favorites(.personal) && $0.1 })
        XCTAssertNotNil(model.snapshot(for: .library(.personal)))
        XCTAssertNotNil(model.snapshot(for: .favorites(.personal)))
        let albumCallsBeforeDemand = await transport.albumListCalls
        XCTAssertEqual(albumCallsBeforeDemand, 0)
        let incomingCallsBeforeDemand = await transport.incomingListCalls
        XCTAssertEqual(incomingCallsBeforeDemand, 0)

        model.ensureAlbumsLoaded()
        var loadedAlbums = false
        for _ in 0..<500 {
            if await transport.albumListCalls == 1, await transport.incomingListCalls == 1, model.albumsVerified {
                loadedAlbums = true
                break
            }
            try? await Task.sleep(for: .milliseconds(3))
        }
        XCTAssertTrue(loadedAlbums)
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
        let browserRevision = model.snapshotRevision(for: .favorites(.personal))
        let viewerRevision = model.viewerSnapshotRevision(for: .favorites(.personal))
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])

        try await repository.setFavorite(itemID: 77, item: try item(77), in: section, collection: .library(.personal), to: true)
        let refreshed = await waitUntil {
            model.snapshotRevision(for: .favorites(.personal)) > browserRevision
        }

        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.viewerSnapshotRevision(for: .favorites(.personal)), viewerRevision)
    }
}
