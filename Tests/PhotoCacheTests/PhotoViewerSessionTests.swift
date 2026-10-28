import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

fileprivate actor ViewerTransport: PhotosTransport {
    var pages: [Int: [PhotoItem]] = [:]
    var blockedPages: Set<Int> = []
    var releasedPages: Set<Int> = []
    var blockedFullImages: Set<Int64> = []
    var releasedFullImages: Set<Int64> = []
    var blockedThumbnails: Set<Int64> = []
    var releasedThumbnails: Set<Int64> = []
    var failedFullImages: Set<Int64> = []
    var failImages = false
    private(set) var pageCalls: [Int] = []
    private(set) var pageCollections: [PhotoCollectionDescriptor] = []
    private(set) var thumbnailCalls: [Int64] = []
    private(set) var thumbnailRequests: [(Int64, ThumbnailSize)] = []
    private(set) var cancelledThumbnails: Set<Int64> = []
    private(set) var fullImageCalls: [Int64] = []
    private(set) var fullImageKeys: [String] = []
    private(set) var cancelledFullImages: Set<Int64> = []
    private(set) var favoriteRequests: [(Int64, Bool)] = []
    private(set) var favoriteWrites: [(Int64, Bool)] = []
    var failFavorite = false
    var blockFavorite = false
    var releaseFavorite = false

    func configure(pages: [Int: [PhotoItem]], blockedPages: Set<Int> = [],
                   blockedFullImages: Set<Int64> = [], blockedThumbnails: Set<Int64> = [],
                   failedFullImages: Set<Int64> = [], failImages: Bool = false) {
        self.pages = pages
        self.blockedPages = blockedPages
        self.blockedFullImages = blockedFullImages
        self.blockedThumbnails = blockedThumbnails
        self.failedFullImages = failedFullImages
        self.failImages = failImages
    }

    func releasePage(_ offset: Int) { releasedPages.insert(offset) }
    func releaseFullImage(_ id: Int64) { releasedFullImages.insert(id) }
    func releaseThumbnail(_ id: Int64) { releasedThumbnails.insert(id) }
    func setFavoriteFailure(_ enabled: Bool) { failFavorite = enabled }
    func setFavoriteBlocked(_ enabled: Bool) { blockFavorite = enabled }
    func releaseFavoriteWrite() { releaseFavorite = true }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        favoriteRequests.append(contentsOf: itemIDs.map { ($0, favorite) })
        while blockFavorite, !releaseFavorite {
            try await Task.sleep(for: .milliseconds(2))
        }
        if failFavorite { throw TestFailure("Favorite write failed") }
        favoriteWrites.append(contentsOf: itemIDs.map { ($0, favorite) })
    }
    private func loadItems(in section: TimelineSection) async throws -> [PhotoItem] {
        pageCalls.append(section.offset)
        while blockedPages.contains(section.offset), !releasedPages.contains(section.offset) {
            try await Task.sleep(for: .milliseconds(2))
        }
        return pages[section.offset] ?? []
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        let days = try pages.keys.sorted().map { key in
            try CollectionDayCount(day: CaptureDay(year: 2024, month: 4, day: key == 0 ? 3 : 2), count: pages[key]!.count)
        }
        return try CollectionDayCatalog(days: days, completeness: initial ? .partial : .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        pageCollections.append(request.collection)
        var rows: [PhotoItem] = []
        if request.newestDay.day == 3 && request.oldestDay.day <= 3 {
            let key = request.offset == 0 ? 0 : request.offset
            let section = TimelineSection(offset: key, limit: request.limit, list: [])
            rows += try await loadItems(in: section).map { try fixtureItem($0, on: CaptureDay(year: 2024, month: 4, day: 3)) }
        }
        if request.oldestDay.day <= 2 && request.newestDay.day >= 2 {
            let key = pages[2] != nil ? 2 : 1
            rows += try await loadItems(in: TimelineSection(offset: key, limit: request.limit, list: [])).map { try fixtureItem($0, on: CaptureDay(year: 2024, month: 4, day: 2)) }
        }
        return CollectionBatchResult(items: rows, profile: fields)
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        thumbnailCalls.append(descriptor.unitID)
        thumbnailRequests.append((descriptor.unitID, size))
        if failImages { throw TestFailure("Offline") }
        do {
            while blockedThumbnails.contains(descriptor.unitID),
                  !releasedThumbnails.contains(descriptor.unitID) {
                try await Task.sleep(for: .milliseconds(2))
            }
        } catch is CancellationError {
            cancelledThumbnails.insert(descriptor.unitID)
            throw CancellationError()
        }
        return ThumbnailResponse(data: Data([UInt8(truncatingIfNeeded: descriptor.unitID), 0x54]),
                                 etag: "thumb-\(descriptor.unitID)", lastModified: nil)
    }
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse {
        fullImageCalls.append(resource.unitID)
        fullImageKeys.append(resource.cacheKey)
        if failImages { throw TestFailure("Offline") }
        if failedFullImages.contains(resource.unitID) {
            throw TestFailure("Original failed")
        }
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

class PhotoViewerSessionTestCase: XCTestCase {
    fileprivate let server = URL(string: "https://viewer.example.invalid")!
    fileprivate let credentials = SynologyCredentials(username: "viewer", password: "unused", otpSecret: "unused")

    fileprivate func root() -> URL { temporaryTestRoot("SynoViewerTest") }

    fileprivate func item(_ id: Int, type: String = "photo", revision: String? = nil) throws -> PhotoItem {
        let key = revision ?? "key-\(id)"
        let json = """
        {"id":\(id),"filename":"\(id).jpg","time":1711929600,"type":"\(type)","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"\(key)","sm":"ready","m":"ready","xl":"ready"}}}
        """
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    fileprivate func snapshot() -> TimelineSnapshot {
        return TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2)]),
            TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 2, itemCount: 2)])
        ])
    }

    fileprivate func repository(root: URL, transport: ViewerTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

}

final class PhotoViewerNavigationTests: PhotoViewerSessionTestCase {
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
}

final class PhotoViewerAssetLifecycleTests: PhotoViewerSessionTestCase {
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
        let oneNeighborStarted = await waitUntil {
            let calls = await transport.fullImageCalls
            return calls.contains(1) || calls.contains(3)
        }
        XCTAssertTrue(oneNeighborStarted)
        calls = await transport.fullImageCalls
        XCTAssertFalse(calls.contains(4))
        await session.navigatePrevious()
        let promoted = await waitUntil { await session.state().item?.id == 1 }
        XCTAssertTrue(promoted)
        let selectedStarted = await waitUntil { await transport.fullImageCalls.contains(1) }
        XCTAssertTrue(selectedStarted)
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

    func testLargeViewerPreviewAndOriginalWaitForStableSelection() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])],
                                  blockedFullImages: [2])
        let repository = try repository(root: cacheRoot, transport: transport)
        let session = PhotoViewerSession(repository: repository,
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         thumbnailSize: .sm, loadsLargePreviews: true,
                                         allowNetwork: true)
        _ = await session.state()
        try await Task.sleep(for: .milliseconds(40))
        let earlyThumbnails = await transport.thumbnailRequests
        let earlyOriginals = await transport.fullImageCalls
        XCTAssertTrue(earlyThumbnails.contains { $0.0 == 2 && $0.1 == .sm })
        XCTAssertFalse(earlyThumbnails.contains { $0.1 == .xl })
        XCTAssertTrue(earlyOriginals.isEmpty)
        let earlyState = await session.state()
        XCTAssertTrue(earlyState.isLoadingLargePreview)

        let concurrent = await waitUntil {
            let thumbnails = await transport.thumbnailRequests
            let originals = await transport.fullImageCalls
            return [1, 2, 3].allSatisfy { id in
                thumbnails.contains { $0.0 == Int64(id) && $0.1 == .sm } &&
                    thumbnails.contains { $0.0 == Int64(id) && $0.1 == .xl }
            } && originals.contains(2)
        }
        XCTAssertTrue(concurrent)
        let neighborPreviewsReady = await waitUntil {
            let state = await session.state()
            return state.previousNeighbor?.largePreviewData == Data([1, 0x54]) &&
                state.nextNeighbor?.largePreviewData == Data([3, 0x54])
        }
        XCTAssertTrue(neighborPreviewsReady)
        let state = await session.state()
        XCTAssertEqual(state.thumbnailData, Data([2, 0x54]))
        XCTAssertNil(state.fullImageData)

        let descriptor = try XCTUnwrap(items[1].additional?.thumbnail)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let entry = try await repository.store.get(
            CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: .xl)
        )
        XCTAssertEqual(entry?.kind, .previewThumbnail)
        await session.close()
    }

    func testViewerUsesCachedSmallerRenditionWhileConfiguredXLDownloads() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(12)
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [selected]], blockedThumbnails: [12])
        let repository = try repository(root: cacheRoot, transport: transport)
        try await repository.setConfiguredThumbnailSize(.xl)
        let descriptor = try XCTUnwrap(selected.additional?.thumbnail)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let medium = CacheKey.thumbnailIdentity(namespace: namespace, descriptor: descriptor, size: .m)
        try await repository.store.put(medium.key, kind: .thumbnail, data: Data([0xAA]),
                                       validatedRun: "older-run", thumbnail: medium)
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: repository,
            index: LibraryIndex(snapshot: oneSection),
            seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0, item: selected,
                                  page: [selected], pageVerified: true),
            thumbnailSize: .xl, allowNetwork: true)

        let fallbackLoaded = await waitUntil { await session.state().thumbnailData == Data([0xAA]) }
        XCTAssertTrue(fallbackLoaded)
        let exactStarted = await waitUntil {
            await transport.thumbnailRequests.contains { $0.0 == 12 && $0.1 == .xl }
        }
        XCTAssertTrue(exactStarted)
        await transport.releaseThumbnail(12)
        let exactLoaded = await waitUntil { await session.state().thumbnailData == Data([12, 0x54]) }
        XCTAssertTrue(exactLoaded)
        await session.close()
    }

    func testRapidNavigationOnlyStartsExpensiveRequestsForSettledSelection() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3), item(4)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: Array(items[0...1]), 2: Array(items[2...3])])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot()),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: items[0], page: Array(items[0...1]),
                                                               pageVerified: true),
                                         thumbnailSize: .sm, loadsLargePreviews: true,
                                         allowNetwork: true)
        _ = await session.state()
        await session.navigateNext()
        await session.navigateNext()
        await session.navigateNext()
        let resolved = await waitUntil { await session.state().item?.id == 4 }
        XCTAssertTrue(resolved)

        try await Task.sleep(for: .milliseconds(40))
        let earlyThumbnails = await transport.thumbnailRequests
        let earlyOriginals = await transport.fullImageCalls
        XCTAssertFalse(earlyThumbnails.contains { $0.0 < 4 && $0.1 == .xl })
        XCTAssertFalse(earlyOriginals.contains { $0 < 4 })

        let settled = await waitUntil {
            let thumbnails = await transport.thumbnailRequests
            let originals = await transport.fullImageCalls
            return thumbnails.contains { $0.0 == 4 && $0.1 == .xl } && originals.contains(4)
        }
        XCTAssertTrue(settled)
        await session.close()
    }

    func testLargePreviewSettingIsInactiveForXLAndOffPreservesConfiguredSize() async throws {
        let xlRoot = root(); defer { try? FileManager.default.removeItem(at: xlRoot) }
        let selected = try item(8)
        let oneSection = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let xlTransport = ViewerTransport()
        await xlTransport.configure(pages: [0: [selected]])
        let xlRepository = try repository(root: xlRoot, transport: xlTransport)
        let xlSession = PhotoViewerSession(repository: xlRepository,
            index: LibraryIndex(snapshot: oneSection),
            seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0, item: selected,
                                  page: [selected], pageVerified: true),
            thumbnailSize: .xl, loadsLargePreviews: true, allowNetwork: true)
        _ = await xlSession.state()
        let xlLoaded = await waitUntil { await xlSession.state().thumbnailData != nil }
        XCTAssertTrue(xlLoaded)
        let xlDescriptor = try XCTUnwrap(selected.additional?.thumbnail)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let xlEntry = try await xlRepository.store.get(
            CacheKey.thumbnail(namespace: namespace, descriptor: xlDescriptor, size: .xl)
        )
        XCTAssertEqual(xlEntry?.kind, .thumbnail)
        await xlSession.close()

        let offRoot = root(); defer { try? FileManager.default.removeItem(at: offRoot) }
        let offTransport = ViewerTransport()
        await offTransport.configure(pages: [0: [selected]])
        let offSession = PhotoViewerSession(repository: try repository(root: offRoot, transport: offTransport),
            index: LibraryIndex(snapshot: oneSection),
            seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0, item: selected,
                                  page: [selected], pageVerified: true),
            thumbnailSize: .sm, loadsLargePreviews: false, allowNetwork: true)
        _ = await offSession.state()
        let offLoaded = await waitUntil { await offSession.state().thumbnailData != nil }
        XCTAssertTrue(offLoaded)
        let requests = await offTransport.thumbnailRequests
        XCTAssertTrue(requests.contains { $0.0 == 8 && $0.1 == .sm })
        XCTAssertFalse(requests.contains { $0.1 == .xl })
        await offSession.close()
    }

    func testFullImageFailureRetainsLargePreview() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(9)
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [selected]], failedFullImages: [9])
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
            index: LibraryIndex(snapshot: snapshot),
            seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0, item: selected,
                                  page: [selected], pageVerified: true),
            thumbnailSize: .sm, loadsLargePreviews: true, allowNetwork: true)
        _ = await session.state()
        let retained = await waitUntil {
            let state = await session.state()
            if case .failure("Original failed") = state.fullImageStatus {
                return state.thumbnailData == Data([9, 0x54]) && state.fullImageData == nil
            }
            return false
        }
        XCTAssertTrue(retained)
        await session.close()
    }

    func testSelectingInflightAdjacentPreviewPromotesItAndCancelsObsoleteNeighbor() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: items], blockedFullImages: [2],
                                  blockedThumbnails: [1, 3])
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 3,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3)])])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
            index: LibraryIndex(snapshot: snapshot),
            seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1, item: items[1],
                                  page: items, pageVerified: true),
            thumbnailSize: .sm, loadsLargePreviews: true, allowNetwork: true)
        _ = await session.state()
        let neighborsStarted = await waitUntil {
            let requests = await transport.thumbnailRequests
            return [1, 3].allSatisfy { id in
                requests.contains { $0.0 == Int64(id) && $0.1 == .sm } &&
                    requests.contains { $0.0 == Int64(id) && $0.1 == .xl }
            }
        }
        XCTAssertTrue(neighborsStarted)
        let speculativeCount = await session.speculativeThumbnailCount()
        XCTAssertLessThanOrEqual(speculativeCount, 4)

        await session.navigatePrevious()
        await transport.releaseThumbnail(1)
        let selectedLoaded = await waitUntil {
            let state = await session.state()
            return state.item?.id == 1 && state.thumbnailData == Data([1, 0x54])
        }
        XCTAssertTrue(selectedLoaded)
        let requests = await transport.thumbnailRequests
        XCTAssertEqual(requests.filter { $0.0 == 1 && $0.1 == .sm }.count, 1,
                       "Selecting a prefetched configured thumbnail must reuse its shared transfer")
        XCTAssertEqual(requests.filter { $0.0 == 1 && $0.1 == .xl }.count, 1,
                       "Selecting a prefetched large preview must reuse its shared transfer")
        let obsoleteCancelled = await waitUntil { await transport.cancelledThumbnails.contains(3) }
        XCTAssertTrue(obsoleteCancelled)
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

    func testAdjacentConfiguredThumbnailsAreRetainedForInstantNavigation() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: items])
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 3,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3)])])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: items,
                                                               pageVerified: true),
                                         thumbnailSize: .m, allowNetwork: true)
        _ = await session.state()
        let neighborsReady = await waitUntil {
            let state = await session.state()
            return state.previousNeighbor?.itemID == 1 &&
                state.previousNeighbor?.thumbnailIdentity == "1:key-1" &&
                state.previousNeighbor?.thumbnailData == Data([1, 0x54]) &&
                state.nextNeighbor?.itemID == 3 &&
                state.nextNeighbor?.thumbnailIdentity == "3:key-3" &&
                state.nextNeighbor?.thumbnailData == Data([3, 0x54])
        }
        XCTAssertTrue(neighborsReady)
        await session.close()
    }

    func testThumbnailLookaheadWarmsTwoItemsInEachDirection() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try (1...5).map { try item($0) }
        let transport = ViewerTransport()
        await transport.configure(pages: [0: items], blockedFullImages: [3])
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 5,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 5)])])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
            index: LibraryIndex(snapshot: snapshot),
            seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 2, item: items[2],
                                  page: items, pageVerified: true),
            thumbnailSize: .m, allowNetwork: true)
        _ = await session.state()
        let ready = await waitUntil {
            let state = await session.state()
            return Set(state.thumbnailLookahead.compactMap { $0.thumbnailData == nil ? nil : $0.itemID }) == [1, 5]
        }
        XCTAssertTrue(ready)
        let fullCalls = await transport.fullImageCalls
        XCTAssertFalse(fullCalls.contains(1))
        XCTAssertFalse(fullCalls.contains(5))
        await session.close()
    }

    func testCachedXLNeighborsAreRetainedWithoutNetwork() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2), item(3)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: items])
        let repository = try repository(root: cacheRoot, transport: transport)
        for neighbor in [items[1], items[2]] {
            let descriptor = try XCTUnwrap(neighbor.additional?.thumbnail)
            for await _ in await repository.thumbnail(descriptor, size: .xl, allowNetwork: true) {}
        }
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 3,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3)])])
        let session = PhotoViewerSession(repository: repository,
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: items[0], page: items,
                                                               pageVerified: true),
                                         thumbnailSize: .xl, allowNetwork: false)
        _ = await session.state()
        let neighborReady = await waitUntil {
            let state = await session.state()
            return state.nextNeighbor?.itemID == 2 &&
                state.nextNeighbor?.thumbnailIdentity == "2:key-2" &&
                state.nextNeighbor?.thumbnailData == Data([2, 0x54])
        }
        XCTAssertTrue(neighborReady)
        await session.close()
    }

    func testCachedFallbackThumbnailIsRetainedForInstantNavigation() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try [item(1), item(2)]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: items])
        let repository = try repository(root: cacheRoot, transport: transport)
        let descriptor = try XCTUnwrap(items[1].additional?.thumbnail)
        for await _ in await repository.thumbnail(descriptor, size: .xl, allowNetwork: true) {}
        let snapshot = TimelineSnapshot(sections: [TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2)])])
        let session = PhotoViewerSession(repository: repository,
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: items[0], page: items,
                                                               pageVerified: true),
                                         thumbnailSize: .m, allowNetwork: false)
        _ = await session.state()
        let neighborReady = await waitUntil {
            let state = await session.state()
            return state.nextNeighbor?.itemID == 2 &&
                state.nextNeighbor?.thumbnailIdentity == "2:key-2" &&
                state.nextNeighbor?.thumbnailData == Data([2, 0x54])
        }
        XCTAssertTrue(neighborReady)
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
}

final class PhotoViewerMetadataValidationTests: PhotoViewerSessionTestCase {
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
        await transport.configure(pages: [0: [selected, other]])
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
        for await _ in await repository.timeline() {}
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let pageKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor))
        try await seedMetadataPage([stale], section: descriptor, repository: repository)

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
        let enhancementStarted = await waitUntil { await transport.fullImageKeys == ["current"] }
        XCTAssertTrue(enhancementStarted)

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
        try await seedMetadataPage(Array(items[2...3]), section: snapshot.sections[1], repository: repository)
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
            return count >= 1 && pageCalls.contains(2)
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
}

extension PhotoViewerAssetLifecycleTests {
    func testRetryPreservesLoadedImagesAndSelection() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(14)
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [selected]])
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: selected, page: [selected],
                                                               pageVerified: true),
                                         allowNetwork: true)
        let loaded = await waitUntil {
            let state = await session.state()
            return state.thumbnailData != nil && state.fullImageData != nil
        }
        XCTAssertTrue(loaded)
        let before = await session.state()
        await session.retry()
        let retried = await session.state()
        XCTAssertEqual(retried.selection, before.selection)
        XCTAssertEqual(retried.thumbnailData, before.thumbnailData)
        XCTAssertEqual(retried.fullImageData, before.fullImageData)
        await session.close()
    }

    func testCloseBeforeEnhancementDelayPreventsExpensiveTransfers() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let selected = try item(14)
        let transport = ViewerTransport()
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        ])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         index: LibraryIndex(snapshot: snapshot),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: selected, page: [selected],
                                                               pageVerified: true),
                                         allowNetwork: true)
        _ = await session.state()
        await session.close()
        try await Task.sleep(for: .milliseconds(150))
        let state = await session.state()
        let thumbnails = await transport.thumbnailRequests
        let originals = await transport.fullImageCalls
        XCTAssertTrue(state.isClosed)
        XCTAssertTrue(thumbnails.isEmpty)
        XCTAssertTrue(originals.isEmpty)
        let speculativeThumbnails = await session.speculativeThumbnailCount()
        let speculativeOriginals = await session.speculativeFullImageCount()
        XCTAssertEqual(speculativeThumbnails, 0)
        XCTAssertEqual(speculativeOriginals, 0)
    }

    func testVideoUsesPreviewAndPublishesPlaybackResourceWithoutPhotoOriginal() async throws {
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
        let state = await session.state()
        XCTAssertEqual(state.videoResource?.variant, .original)
        XCTAssertEqual(state.fullImageStatus, .idle)
        let fullCalls = await transport.fullImageCalls
        XCTAssertTrue(fullCalls.isEmpty)
        await session.close()
    }

    func testLivePhotoLoadsStillImageInsteadOfReportingUnsupportedVideo() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let livePhoto = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":15,"filename":"15.HEIC","time":1711929600,"type":"live","live_type":"live","additional":{"thumbnail":{"unit_id":15,"cache_key":"key-15","sm":"ready","m":"ready","xl":"ready"}}}
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
}

final class PhotoViewerFavoriteTests: PhotoViewerSessionTestCase {
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
        let stored = try await repo.store.metadataPage(try DayPageAddress(section: section, collection: .personalLibrary), namespace: repo.metadataNamespace, currentRun: repo.runID)?.completeItems ?? []
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

        XCTAssertEqual(replayed?.values[51], true)
    }

    func testFavoriteWriteSurvivesViewerCloseAndUpdatesTimeline() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let first = try item(61)
        let section = TimelineSection(offset: 0, limit: 1,
                                      list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [first]])
        await transport.setFavoriteBlocked(true)
        let repo = try repository(root: cacheRoot, transport: transport)
        for await _ in await repo.page(section) {}
        let window = LibraryPageWindow(repository: repo)
        await window.update(snapshot: TimelineSnapshot(sections: [section]), allowNetwork: true,
                            visible: [0], prefetch: [])
        let pageLoaded = await waitUntil { await window.retainedPages().first?.items.count == 1 }
        XCTAssertTrue(pageLoaded)
        let session = PhotoViewerSession(repository: repo,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: [section])),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: first, page: [first],
                                                               pageVerified: true), allowNetwork: true)
        _ = await session.state()

        let toggle = Task { await session.toggleFavorite() }
        let writeStarted = await waitUntil { await transport.favoriteRequests.count == 1 }
        XCTAssertTrue(writeStarted)
        let viewerUpdatedBeforeResponse = await waitUntil {
            await session.state().item?.isFavorite == true
        }
        XCTAssertTrue(viewerUpdatedBeforeResponse)
        let timelineUpdatedBeforeResponse = await waitUntil {
            await window.retainedPages().first?.items.first?.isFavorite == true
        }
        XCTAssertTrue(timelineUpdatedBeforeResponse)
        await session.close()
        await transport.releaseFavoriteWrite()
        await toggle.value

        let completedWrites = await transport.favoriteWrites.count
        XCTAssertEqual(completedWrites, 1)
        let timelineUpdated = await waitUntil {
            await window.retainedPages().first?.items.first?.isFavorite == true
        }
        XCTAssertTrue(timelineUpdated)
        let key = try XCTUnwrap(CacheKey.page(namespace: CacheKey.namespace(server: server,
                                                                           account: credentials.username),
                                              section: section))
        let store = await repo.store
        let cached = try await store.metadataPage(try DayPageAddress(section: section, collection: .personalLibrary), namespace: repo.metadataNamespace, currentRun: repo.runID)
        XCTAssertEqual(cached?.slots.first?.item?.isFavorite, true)
        await window.cancelAll()
    }

    func testFavoritePendingStateFollowsItsPhotoAcrossNavigation() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let first = try item(63)
        let second = try item(64)
        let section = TimelineSection(offset: 0, limit: 2,
                                      list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2)])
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [first, second]])
        await transport.setFavoriteBlocked(true)
        let repo = try repository(root: cacheRoot, transport: transport)
        let session = PhotoViewerSession(repository: repo,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: [section])),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: first, page: [first, second],
                                                               pageVerified: true), allowNetwork: true)
        _ = await session.state()

        let firstToggle = Task { await session.toggleFavorite() }
        let firstRequestStarted = await waitUntil { await transport.favoriteRequests.count == 1 }
        XCTAssertTrue(firstRequestStarted)
        await session.navigateNext()
        let reachedSecond = await waitUntil {
            let state = await session.state()
            return state.item?.id == second.id && state.metadataVerified
        }
        XCTAssertTrue(reachedSecond)
        var state = await session.state()
        XCTAssertFalse(state.favoriteUpdating,
                       "A write for the previous photo must not disable the new selection")

        let secondToggle = Task { await session.toggleFavorite() }
        let secondUpdated = await waitUntil {
            let state = await session.state()
            return state.item?.id == second.id && state.item?.isFavorite == true && state.favoriteUpdating
        }
        XCTAssertTrue(secondUpdated)
        await session.navigatePrevious()
        let returnedToFirst = await waitUntil { await session.state().item?.id == first.id }
        XCTAssertTrue(returnedToFirst)
        state = await session.state()
        XCTAssertTrue(state.favoriteUpdating,
                      "Returning to the photo whose write is pending should disable only that photo")

        await transport.releaseFavoriteWrite()
        await firstToggle.value
        await secondToggle.value
        let writes = await transport.favoriteWrites.count
        XCTAssertEqual(writes, 2)
        await session.close()
    }

    func testFavoritesViewerNavigatesUsingFavoritesPages() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let first = try item(71).withFavorite(true)
        let second = try item(72).withFavorite(true)
        let sections = [
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)]),
            TimelineSection(offset: 0, limit: 1,
                            list: [TimelineDay(year: 2024, month: 4, day: 2, itemCount: 1)])
        ]
        let transport = ViewerTransport()
        await transport.configure(pages: [0: [first], 1: [second]])
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         collection: .favorites,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: sections)),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0,
                                                               item: first, page: [first],
                                                               pageVerified: true), allowNetwork: true)
        _ = await session.state()
        await session.navigateNext()
        let reachedSecond = await waitUntil { await session.state().item?.id == second.id }
        XCTAssertTrue(reachedSecond)
        let collections = await transport.pageCollections
        XCTAssertFalse(collections.isEmpty)
        XCTAssertTrue(collections.allSatisfy { $0 == .favorites })
        await session.close()
    }

    func testFavoritesViewerUsesPreWriteOffsetsWhileRemovalIsPending() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try (0..<254).map { try item(80 + $0).withFavorite(true) }
        let day = TimelineDay(year: 2024, month: 4, day: 3, itemCount: 254)
        let sections = [
            TimelineSection(offset: 0, limit: 250, list: [day]),
            TimelineSection(offset: 250, limit: 4, list: [day]),
        ]
        let transport = ViewerTransport()
        await transport.configure(pages: [250: Array(items[250...253])])
        await transport.setFavoriteBlocked(true)
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         collection: .favorites,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: sections)),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: Array(items[0...249]),
                                                               pageVerified: true), allowNetwork: true)
        _ = await session.state()

        let toggle = Task { await session.toggleFavorite() }
        let writeStarted = await waitUntil { await transport.favoriteRequests.count == 1 }
        XCTAssertTrue(writeStarted)
        await session.navigate(by: 249)

        let reachedNextPage = await waitUntil { await session.state().item?.id == items[250].id }
        XCTAssertTrue(reachedNextPage)
        let calls = await transport.pageCalls
        XCTAssertTrue(calls.contains(250), "Pending removal must query the server's still-unmodified page offset")
        XCTAssertFalse(calls.contains(249), "Optimistic status must not be mistaken for committed membership")

        await transport.releaseFavoriteWrite()
        await toggle.value
        await session.close()
    }

    func testFavoritesViewerReplansInflightPageWhenRemovalCommits() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let items = try (0..<254).map { try item(100 + $0).withFavorite(true) }
        let day = TimelineDay(year: 2024, month: 4, day: 3, itemCount: 254)
        let sections = [
            TimelineSection(offset: 0, limit: 250, list: [day]),
            TimelineSection(offset: 250, limit: 4, list: [day]),
        ]
        let transport = ViewerTransport()
        await transport.configure(pages: [249: Array(items[250...253]), 250: Array(items[250...253])],
                                  blockedPages: [250])
        await transport.setFavoriteBlocked(true)
        let session = PhotoViewerSession(repository: try repository(root: cacheRoot, transport: transport),
                                         collection: .favorites,
                                         index: LibraryIndex(snapshot: TimelineSnapshot(sections: sections)),
                                         seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 1,
                                                               item: items[1], page: Array(items[0...249]),
                                                               pageVerified: true), allowNetwork: true)
        _ = await session.state()

        let toggle = Task { await session.toggleFavorite() }
        let writeStarted = await waitUntil { await transport.favoriteRequests.count == 1 }
        XCTAssertTrue(writeStarted)
        await session.navigate(by: 249)
        let pendingPageStarted = await waitUntil { await transport.pageCalls.contains(250) }
        XCTAssertTrue(pendingPageStarted)

        await transport.releaseFavoriteWrite()
        await toggle.value

        let reachedReplannedPage = await waitUntil { await session.state().item?.id == items[250].id }
        XCTAssertTrue(reachedReplannedPage,
                      "Committing membership must restart a page canceled under the pending translation")
        let calls = await transport.pageCalls
        XCTAssertTrue(calls.contains(249), "Committed removal should translate the original page past the tombstone")
        await session.close()
    }
}
