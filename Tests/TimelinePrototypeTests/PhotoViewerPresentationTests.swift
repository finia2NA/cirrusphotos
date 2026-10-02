import AppKit
import Foundation
import ImageIO
import PhotoCache
import SynologyAPI
import UniformTypeIdentifiers
import XCTest
@testable import TimelinePrototype

private actor PresentationTransport: PhotosTransport {
    let preview: Data
    private var releasedThumbnails: Set<Int64> = [1]

    init(preview: Data) { self.preview = preview }
    func releaseThumbnail(_ id: Int64) { releasedThumbnails.insert(id) }
    func login(credentials: SynologyCredentials) async throws {}
    func timeline(initial: Bool) async throws -> TimelineSnapshot { TimelineSnapshot(sections: []) }
    func items(in section: TimelineSection) async throws -> [PhotoItem] { [] }
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

@MainActor
final class PhotoViewerPresentationTests: XCTestCase {
    private func previewData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func item(_ id: Int) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(id).jpg","time":1711929600,"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key-\(id)","m":"ready"}}}
        """.utf8))
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return false
    }

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
}
