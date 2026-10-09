import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SynologyAPI
@testable import PhotoCache

final class RotationTests: XCTestCase {
    private func item(_ id: Int64, key: String = "old", orientation: Int = 1,
                      width: Int = 400, height: Int = 300) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(id).jpg","time":1712102400,"type":"photo","additional":{"thumbnail":{"unit_id":\(id + 100),"cache_key":"\(key)","sm":"ready","m":"ready","xl":"ready"},"resolution":{"width":\(width),"height":\(height)},"orientation":\(orientation),"orientation_original":1}}
        """.utf8))
    }

    private func repository(_ transport: RotationTransport, root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "rotation", password: "pw", otpSecret: "unused"),
            budget: 100_000_000, cacheRoot: root, transport: transport
        )
    }

    func testNormalRotationAdoptsAuthoritativeDescriptorAndCacheKey() async throws {
        let root = temporaryTestRoot("RotationSuccess")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try item(1)
        let refreshed = try item(1, key: "new", orientation: 6, width: 300, height: 400)
        let transport = RotationTransport(thumbnail: try jpeg(), refreshed: refreshed)
        let repository = try repository(transport, root: root)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let action = SelectionRotationAction(itemIDs: [1], sectionsByID: [1: section],
                                             collection: .personalLibrary, itemsByID: [1: original])
        let store = await repository.store
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(
            server: SynologyClient.defaultBaseURL, account: "rotation"), section: section))
        try await store.put(key, kind: .page, data: JSONEncoder().encode([original]), validatedRun: "run")
        try await repository.rotate(action, direction: .clockwise)
        let calls = await transport.rotateCalls
        XCTAssertEqual(calls.first?.0, [1])
        XCTAssertEqual(calls.first?.1, .clockwise)
        let cached = try await store.get(key)
        let cachedItems = try JSONDecoder().decode([PhotoItem].self, from: XCTUnwrap(cached).data)
        XCTAssertEqual(cachedItems.first?.additional?.thumbnail?.cacheKey, "new")
        XCTAssertEqual(cachedItems.first?.additional?.resolution?.width, 300)
    }

    func testNormalRotationFailureRollsBackCachedMetadata() async throws {
        let root = temporaryTestRoot("RotationRollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try item(2)
        let transport = RotationTransport(thumbnail: try jpeg(), refreshed: original, failRotate: true)
        let repository = try repository(transport, root: root)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let action = SelectionRotationAction(itemIDs: [2], sectionsByID: [2: section],
                                             collection: .personalLibrary, itemsByID: [2: original])
        let store = await repository.store
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(
            server: SynologyClient.defaultBaseURL, account: "rotation"), section: section))
        try await store.put(key, kind: .page, data: JSONEncoder().encode([original]), validatedRun: "run")
        do {
            try await repository.rotate(action, direction: .clockwise)
            XCTFail("Expected rotation failure")
        } catch {}
        let stored = try await store.get(key)
        let cached = try XCTUnwrap(stored)
        let item = try XCTUnwrap(JSONDecoder().decode([PhotoItem].self, from: cached.data).first)
        XCTAssertEqual(item.additional?.thumbnail?.cacheKey, "old")
        XCTAssertEqual(item.additional?.resolution?.width, 400)
        XCTAssertEqual(item.additional?.orientation, 1)
    }

    func testThumbnailUploadFailureRestoresRegeneratingUnit() async throws {
        let root = temporaryTestRoot("RotationRestore")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try item(7)
        let transport = RotationTransport(thumbnail: try jpeg(), refreshed: original, failUpload: true)
        let repository = try repository(transport, root: root)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let action = SelectionRotationAction(itemIDs: [7], sectionsByID: [7: section],
                                             collection: .personalLibrary, itemsByID: [7: original])
        var final: ThumbnailRotationProgress?
        for await progress in await repository.rotateThumbnails(action, direction: .counterClockwise) {
            final = progress
        }
        XCTAssertEqual(final?.stage, .finished)
        XCTAssertEqual(final?.failures.count, 1)
        let restored = await transport.restoredUnits
        let uploaded = await transport.uploadedUnits
        XCTAssertEqual(restored, [[107]])
        XCTAssertEqual(uploaded, [107])
    }

    func testThumbnailWorkflowRotatesAllThreeJPEGsAndFinishesWithoutRestore() async throws {
        let root = temporaryTestRoot("RotationThumbnailSuccess")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try item(9)
        let refreshed = try item(9, key: "new")
        let transport = RotationTransport(thumbnail: try jpeg(), refreshed: refreshed)
        let repository = try repository(transport, root: root)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let action = SelectionRotationAction(itemIDs: [9], sectionsByID: [9: section],
                                             collection: .personalLibrary, itemsByID: [9: original])
        var final: ThumbnailRotationProgress?
        for await progress in await repository.rotateThumbnails(action, direction: .clockwise) { final = progress }
        XCTAssertEqual(final?.stage, .finished)
        XCTAssertTrue(final?.failures.isEmpty == true)
        let restored = await transport.restoredUnits
        let uploadedFiles = await transport.uploadedFiles
        XCTAssertEqual(restored.count, 0)
        let uploaded = try XCTUnwrap(uploadedFiles.first)
        for data in [uploaded.sm, uploaded.m, uploaded.xl] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 3)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 4)
        }
    }

    func testAmbiguousUploadCancellationRestoresAndAdoptsAdvancedCacheKey() async throws {
        let root = temporaryTestRoot("RotationAmbiguousUpload")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try item(11)
        let refreshed = try item(11, key: "committed")
        let transport = RotationTransport(thumbnail: try jpeg(), refreshed: refreshed,
                                          initialItem: original, uploadCommitsThenCancels: true)
        let repository = try repository(transport, root: root)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let action = SelectionRotationAction(itemIDs: [11], sectionsByID: [11: section],
                                             collection: .personalLibrary, itemsByID: [11: original])
        let store = await repository.store
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(
            server: SynologyClient.defaultBaseURL, account: "rotation"), section: section))
        try await store.put(key, kind: .page, data: JSONEncoder().encode([original]), validatedRun: "run")
        var final: ThumbnailRotationProgress?
        for await progress in await repository.rotateThumbnails(action, direction: .clockwise) { final = progress }
        XCTAssertEqual(final?.stage, .finished)
        XCTAssertFalse(final?.failures.isEmpty == true)
        let restored = await transport.restoredUnits
        XCTAssertEqual(restored, [[111]])
        let stored = try await store.get(key)
        let cached = try XCTUnwrap(stored)
        let cachedItem = try XCTUnwrap(JSONDecoder().decode([PhotoItem].self, from: cached.data).first)
        XCTAssertEqual(cachedItem.additional?.thumbnail?.cacheKey, "committed")
    }

    func testAmbiguousSetRegeneratingFailureRestoresDescriptorUnitAndReconciles() async throws {
        let root = temporaryTestRoot("RotationAmbiguousSet")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try item(12)
        let refreshed = try item(12, key: "set-committed")
        let transport = RotationTransport(thumbnail: try jpeg(), refreshed: refreshed,
                                          initialItem: original, setCommitsThenThrows: true)
        let repository = try repository(transport, root: root)
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let action = SelectionRotationAction(itemIDs: [12], sectionsByID: [12: section],
                                             collection: .personalLibrary, itemsByID: [12: original])
        let store = await repository.store
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(
            server: SynologyClient.defaultBaseURL, account: "rotation"), section: section))
        try await store.put(key, kind: .page, data: JSONEncoder().encode([original]), validatedRun: "run")
        for await _ in await repository.rotateThumbnails(action, direction: .clockwise) {}
        let restored = await transport.restoredUnits
        XCTAssertEqual(restored, [[112]])
        let stored = try await store.get(key)
        let cached = try XCTUnwrap(stored)
        let cachedItem = try XCTUnwrap(JSONDecoder().decode([PhotoItem].self, from: cached.data).first)
        XCTAssertEqual(cachedItem.additional?.thumbnail?.cacheKey, "set-committed")
    }

    private func jpeg() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor RotationTransport: PhotosTransport {
    let thumbnailData: Data
    let refreshed: PhotoItem
    let failUpload: Bool
    let failRotate: Bool
    let uploadCommitsThenCancels: Bool
    let setCommitsThenThrows: Bool
    var currentItem: PhotoItem
    var rotateCalls: [([Int64], PhotoRotationDirection)] = []
    var restoredUnits: [[Int64]] = []
    var uploadedUnits: [Int64] = []
    var uploadedFiles: [ConvertedThumbnailFiles] = []

    init(thumbnail: Data, refreshed: PhotoItem, failUpload: Bool = false, failRotate: Bool = false,
         initialItem: PhotoItem? = nil, uploadCommitsThenCancels: Bool = false,
         setCommitsThenThrows: Bool = false) {
        thumbnailData = thumbnail
        self.refreshed = refreshed
        self.failUpload = failUpload
        self.failRotate = failRotate
        self.currentItem = initialItem ?? refreshed
        self.uploadCommitsThenCancels = uploadCommitsThenCancels
        self.setCommitsThenThrows = setCommitsThenThrows
    }

    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws {
        rotateCalls.append((itemIDs, direction))
        if failRotate { throw TestFailure("rotation failed") }
    }
    func items(ids: [Int64]) async throws -> [PhotoItem] { [currentItem] }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, etag: String?,
                   lastModified: String?) async throws -> ThumbnailResponse {
        ThumbnailResponse(data: thumbnailData, etag: nil, lastModified: nil)
    }
    func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit] {
        if setCommitsThenThrows {
            currentItem = refreshed
            throw TestFailure("set response lost")
        }
        return [RegeneratingThumbnailUnit(itemID: itemIDs.first, unitID: (itemIDs.first ?? 0) + 100)]
    }
    func restoreFromRegenerating(unitIDs: [Int64]) async throws { restoredUnits.append(unitIDs) }
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles) async throws {
        uploadedUnits.append(unitID)
        uploadedFiles.append(files)
        if uploadCommitsThenCancels {
            currentItem = refreshed
            throw CancellationError()
        }
        if failUpload { throw TestFailure("upload failed") }
    }
}
