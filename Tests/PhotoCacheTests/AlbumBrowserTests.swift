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
    var mutationFails = false
    var replacementEntries: [DayTimelineEntry] = []
    var replacementList: [AlbumSummary] = []
    var pauseMutation = false
    var mutationStarted = false
    var mutationContinuation: CheckedContinuation<Void, Never>?
    var pauseCatalog = false
    var catalogStarted = false
    var catalogContinuation: CheckedContinuation<Void, Never>?

    func configure(albumList: [AlbumSummary] = [],
                   albumEntriesByID: [Int64: [DayTimelineEntry]] = [:],
                   timelineSnapshot: TimelineSnapshot = TimelineSnapshot(sections: []),
                   pageItems: [PhotoItem] = [],
                   albumListFailure: String? = nil,
                   pageFailure: String? = nil) {
        self.albumList = albumList
        self.albumEntriesByID = albumEntriesByID.isEmpty && !pageItems.isEmpty ? [54: pageItems.map { DayTimelineEntry(id: $0.id, time: $0.time) }] : albumEntriesByID
        self.timelineSnapshot = timelineSnapshot
        self.pageItems = pageItems
        self.albumListFailure = albumListFailure
        self.pageFailure = pageFailure
    }

    func login(credentials: SynologyCredentials) async throws {}

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        collectionTimelineCalls.append((collection, initial))
        return try fixtureDayCatalog(timelineSnapshot, initial: initial)
    }

    func albums() async throws -> [AlbumSummary] {
        albumListCalls += 1
        if let albumListFailure { throw TestFailure(albumListFailure) }
        return albumList
    }

    func configureMutation(entries: [DayTimelineEntry], list: [AlbumSummary], fails: Bool = false) {
        replacementEntries = entries; replacementList = list; mutationFails = fails
    }

    func pauseNextCatalog() { pauseCatalog = true }
    func releaseCatalog() { catalogContinuation?.resume(); catalogContinuation = nil }
    func pauseNextMutation() { pauseMutation = true }
    func releaseMutation() { mutationContinuation?.resume(); mutationContinuation = nil }

    func album(id: Int64) async throws -> AlbumSummary {
        guard let album = albumList.first(where: { $0.id == id }) else { throw TestFailure("Missing album") }
        return album
    }

    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws {
        albumEntriesByID[id] = replacementEntries
        albumList = replacementList
        if pauseMutation {
            mutationStarted = true
            await withCheckedContinuation { mutationContinuation = $0 }
            pauseMutation = false
        }
        if mutationFails { throw TestFailure("Incomplete album change") }
    }

    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        if offset == 0 { albumTimelineCalls.append(albumID) }
        let result = Array((albumEntriesByID[albumID] ?? []).dropFirst(offset).prefix(limit))
        if pauseCatalog {
            pauseCatalog = false; catalogStarted = true
            await withCheckedContinuation { catalogContinuation = $0 }
        }
        return result
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        itemRequests.append((section, collection))
        if let pageFailure { throw TestFailure(pageFailure) }
        return try fixtureBatch(pageItems, request: request, fields: fields)
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

    private func section(_ day: Int, offset: Int = 0, limit: Int = 1, count: Int = 1) -> TimelineSection {
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

        let namespace = await repository.metadataNamespace
        let cached = try await repository.store.metadataCatalog(.init(namespace: namespace, collection: .album(54)))
        XCTAssertEqual(cached?.catalog.days.map(\.day.id), ["2024-01-01", "2023-12-31"])

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
            if case .value(let items, true) = event { let items = items.completeItems ?? []; verifiedItems = items }
        }
        XCTAssertEqual(verifiedItems.map(\.id), [7])
        let requests = await transport.itemRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.1, .album(54))
        XCTAssertEqual(requests.first?.0, descriptor)

        let cached = try await repository.store.metadataPage(try XCTUnwrap(DayPageAddress(section: descriptor, collection: .album(54))), namespace: repository.metadataNamespace, currentRun: repository.runID)
        XCTAssertEqual(cached?.slots.map(\.itemID), [7])

    }

    func testAlbumAndPersonalPageKeysAreIsolated() {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let descriptor = section(1)
        XCTAssertNotEqual(CacheKey.page(namespace: namespace, section: descriptor, collection: .personalLibrary),
                          CacheKey.page(namespace: namespace, section: descriptor, collection: .album(54)))
        XCTAssertNotEqual(CacheKey.page(namespace: namespace, section: descriptor, collection: .album(54)),
                          CacheKey.page(namespace: namespace, section: descriptor, collection: .album(55)))
    }

    func testConfirmedFavoriteSharesCanonicalDetailsAcrossCollections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let descriptor = section(1)
        let photo = try item(7)
        let repository = try makeRepository(root: root, transport: transport)
        for collection: PhotoCollectionDescriptor in [.album(54), .personalLibrary] {
            try await seedMetadataPage([photo], section: descriptor, repository: repository, collection: collection)
        }
        let action = SelectionFavoriteAction(affectedIDs: [photo.id], targetFavorite: true,
            sectionsByID: [photo.id: descriptor], collection: .album(54), itemsByID: [photo.id: photo])
        try await repository.setFavoritesBatch(action: action)
        for collection: PhotoCollectionDescriptor in [.album(54), .personalLibrary] {
            let cached = try await repository.store.metadataPage(try XCTUnwrap(DayPageAddress(section: descriptor, collection: collection)), namespace: repository.metadataNamespace, currentRun: repository.runID)
            XCTAssertEqual(cached?.slots.first?.item?.isFavorite, true)
        }
        let writes = await transport.favoriteWrites
        XCTAssertEqual(writes.map(\.0), [photo.id])
    }
    func testMembershipMutationRefreshesSameCountAndPreservesLibrary() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let old = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(1))
        let updated = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(2))
        await transport.configure(albumList: [old], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [updated])
        let repository = try makeRepository(root: root, transport: transport)
        let descriptor = section(1)
        try await seedMetadataPage([try item(1)], section: descriptor, repository: repository, collection: .personalLibrary)
        for await _ in await repository.albums() { }
        var albumSection: TimelineSection?
        var albumSnapshot: TimelineSnapshot?
        for await event in await repository.timeline(collection: .album(54)) {
            if case .value(let snapshot, true) = event { albumSection = snapshot.sections.first; albumSnapshot = snapshot }
        }
        let snapshot = try XCTUnwrap(albumSnapshot)
        let filter = PhotoCollectionDescriptor.libraryFilter(UUID())
        try await repository.registerLibraryFilter(.init(descriptor: filter, snapshot: snapshot,
            referencesBySection: [[.init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1)]],
            filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            sourceCollection: .album(54)))
        try await repository.addItems([2], toAlbum: 54)
        var filterFailed = false
        for await event in await repository.page(try XCTUnwrap(albumSection), collection: filter) {
            if case .failure = event { filterFailed = true }
        }
        XCTAssertTrue(filterFailed)
        let summaries = try await repository.store.metadataAlbumSummaries(repository.metadataNamespace)
        XCTAssertEqual(summaries?.albums.first?.thumbnail?.unitID, 2)
        let address = try DayPageAddress(section: XCTUnwrap(albumSection), collection: .album(54))
        let albumPage = try await repository.store.metadataPage(address, namespace: repository.metadataNamespace, currentRun: repository.runID)
        XCTAssertEqual(albumPage?.slots.map(\.itemID), [2])
        let personalAddress = try DayPageAddress(section: descriptor, collection: .personalLibrary)
        let personal = try await repository.store.metadataPage(personalAddress, namespace: repository.metadataNamespace, currentRun: repository.runID)
        XCTAssertEqual(personal?.slots.map(\.itemID), [1])
    }

    func testAmbiguousFailureStillRefreshesMembership() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let old = AlbumSummary(id: 54, name: "Trip", itemCount: 1)
        let updated = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(2))
        await transport.configure(albumList: [old], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [updated], fails: true)
        let repository = try makeRepository(root: root, transport: transport)
        do { try await repository.addItems([2], toAlbum: 54); XCTFail("Expected failure") } catch { }
        let summaries = try await repository.store.metadataAlbumSummaries(repository.metadataNamespace)
        XCTAssertEqual(summaries?.albums.first?.thumbnail?.unitID, 2)
        let calls = await transport.albumTimelineCalls
        XCTAssertEqual(calls, [54])
    }

    func testCancelledMutationReconcilesWithoutClaimingSuccess() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let old = AlbumSummary(id: 54, name: "Trip", itemCount: 1)
        let updated = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(2))
        await transport.configure(albumList: [old], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [updated])
        await transport.pauseNextMutation()
        let repository = try makeRepository(root: root, transport: transport)
        let mutation = Task { try await repository.addItems([2], toAlbum: 54) }
        while !(await transport.mutationStarted) { await Task.yield() }
        mutation.cancel()
        await transport.releaseMutation()
        do { try await mutation.value; XCTFail("Expected cancellation") } catch { }
        let summaries = try await repository.store.metadataAlbumSummaries(repository.metadataNamespace)
        XCTAssertEqual(summaries?.albums.first?.thumbnail?.unitID, 2)
    }

    func testAdmittedOldCatalogCannotOverwriteMutation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let album = AlbumSummary(id: 54, name: "Trip", itemCount: 1)
        await transport.configure(albumList: [album], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [album])
        await transport.pauseNextCatalog()
        let repository = try makeRepository(root: root, transport: transport)
        let oldRead = Task { for await _ in await repository.timeline(collection: .album(54)) { } }
        while !(await transport.catalogStarted) { await Task.yield() }
        try await repository.addItems([2], toAlbum: 54)
        await transport.releaseCatalog()
        await oldRead.value
        let catalog = try await repository.store.metadataCatalog(CollectionKey(namespace: repository.metadataNamespace, collection: .album(54)))
        let snapshot = try CollectionDayPager.snapshot(catalog: XCTUnwrap(catalog).catalog)
        let address = try DayPageAddress(section: XCTUnwrap(snapshot.sections.first), collection: .album(54))
        let page = try await repository.store.metadataPage(address, namespace: repository.metadataNamespace, currentRun: repository.runID)
        XCTAssertEqual(page?.slots.map(\.itemID), [2])
    }

}
