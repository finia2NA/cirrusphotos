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

    func testAutomaticMatcherSupportsImageIOOriginalFormats() throws {
        let source = try patternedImage(width: 72, height: 108)
        let wrongThumbnail = try encoded(
            ThumbnailOrientationMatcher.rotate(source, clockwiseQuarterTurns: -1),
            type: .jpeg
        )
        let thumbnails = Dictionary(uniqueKeysWithValues: ThumbnailSize.allCases.map {
            ($0, wrongThumbnail)
        })
        let metadata = try item(20, width: 72, height: 108)

        for type in [UTType.jpeg, .png, .tiff, .heic] {
            let original = try encoded(source, type: type)
            let match = try ThumbnailOrientationMatcher.match(
                originalData: original, item: metadata, thumbnails: thumbnails
            )
            XCTAssertEqual(match.clockwiseQuarterTurns, 1, "Failed for \(type.identifier)")
        }
    }

    func testAutomaticMatcherRequiresAllThreeRenditionsToAgree() throws {
        let source = try patternedImage(width: 72, height: 108)
        let needsRight = try encoded(
            ThumbnailOrientationMatcher.rotate(source, clockwiseQuarterTurns: -1), type: .jpeg
        )
        let needsLeft = try encoded(
            ThumbnailOrientationMatcher.rotate(source, clockwiseQuarterTurns: 1), type: .jpeg
        )
        let metadata = try item(21, width: 72, height: 108)

        XCTAssertThrowsError(try ThumbnailOrientationMatcher.match(
            originalData: encoded(source, type: .png), item: metadata,
            thumbnails: [.sm: needsRight, .m: needsLeft, .xl: needsRight]
        )) { error in
            guard case ThumbnailOrientationMatchError.disagreement = error else {
                return XCTFail("Expected disagreement, got \(error)")
            }
        }
    }

    func testAutomaticMatcherRejectsAmbiguousUniformImages() throws {
        let uniform = try jpeg()
        let metadata = try item(27, width: 4, height: 3)
        XCTAssertThrowsError(try ThumbnailOrientationMatcher.match(
            originalData: uniform, item: metadata,
            thumbnails: [.sm: uniform, .m: uniform, .xl: uniform]
        )) { error in
            guard case ThumbnailOrientationMatchError.ambiguous = error else {
                return XCTFail("Expected ambiguity, got \(error)")
            }
        }
    }

    func testAutomaticMatcherLeavesAlreadyCorrectRenditionsAtZero() throws {
        let source = try patternedImage(width: 72, height: 108)
        let data = try encoded(source, type: .jpeg)
        let metadata = try item(22, width: 72, height: 108)
        let match = try ThumbnailOrientationMatcher.match(
            originalData: try encoded(source, type: .tiff), item: metadata,
            thumbnails: [.sm: data, .m: data, .xl: data]
        )
        XCTAssertEqual(match.clockwiseQuarterTurns, 0)
    }

    func testAutomaticMatcherRecognizesEveryQuarterTurn() throws {
        let source = try patternedImage(width: 72, height: 108)
        let original = try encoded(source, type: .png)
        let metadata = try item(25, width: 72, height: 108)
        for correction in 0..<4 {
            let thumbnail = try encoded(
                ThumbnailOrientationMatcher.rotate(
                    source, clockwiseQuarterTurns: (4 - correction) % 4
                ),
                type: .jpeg
            )
            let match = try ThumbnailOrientationMatcher.match(
                originalData: original, item: metadata,
                thumbnails: Dictionary(uniqueKeysWithValues: ThumbnailSize.allCases.map {
                    ($0, thumbnail)
                })
            )
            XCTAssertEqual(match.clockwiseQuarterTurns, correction)
        }
    }

    func testAutomaticWorkflowDoesNotMutateWhenRenditionsDisagree() async throws {
        let root = temporaryTestRoot("RotationAutomaticDisagreement")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try patternedImage(width: 72, height: 108)
        let originalData = try encoded(source, type: .heic)
        let needsRight = try encoded(
            ThumbnailOrientationMatcher.rotate(source, clockwiseQuarterTurns: -1), type: .jpeg
        )
        let needsLeft = try encoded(
            ThumbnailOrientationMatcher.rotate(source, clockwiseQuarterTurns: 1), type: .jpeg
        )
        let original = try item(23, width: 72, height: 108)
        let transport = RotationTransport(
            thumbnails: [.sm: needsRight, .m: needsLeft, .xl: needsRight],
            original: originalData, refreshed: original
        )
        let repository = try repository(transport, root: root)
        let action = SelectionRotationAction(itemIDs: [23], sectionsByID: [:],
                                             collection: .personalLibrary,
                                             itemsByID: [23: original])
        var final: ThumbnailRotationProgress?
        for await progress in await repository.fixThumbnailRotations(action) { final = progress }

        XCTAssertEqual(final?.stage, .finished)
        XCTAssertEqual(final?.failures.count, 1)
        let regenerationCalls = await transport.regenerationCalls
        let uploadedFiles = await transport.uploadedFiles
        XCTAssertTrue(regenerationCalls.isEmpty)
        XCTAssertTrue(uploadedFiles.isEmpty)
    }

    func testAutomaticWorkflowDoesNotMutateAlreadyCorrectRenditions() async throws {
        let root = temporaryTestRoot("RotationAutomaticAlreadyCorrect")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try patternedImage(width: 72, height: 108)
        let originalData = try encoded(source, type: .tiff)
        let thumbnail = try encoded(source, type: .jpeg)
        let item = try item(26, width: 72, height: 108)
        let transport = RotationTransport(
            thumbnails: Dictionary(uniqueKeysWithValues: ThumbnailSize.allCases.map {
                ($0, thumbnail)
            }),
            original: originalData, refreshed: item
        )
        let repository = try repository(transport, root: root)
        let action = SelectionRotationAction(itemIDs: [26], sectionsByID: [:],
                                             collection: .personalLibrary,
                                             itemsByID: [26: item])
        var final: ThumbnailRotationProgress?
        for await progress in await repository.fixThumbnailRotations(action) { final = progress }

        let regenerationCalls = await transport.regenerationCalls
        let uploadedFiles = await transport.uploadedFiles
        XCTAssertTrue(final?.failures.isEmpty == true)
        XCTAssertTrue(regenerationCalls.isEmpty)
        XCTAssertTrue(uploadedFiles.isEmpty)
    }

    func testAutomaticWorkflowUploadsOnlyAfterUnanimousMatch() async throws {
        let root = temporaryTestRoot("RotationAutomaticSuccess")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try patternedImage(width: 72, height: 108)
        let originalData = try encoded(source, type: .png)
        let wrong = try encoded(
            ThumbnailOrientationMatcher.rotate(source, clockwiseQuarterTurns: -1), type: .jpeg
        )
        let original = try item(24, width: 72, height: 108)
        let refreshed = try item(24, key: "fixed", width: 72, height: 108)
        let transport = RotationTransport(
            thumbnails: Dictionary(uniqueKeysWithValues: ThumbnailSize.allCases.map { ($0, wrong) }),
            original: originalData, refreshed: refreshed
        )
        let repository = try repository(transport, root: root)
        let action = SelectionRotationAction(itemIDs: [24], sectionsByID: [:],
                                             collection: .personalLibrary,
                                             itemsByID: [24: original])
        var final: ThumbnailRotationProgress?
        for await progress in await repository.fixThumbnailRotations(action) { final = progress }

        XCTAssertTrue(final?.failures.isEmpty == true)
        let regenerationCalls = await transport.regenerationCalls
        let uploadedFiles = await transport.uploadedFiles
        XCTAssertEqual(regenerationCalls, [[24]])
        let uploaded = try XCTUnwrap(uploadedFiles.first)
        for data in [uploaded.sm, uploaded.m, uploaded.xl] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 72)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 108)
        }
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

    private func patternedImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.15, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 3, y: 5, width: width / 3, height: height / 4))
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: width / 2, y: height / 3,
                            width: width / 2 - 7, height: height / 5))
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 5, y: height * 2 / 3,
                                       width: width / 2, height: height / 4))
        return try XCTUnwrap(context.makeImage())
    }

    private func encoded(_ image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ), "ImageIO cannot encode \(type.identifier) on this system")
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor RotationTransport: PhotosTransport {
    let thumbnailData: Data
    let thumbnails: [ThumbnailSize: Data]
    let originalData: Data
    let refreshed: PhotoItem
    let failUpload: Bool
    let failRotate: Bool
    let uploadCommitsThenCancels: Bool
    let setCommitsThenThrows: Bool
    var currentItem: PhotoItem
    var rotateCalls: [([Int64], PhotoRotationDirection)] = []
    var regenerationCalls: [[Int64]] = []
    var restoredUnits: [[Int64]] = []
    var uploadedUnits: [Int64] = []
    var uploadedFiles: [ConvertedThumbnailFiles] = []

    init(thumbnail: Data, refreshed: PhotoItem, failUpload: Bool = false, failRotate: Bool = false,
         initialItem: PhotoItem? = nil, uploadCommitsThenCancels: Bool = false,
         setCommitsThenThrows: Bool = false) {
        thumbnailData = thumbnail
        thumbnails = Dictionary(uniqueKeysWithValues: ThumbnailSize.allCases.map { ($0, thumbnail) })
        originalData = thumbnail
        self.refreshed = refreshed
        self.failUpload = failUpload
        self.failRotate = failRotate
        self.currentItem = initialItem ?? refreshed
        self.uploadCommitsThenCancels = uploadCommitsThenCancels
        self.setCommitsThenThrows = setCommitsThenThrows
    }

    init(thumbnails: [ThumbnailSize: Data], original: Data, refreshed: PhotoItem) {
        self.thumbnails = thumbnails
        thumbnailData = thumbnails[.m] ?? Data()
        originalData = original
        self.refreshed = refreshed
        failUpload = false
        failRotate = false
        currentItem = refreshed
        uploadCommitsThenCancels = false
        setCommitsThenThrows = false
    }

    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws {
        rotateCalls.append((itemIDs, direction))
        if failRotate { throw TestFailure("rotation failed") }
    }
    func items(ids: [Int64]) async throws -> [PhotoItem] { [currentItem] }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, etag: String?,
                   lastModified: String?) async throws -> ThumbnailResponse {
        ThumbnailResponse(data: thumbnails[size], etag: nil, lastModified: nil)
    }
    func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit] {
        regenerationCalls.append(itemIDs)
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
    func fullImage(_ resource: FullImageResource, etag: String?,
                   lastModified: String?) async throws -> FullImageResponse {
        FullImageResponse(data: originalData, etag: nil, lastModified: nil)
    }
}
