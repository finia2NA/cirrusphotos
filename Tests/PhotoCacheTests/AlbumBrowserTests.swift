import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor AlbumFakeTransport: PhotosTransport {
    var albumList: [AlbumSummary] = []
    var albumListFailure: String?
    var albumEntriesByID: [Int64: [DayTimelineEntry]] = [:]
    var timelineSnapshot = TimelineSnapshot(sections: [])
    var pageItems: [PhotoItem] = []
    var pageFailure: String?
    var albumListCalls = 0
    var albumTimelineCalls: [Int64] = []
    var collectionTimelineCalls: [(PhotoCollectionDescriptor, Bool)] = []
    var itemRequests: [(TimelineSection, PhotoCollectionDescriptor)] = []
    var favoriteWrites: [(Int64, Bool)] = []
    var favoriteFailure = false

    func configure(albumList: [AlbumSummary] = [],
                   albumEntriesByID: [Int64: [DayTimelineEntry]] = [:],
                   timelineSnapshot: TimelineSnapshot = TimelineSnapshot(sections: []),
                   pageItems: [PhotoItem] = [],
                   albumListFailure: String? = nil,
                   pageFailure: String? = nil) {
        self.albumList = albumList
        self.albumEntriesByID = albumEntriesByID
        self.timelineSnapshot = timelineSnapshot
        self.pageItems = pageItems
        self.albumListFailure = albumListFailure
        self.pageFailure = pageFailure
    }

    func login(credentials: SynologyCredentials) async throws {}

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        collectionTimelineCalls.append((collection, initial))
        return timelineSnapshot
    }

    func albums() async throws -> [AlbumSummary] {
        albumListCalls += 1
        if let albumListFailure { throw TestFailure(albumListFailure) }
        return albumList
    }

    func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot {
        albumTimelineCalls.append(albumID)
        return DayGroupedTimelineBuilder.build(entries: albumEntriesByID[albumID] ?? []).snapshot
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        itemRequests.append((section, collection))
        if let pageFailure { throw TestFailure(pageFailure) }
        return pageItems
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        if favoriteFailure { throw TestFailure("Favorite write failed") }
        favoriteWrites.append(contentsOf: itemIDs.map { ($0, favorite) })
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        throw TestFailure("Unexpected thumbnail request")
    }

    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse {
        throw TestFailure("Unexpected original-image request")
    }
}

final class AlbumBrowserTests: XCTestCase {
    private let server = URL(string: "https://example.invalid")!
    private let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")

    private func root() -> URL { temporaryTestRoot("SynoAlbumTest") }

    private func makeRepository(root: URL, transport: AlbumFakeTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server, cacheRoot: root, transport: transport)
    }

    private func section(_ day: Int, offset: Int = 0, limit: Int = 2, count: Int = 2) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
                        list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: count)])
    }

    private func item(_ id: Int, favorite: Bool = false) throws -> PhotoItem {
        let favoriteJSON = favorite ? ",\"favorite\":true" : ""
        return try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":\(id),\"time\":1711929600,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":\(id),\"cache_key\":\"\(id)_rev\"}\(favoriteJSON)}}".utf8))
    }

    private func thumbnail(_ unit: Int64) -> ThumbnailInfo {
        ThumbnailInfo(unitID: unit, cacheKey: "\(unit)_rev", sm: "ready", m: "ready", xl: "ready")
    }

    func testAlbumListIsPersistedAndRevalidatedOnce() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [
            AlbumSummary(id: 54, name: "Trip", itemCount: 12, thumbnail: thumbnail(77607)),
            AlbumSummary(id: 55, name: "Family", itemCount: 3),
        ])
        let repository = try makeRepository(root: root, transport: transport)
        var values: [[AlbumSummary]] = []
        for await event in await repository.albums() {
            if case .value(let list, _) = event { values.append(list) }
        }
        XCTAssertEqual(values.last?.map(\.id), [54, 55])
        let firstCalls = await transport.albumListCalls
        XCTAssertEqual(firstCalls, 1)

        let secondTransport = AlbumFakeTransport()
        await secondTransport.configure(albumList: [
            AlbumSummary(id: 54, name: "Trip", itemCount: 12, thumbnail: thumbnail(77607)),
            AlbumSummary(id: 55, name: "Family", itemCount: 3),
        ])
        let secondRepository = try makeRepository(root: root, transport: secondTransport)
        var cachedFirst = false
        var verifiedFinal = false
        for await event in await secondRepository.albums() {
            if case .value(let list, let verified) = event {
                XCTAssertEqual(list.map(\.id), [54, 55])
                if !verified { cachedFirst = true }
                if verified { verifiedFinal = true }
            }
        }
        XCTAssertTrue(cachedFirst, "The cached album list must arrive before validation")
        XCTAssertTrue(verifiedFinal)
        let secondCalls = await secondTransport.albumListCalls
        XCTAssertEqual(secondCalls, 1, "The list validates once per run")
    }

    func testAlbumTimelineScansAndCachesWithoutBrowseTimeline() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        await transport.configure(albumEntriesByID: [54: [
            DayTimelineEntry(id: 1, time: day + 10),
            DayTimelineEntry(id: 2, time: day + 20),
            DayTimelineEntry(id: 3, time: day - 86_400),
        ]])
        let repository = try makeRepository(root: root, transport: transport)
        var finalSnapshot: TimelineSnapshot?
        for await event in await repository.timeline(collection: .album(54)) {
            if case .value(let snapshot, true) = event { finalSnapshot = snapshot }
        }
        let snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-01", "2023-12-31"])
        XCTAssertEqual(snapshot.sections.count, 2)
        let albumCalls = await transport.albumTimelineCalls
        XCTAssertEqual(albumCalls, [54])
        let timelineCalls = await transport.collectionTimelineCalls
        XCTAssertTrue(timelineCalls.isEmpty, "Albums must never call Browse.Timeline")

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let cached = try await repository.store.get(
            CacheKey.timeline(namespace: namespace, collection: .album(54)))
        let entry = try XCTUnwrap(cached)
        XCTAssertEqual(try JSONDecoder().decode(TimelineSnapshot.self, from: entry.data).sections,
                       snapshot.sections)
    }

    func testEmptyAlbumScanProducesNoSections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let repository = try makeRepository(root: root, transport: transport)
        for await event in await repository.timeline(collection: .album(9)) {
            if case .value(let snapshot, true) = event {
                XCTAssertTrue(snapshot.sections.isEmpty)
            }
        }
    }

    func testAlbumPageUsesAlbumCollectionAndCachesUnderAlbumKey() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let descriptor = section(1)
        await transport.configure(pageItems: [try item(7)])
        let repository = try makeRepository(root: root, transport: transport)
        var verifiedItems: [PhotoItem] = []
        for await event in await repository.page(descriptor, collection: .album(54)) {
            if case .value(let items, true) = event { verifiedItems = items }
        }
        XCTAssertEqual(verifiedItems.map(\.id), [7])
        let requests = await transport.itemRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.1, .album(54))
        XCTAssertEqual(requests.first?.0, descriptor)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor, collection: .album(54)))
        let cached = try await repository.store.get(key)
        XCTAssertNotNil(cached)
    }

    func testAlbumAndPersonalPageKeysAreIsolated() {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let descriptor = section(1)
        XCTAssertNotEqual(CacheKey.page(namespace: namespace, section: descriptor, collection: .personalLibrary),
                          CacheKey.page(namespace: namespace, section: descriptor, collection: .album(54)))
        XCTAssertNotEqual(CacheKey.timeline(namespace: namespace, collection: .album(54)),
                          CacheKey.timeline(namespace: namespace, collection: .album(55)))
    }

    func testAlbumFavoriteBatchPatchesAlbumPagesAndLeavesPersonalUntouched() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let transport = AlbumFakeTransport()
        let descriptor = section(1)
        let photo = try item(7)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: []))
        let repository = try makeRepository(root: root, transport: transport)
        let albumKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor, collection: .album(54)))
        let personalKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor, collection: .personalLibrary))
        try await repository.store.put(albumKey, kind: .page,
                                       data: JSONEncoder().encode([photo]), validatedRun: nil)
        try await repository.store.put(personalKey, kind: .page,
                                       data: JSONEncoder().encode([photo]), validatedRun: nil)

        let action = SelectionFavoriteAction(affectedIDs: [photo.id], targetFavorite: true,
                                             sectionsByID: [photo.id: descriptor],
                                             collection: .album(54), itemsByID: [photo.id: photo])
        try await repository.setFavoritesBatch(action: action)

        let albumCached = try await repository.store.get(albumKey)
        let personalCached = try await repository.store.get(personalKey)
        let albumEntry = try XCTUnwrap(albumCached)
        let personalEntry = try XCTUnwrap(personalCached)
        let albumItems = try JSONDecoder().decode([PhotoItem].self, from: albumEntry.data)
        let personalItems = try JSONDecoder().decode([PhotoItem].self, from: personalEntry.data)
        XCTAssertTrue(albumItems[0].isFavorite)
        XCTAssertFalse(personalItems[0].isFavorite, "Album favorites must not patch Personal Library pages")
        let writes = await transport.favoriteWrites
        XCTAssertEqual(writes.map(\.0), [photo.id])
    }

    func testFavoritesBatchStillPatchesPersonalPagesByDay() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let transport = AlbumFakeTransport()
        let descriptor = section(1)
        let photo = try item(9)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [descriptor]))
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline(collection: .personalLibrary) {}
        let personalKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor, collection: .personalLibrary))
        try await repository.store.put(personalKey, kind: .page,
                                       data: JSONEncoder().encode([photo]), validatedRun: nil)

        let action = SelectionFavoriteAction(affectedIDs: [photo.id], targetFavorite: true,
                                             sectionsByID: [photo.id: descriptor],
                                             collection: .favorites, itemsByID: [photo.id: photo])
        try await repository.setFavoritesBatch(action: action)

        let personalCached = try await repository.store.get(personalKey)
        let personalEntry = try XCTUnwrap(personalCached)
        let personalItems = try JSONDecoder().decode([PhotoItem].self, from: personalEntry.data)
        XCTAssertTrue(personalItems[0].isFavorite, "Favorites actions still patch Personal Library pages")
    }
}
