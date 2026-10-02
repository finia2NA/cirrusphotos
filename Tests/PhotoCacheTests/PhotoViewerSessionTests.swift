import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private struct ViewerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor ViewerTransport: PhotosTransport {
    var pages: [Int: [PhotoItem]] = [:]
    var blockedPages: Set<Int> = []
    var releasedPages: Set<Int> = []
    var blockedFullImages: Set<Int64> = []
    var releasedFullImages: Set<Int64> = []
    var failImages = false
    private(set) var pageCalls: [Int] = []
    private(set) var thumbnailCalls: [Int64] = []
    private(set) var fullImageCalls: [Int64] = []
    private(set) var fullImageKeys: [String] = []
    private(set) var cancelledFullImages: Set<Int64> = []
    private(set) var favoriteWrites: [(Int64, Bool)] = []
    var failFavorite = false

    func configure(pages: [Int: [PhotoItem]], blockedPages: Set<Int> = [],
                   blockedFullImages: Set<Int64> = [], failImages: Bool = false) {
        self.pages = pages
        self.blockedPages = blockedPages
        self.blockedFullImages = blockedFullImages
        self.failImages = failImages
    }

    func releasePage(_ offset: Int) { releasedPages.insert(offset) }
    func releaseFullImage(_ id: Int64) { releasedFullImages.insert(id) }
    func setFavoriteFailure(_ enabled: Bool) { failFavorite = enabled }

    func login(credentials: SynologyCredentials) async throws {}
    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        if failFavorite { throw ViewerFailure(message: "Favorite write failed") }
        favoriteWrites.append(contentsOf: itemIDs.map { ($0, favorite) })
    }
    func timeline(initial: Bool) async throws -> TimelineSnapshot { TimelineSnapshot(sections: []) }
    func items(in section: TimelineSection) async throws -> [PhotoItem] {
        pageCalls.append(section.offset)
        while blockedPages.contains(section.offset), !releasedPages.contains(section.offset) {
            try await Task.sleep(for: .milliseconds(2))
        }
        return pages[section.offset] ?? []
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        thumbnailCalls.append(descriptor.unitID)
        if failImages { throw ViewerFailure(message: "Offline") }
        return ThumbnailResponse(data: Data([UInt8(truncatingIfNeeded: descriptor.unitID), 0x54]),
                                 etag: "thumb-\(descriptor.unitID)", lastModified: nil)
    }
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse {
        fullImageCalls.append(resource.unitID)
        fullImageKeys.append(resource.cacheKey)
        if failImages { throw ViewerFailure(message: "Offline") }
        do {
            while blockedFullImages.contains(resource.unitID),
                  !releasedFullImages.contains(resource.unitID) {
                try await Task.sleep(for: .milliseconds(2))
            }
        } catch is CancellationError {
            cancelledFullImages.insert(resource.unitID)
            throw CancellationError()
        }
        return FullImageResponse(data: Data([UInt8(truncatingIfNeeded: resource.unitID), 0x46]),
                                 etag: "full-\(resource.unitID)", lastModified: nil)
    }
}

final class PhotoViewerSessionTests: XCTestCase {
    private let server = URL(string: "https://viewer.example.invalid")!
    private let credentials = SynologyCredentials(username: "viewer", password: "unused", otpSecret: "unused")

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SynoViewerTest-\(UUID().uuidString)")
    }

    private func item(_ id: Int, type: String = "photo", revision: String? = nil) throws -> PhotoItem {
        let key = revision ?? "key-\(id)"
        let json = """
        {"id":\(id),"filename":"\(id).jpg","time":1711929600,"type":"\(type)","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"\(key)","sm":"ready","m":"ready","xl":"ready"}}}
        """
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func snapshot() -> TimelineSnapshot {
        let days = [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 4)]
        return TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 2, list: days),
            TimelineSection(offset: 2, limit: 2, list: days)
        ])
    }

    private func repository(root: URL, transport: ViewerTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return false
    }

    func testNavigationUsesExactSectionOffsetsAndClampsAtBounds() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: items[0], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         allowNetwork: true)
        await session.navigatePrevious()
        var state = await session.state()
        XCTAssertEqual(state.desiredLocation,
                       PhotoViewerLocation(sectionIndex: 0, pageOffset: 0, ordinal: 0))
        await session.navigate(by: 3)
        state = await session.state()
        XCTAssertEqual(state.desiredLocation,
                       PhotoViewerLocation(sectionIndex: 1, pageOffset: 1, ordinal: 3))
        let resolved = await waitUntil { await session.state().item?.id == 4 }
        XCTAssertTrue(resolved)
        await session.navigateNext()
        state = await session.state()
        let pageCount = await session.retainedPageCount()
        XCTAssertEqual(state.desiredLocation.ordinal, 3)
        XCTAssertLessThanOrEqual(pageCount, 3)
        await session.close()
    }

    func testRapidNavigationKeepsLatestDesiredItemAndCancelsObsoleteImage() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])],
                                  blockedPages: [2], blockedFullImages: [2, 4])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: items[0], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        await session.navigateNext()
        let secondStarted = await waitUntil { await transport.fullImageCalls.contains(2) }
        XCTAssertTrue(secondStarted)
        await session.navigateNext()
        await session.navigateNext()
        var state = await session.state()
        XCTAssertEqual(state.desiredLocation,
                       PhotoViewerLocation(sectionIndex: 1, pageOffset: 1, ordinal: 3))
        await transport.releasePage(2)
        let fourthResolved = await waitUntil { await session.state().item?.id == 4 }
        XCTAssertTrue(fourthResolved)
        let obsoleteCancelled = await waitUntil { await transport.cancelledFullImages.contains(2) }
        XCTAssertTrue(obsoleteCancelled)
        state = await session.state()
        XCTAssertNotEqual(state.item?.id, 3)
        await session.close()
    }

    func testPrefetchStartsOnlyAfterCurrentFullImageAndStaysAdjacent() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])],
                                  blockedFullImages: [2, 1, 3])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        let currentStarted = await waitUntil { await transport.fullImageCalls == [2] }
        XCTAssertTrue(currentStarted)
        try? await Task.sleep(for: .milliseconds(25))
        var calls = await transport.fullImageCalls
        XCTAssertEqual(calls, [2])

        await transport.releaseFullImage(2)
        let prefetchCreated = await waitUntil { await session.speculativeFullImageCount() == 2 }
        XCTAssertTrue(prefetchCreated)
        let speculativeCount = await session.speculativeFullImageCount()
        XCTAssertLessThanOrEqual(speculativeCount, 2)
        let firstNeighborStarted = await waitUntil { await transport.fullImageCalls.contains(1) }
        XCTAssertTrue(firstNeighborStarted)
        calls = await transport.fullImageCalls
        XCTAssertFalse(calls.contains(4))
        await session.navigatePrevious()
        let promoted = await waitUntil { await session.state().item?.id == 1 }
        XCTAssertTrue(promoted)
        try? await Task.sleep(for: .milliseconds(20))
        calls = await transport.fullImageCalls
        XCTAssertEqual(calls.filter { $0 == 1 }.count, 1,
                       "An in-flight neighboring transfer should be promoted rather than restarted")
        XCTAssertFalse(calls.contains(4))
        await transport.releaseFullImage(1)
        let promotedData = await waitUntil { await session.state().fullImageData == Data([1, 0x46]) }
        XCTAssertTrue(promotedData)
        await session.close()
    }

    func testThumbnailBufferWarmsBothNeighborsBeforeCurrentOriginalSucceeds() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])],
                                  blockedFullImages: [2])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        let buffered = await waitUntil {
            let calls = await transport.thumbnailCalls
            return calls.contains(1) && calls.contains(3)
        }
        XCTAssertTrue(buffered)
        let fullCalls = await transport.fullImageCalls
        XCTAssertFalse(fullCalls.contains(1))
        XCTAssertFalse(fullCalls.contains(3))
        await session.close()
    }

    func testNavigationKeepsUnloadedNeighborPageForThumbnailBuffer() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])],
                                  blockedPages: [2], blockedFullImages: [2])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: items[0], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        await session.navigateNext()
        let neighborPageStarted = await waitUntil { await transport.pageCalls.contains(2) }
        XCTAssertTrue(neighborPageStarted)

        await transport.releasePage(2)
        let nextThumbnailBuffered = await waitUntil { await transport.thumbnailCalls.contains(3) }
        XCTAssertTrue(nextThumbnailBuffered,
                      "Navigation must not cancel metadata needed to buffer the next thumbnail")
        let fullCalls = await transport.fullImageCalls
        XCTAssertFalse(fullCalls.contains(3),
                       "Original prefetch must remain gated on the current original succeeding")
        await session.close()
    }

    func testCachedImagesRemainVisibleWhenValidationFails() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(7)
        let warmingTransport = ViewerTransport()
        await warmingTransport.configure(pages: [0: [selected]])
        let warmingRepository = try repository(root: cacheRoot, transport: warmingTransport)
        for await _ in await warmingRepository.thumbnail(try XCTUnwrap(selected.additional?.thumbnail),
                                                          size: .xl, allowNetwork: true) {}
        for await _ in await warmingRepository.fullImage(try XCTUnwrap(selected.fullImageResource)) {}

        let offlineTransport = ViewerTransport()
        await offlineTransport.configure(pages: [0: [selected]], failImages: true)
        let offlineRepository = try repository(root: cacheRoot, transport: offlineTransport)
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: offlineRepository,
                                         index: LibraryIndex(snapshot: oneSection),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: selected, page: [selected],
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        let failedAfterCache = await waitUntil {
            let state = await session.state()
            guard state.thumbnailData != nil, state.fullImageData != nil else { return false }
            if case .ready(verified: false, validationFailure: .some("Offline")) = state.fullImageStatus,
               case .ready(verified: false, validationFailure: .some("Offline")) = state.thumbnailStatus {
                return true
            }
            return false
        }
        XCTAssertTrue(failedAfterCache)
        await session.close()
    }

    func testVerifiedMetadataRevisionReplacesProvisionalResourceBeforeNetworkImage() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let old = try item(1, revision: "old")
        let replacement = try item(1, revision: "new")
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [replacement]])
        let repository = try repository(root: cacheRoot, transport: transport)
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: repository,
                                         index: LibraryIndex(snapshot: oneSection),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: old, page: [old], pageVerified: false),
                                         allowNetwork: true)
        _ = await session.state()
        let replaced = await waitUntil {
            let state = await session.state()
            return state.item?.additional?.thumbnail?.cacheKey == "new" && state.metadataVerified &&
                state.fullImageData == Data([1, 0x46])
        }
        XCTAssertTrue(replaced)
        let keys = await transport.fullImageKeys
        XCTAssertEqual(keys, ["new"],
                       "Provisional metadata must never authorize an original-image network request")
        await session.close()
    }

    func testVerifiedPageTracksShiftedSelectedIDAndRejectsRemovedSelection() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(5)
        let other = try item(6)
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [selected]])
        let twoItems = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 2,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2)])
        ])
        let shifted = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: twoItems),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: selected, page: [other, selected],
                                                               pageVerified: false),
                                         allowNetwork: true)
        _ = await shifted.state()
        let tracked = await waitUntil {
            let state = await shifted.state()
            return state.metadataVerified && state.item?.id == 5 && state.desiredLocation.pageOffset == 0
        }
        XCTAssertTrue(tracked)
        await shifted.close()

        let removedRoot = root(); defer { try? FileManager.default.removeItem(at: removedRoot) }
        let removedTransport = ViewerTransport()
        await removedTransport.configure(pages: [0: [other]])
        let removed = PhotoViewerSession(repository: try repository(root: removedRoot, transport: removedTransport),
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: [
                                            TimelineSection(offset: 0, limit: 1,
                                                list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
                                         ])),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: selected, page: [selected],
                                                               pageVerified: false),
                                         allowNetwork: true)
        _ = await removed.state()
        let rejected = await waitUntil {
            let state = await removed.state()
            if case .failure = state.metadataStatus { return state.item == nil && state.fullImageData == nil }
            return false
        }
        XCTAssertTrue(rejected)
        await removed.close()
    }

    func testVerifiedSeedWithoutSeedPageIgnoresProvisionalCachedMetadata() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let stale = try item(20, revision: "stale")
        let current = try item(20, revision: "current")
        let descriptor = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let snapshot = TimelineSnapshot(sections: [descriptor])
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [current]], blockedPages: [0])
        let repository = try repository(root: cacheRoot, transport: transport)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let pageKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor))
        try await repository.store.put(pageKey, kind: .page,
                                       data: JSONEncoder().encode([stale]), validatedRun: nil)

        let session = PhotoViewerSession(repository: repository,
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: current, pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        let pageStarted = await waitUntil { await transport.pageCalls == [0] }
        XCTAssertTrue(pageStarted)
        try? await Task.sleep(for: .milliseconds(20))
        var state = await session.state()
        XCTAssertTrue(state.metadataVerified)
        XCTAssertEqual(state.item?.additional?.thumbnail?.cacheKey, "current")
        let keysBeforeRelease = await transport.fullImageKeys
        XCTAssertEqual(keysBeforeRelease, ["current"])

        await transport.releasePage(0)
        let pageVerified = await waitUntil {
            let state = await session.state()
            return state.metadataVerified && state.item?.additional?.thumbnail?.cacheKey == "current"
        }
        XCTAssertTrue(pageVerified)
        state = await session.state()
        XCTAssertEqual(state.item?.id, 20)
        await session.close()
    }

    func testCachedOnlyNeighborRestartsSpeculativeValidationAfterPageVerification() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let snapshot = snapshot()
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])],
                                  blockedPages: [2])
        let repository = try repository(root: cacheRoot, transport: transport)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let neighborPageKey = try XCTUnwrap(CacheKey.page(namespace: namespace,
                                                          section: snapshot.sections[1]))
        try await repository.store.put(neighborPageKey, kind: .page,
                                       data: JSONEncoder().encode(Array(items[2...3])), validatedRun: nil)
        let neighborResource = try XCTUnwrap(items[2].fullImageResource)
        try await repository.store.put(CacheKey.fullImage(namespace: namespace, resource: neighborResource),
                                       kind: .fullImage, data: Data([3, 0x46]), validatedRun: nil)

        let session = PhotoViewerSession(repository: repository,
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        let cachedNeighborRetained = await waitUntil {
            let count = await session.speculativeFullImageCount()
            let pageCalls = await transport.pageCalls
            return count == 2 && pageCalls.contains(2)
        }
        XCTAssertTrue(cachedNeighborRetained)
        var calls = await transport.fullImageCalls
        XCTAssertFalse(calls.contains(3), "Provisional neighbor metadata permits cache access only")

        await transport.releasePage(2)
        let validationRestarted = await waitUntil { await transport.fullImageCalls.contains(3) }
        XCTAssertTrue(validationRestarted)
        calls = await transport.fullImageCalls
        XCTAssertEqual(calls.filter { $0 == 3 }.count, 1)
        await session.close()
    }

    func testCachedOnlyMissRestartsWhenNetworkBecomesAllowed() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(14)
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [selected]])
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: oneSection),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: selected, page: [selected],
                                                               pageVerified: true),
                                         allowNetwork: false)
        _ = await session.state()
        let honestMiss = await waitUntil {
            if case .failure = await session.state().fullImageStatus { return true }
            return false
        }
        XCTAssertTrue(honestMiss)
        let offlineCalls = await transport.fullImageCalls
        XCTAssertTrue(offlineCalls.isEmpty)
        await session.updateAllowNetwork(true)
        let loaded = await waitUntil { await session.state().fullImageData == Data([14, 0x46]) }
        XCTAssertTrue(loaded)
        await session.close()
    }

    func testVideoUsesPreviewAndReportsUnsupportedPlayback() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let video = try item(12, type: "video")
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [video]])
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: oneSection),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: video, page: [video], pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        let preview = await waitUntil { await session.state().thumbnailData != nil }
        XCTAssertTrue(preview)
        if case .unsupported(let message) = await session.state().fullImageStatus {
            XCTAssertTrue(message.contains("Video"))
        } else {
            XCTFail("Video playback should be explicitly unsupported")
        }
        let fullCalls = await transport.fullImageCalls
        XCTAssertTrue(fullCalls.isEmpty)
        await session.close()
    }

    func testLivePhotoLoadsStillImageInsteadOfReportingUnsupportedVideo() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let livePhoto = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":15,"filename":"15.HEIC","time":1711929600,"type":"live","live_type":"photo","additional":{"thumbnail":{"unit_id":15,"cache_key":"key-15","sm":"ready","m":"ready","xl":"ready"}}}
        """.utf8))
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [livePhoto]])
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: oneSection),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: livePhoto, page: [livePhoto],
                                                               pageVerified: true),
                                         allowNetwork: true)

        let loaded = await waitUntil { await session.state().fullImageData == Data([15, 0x46]) }
        XCTAssertTrue(loaded)
        if case .unsupported(let message) = await session.state().fullImageStatus {
            XCTFail("Live Photo still image should load normally: \(message)")
        }
        let fullImageCalls = await transport.fullImageCalls
        XCTAssertEqual(fullImageCalls, [15])
        await session.close()
    }

    func testFavoriteWriteUpdatesViewerRetainedPageAndDiskCache() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let first = try item(31)
        let second = try item(32)
        let section = TimelineSection(offset: 0, limit: 2,
                                      list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2)])
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [first, second]])
        let repo = try repository(root: cacheRoot, transport: transport)
        for await _ in await repo.page(section) {}
        let window = LibraryPageWindow(repository: repo)
        await window.update(snapshot: TimelineSnapshot(sections: [section]), allowNetwork: true,
                            visible: [0], prefetch: [])
        let pageLoaded = await waitUntil { await window.retainedPages().first?.items.count == 2 }
        XCTAssertTrue(pageLoaded)
        let session = PhotoViewerSession(repository: repo,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: [section])),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: first, page: [first, second],
                                                               pageVerified: true), allowNetwork: true)
        _ = await session.state()
        await session.toggleFavorite()
        let favoredState = await session.state()
        XCTAssertTrue(favoredState.item?.isFavorite == true)
        let writes = await transport.favoriteWrites
        XCTAssertEqual(writes.count, 1)
        let badgeUpdated = await waitUntil { await window.retainedPages().first?.items.first?.isFavorite == true }
        XCTAssertTrue(badgeUpdated)
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(server: server, account: credentials.username),
                                              section: section))
        let cachedBytes = try await repo.store.get(key)?.data
        let bytes = try XCTUnwrap(cachedBytes)
        let stored = try JSONDecoder().decode([PhotoItem].self, from: bytes)
        XCTAssertTrue(stored[0].isFavorite)
        await session.toggleFavorite()
        let unfavoredState = await session.state()
        XCTAssertFalse(unfavoredState.item?.isFavorite == true)
        let badgeCleared = await waitUntil { await window.retainedPages().first?.items.first?.isFavorite == false }
        XCTAssertTrue(badgeCleared)
        await session.close()
        await window.cancelAll()
    }

    func testFavoriteFailurePreservesPreviousState() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let first = try item(41)
        let section = TimelineSection(offset: 0, limit: 1,
                                      list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [first]])
        await transport.setFavoriteFailure(true)
        let repo = try repository(root: cacheRoot, transport: transport)
        let session = PhotoViewerSession(repository: repo,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: [section])),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: first, page: [first], pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        await session.toggleFavorite()
        let state = await session.state()
        XCTAssertFalse(state.item?.isFavorite == true)
        XCTAssertFalse(state.favoriteUpdating)
        XCTAssertTrue(state.favoriteFailure?.contains("Favorite write failed") == true)
        await session.close()
    }

    func testFavoriteChangesReplayToLateSubscribers() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let section = TimelineSection(offset: 0, limit: 1,
                                      list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let transport = ViewerTransport()
        let repo = try repository(root: cacheRoot, transport: transport)

        try await repo.setFavorite(itemID: 51, in: section, to: true)
        var changes = await repo.favoriteChanges().makeAsyncIterator()
        let replayed = await changes.next()

        XCTAssertEqual(replayed?.itemID, 51)
        XCTAssertEqual(replayed?.favorite, true)
    }
}
