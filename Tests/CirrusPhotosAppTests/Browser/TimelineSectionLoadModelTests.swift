import Foundation
import XCTest
import PhotoCache
import SynologyAPI
@testable import CirrusPhotosApp

@MainActor
final class TimelineSectionLoadModelTests: XCTestCase {
    private func section(day: Int = 20) -> TimelineSection {
        .init(offset: 0, limit: 1,
              list: [.init(year: 2025, month: 1, day: day, itemCount: 1)])
    }

    private func item(camera: String = "Bulk Camera") throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":7,"filename":"7.JPG","time":1737331200,"type":"photo",
         "additional":{"exif":{"camera":"\(camera)"}}}
        """.utf8))
    }

    private func makeModels(delay: Duration = .zero) async throws
        -> (LibraryModel, LibraryFilterModel, TimelineSectionLoadModel, LoadModelTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineSectionLoadModel-\(UUID().uuidString)")
        let snapshot = TimelineSnapshot(sections: [section()])
        let transport = LoadModelTransport(snapshot: snapshot, item: try item(), delay: delay)
        let repository = try CachedPhotosRepository(
            credentials: .init(username: "load-model", password: "unused"),
            baseURL: URL(string: "https://load-model.example.invalid")!,
            cacheRoot: root,
            transport: transport
        )
        let library = LibraryModel(repository: repository)
        await library.load()
        let filter = LibraryFilterModel()
        filter.configure(library: library, source: .library(.personal))
        let coordinator = TimelineSectionLoadModel()
        coordinator.configure(library: library, filter: filter)
        return (library, filter, coordinator, transport, root)
    }

    /// The shell configures both models in `onAppear`, before `load()` opens the
    /// repository; they must notice the repository and verified timelines on their own.
    func testModelsConfiguredBeforeLoadStartSyncAndBecomeAvailable() async throws {
        let root = temporaryTestRoot("TimelineSectionLoadModel")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LoadModelTransport(snapshot: TimelineSnapshot(sections: [section()]), item: try item(), delay: .zero)
        let session = AppSession(preferences: AppPreferences()) { _ in
            try CachedPhotosRepository(
                credentials: .init(username: "load-model", password: "unused"),
                baseURL: URL(string: "https://load-model.example.invalid")!,
                cacheRoot: root,
                transport: transport
            )
        }
        let library = LibraryModel(session: session)
        XCTAssertNil(library.repository)
        let filter = LibraryFilterModel()
        filter.configure(library: library, source: .library(.personal))
        let load = TimelineSectionLoadModel()
        load.configure(library: library, filter: filter)
        let sync = MetadataSyncModel()
        sync.configure(library: library)
        sync.setFocus(.library(.personal))
        XCTAssertFalse(load.canPresent)

        await library.load()
        let available = await waitUntil { @MainActor in load.canPresent }
        let syncing = await waitUntil { @MainActor in sync.collections[.library(.personal)] != nil }
        XCTAssertTrue(available)
        XCTAssertTrue(syncing)
    }

    func testMetadataSyncShowsAnActivityEntryOnlyWhileRunning() async throws {
        let root = temporaryTestRoot("TimelineSectionLoadModel")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LoadModelTransport(snapshot: TimelineSnapshot(sections: [section()]), item: try item(),
                                           delay: .milliseconds(200))
        let session = AppSession(preferences: AppPreferences()) { _ in
            try CachedPhotosRepository(
                credentials: .init(username: "load-model", password: "unused"),
                baseURL: URL(string: "https://load-model.example.invalid")!,
                cacheRoot: root,
                transport: transport
            )
        }
        let library = LibraryModel(session: session)
        let sync = MetadataSyncModel()
        sync.configure(library: library)
        await library.load()

        let syncEntry = { @MainActor in library.activity.entries.first { $0.kind == .metadataSync } }
        let appeared = await waitUntil(attempts: 2_000) { @MainActor in syncEntry() != nil }
        XCTAssertTrue(appeared)
        let entry = try XCTUnwrap(syncEntry())
        XCTAssertFalse(entry.phase.isSettled, "a running entry has no dismiss button")
        XCTAssertNil(entry.cancel)
        XCTAssertTrue(library.activity.inProgress.contains { $0.id == entry.id })

        // The pass either finishes or waits to retry; the entry goes away in both cases.
        let ended = await waitUntil(attempts: 4_000) { @MainActor in
            !sync.progress.running && syncEntry() == nil
        }
        XCTAssertTrue(ended)
        XCTAssertFalse(library.activity.history.contains { $0.kind == .metadataSync })
    }

    func testAppWideRunLoadsLibraryFavoritesAndEveryAlbumAndUpdatesFilterThroughRepository() async throws {
        let (library, filter, model, transport, root) = try await makeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAvailability()
        XCTAssertTrue(model.canPresent)
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(model.targetTitle, "Personal Library, Favorites, and All Albums")

        model.start(useCachedPages: false)
        let finished = await waitUntil { @MainActor in model.progress.state == .finished }
        let ingested = await waitUntil { @MainActor in filter.catalog.cameras == ["Bulk Camera"] }
        XCTAssertTrue(finished)
        XCTAssertTrue(ingested)
        let collections = await transport.itemCollections()
        XCTAssertEqual(collections, [.library(.personal), .favorites(.personal), .album(54), .album(55)])
        XCTAssertNotNil(library.snapshot(for: .library(.personal)))
    }

    func testSharedMapMetadataFilterRetainsSharedActionAvailability() {
        let library = LibraryModel()
        let snapshot = TimelineSnapshot(sections: [section()])
        let map = PhotoCollectionDescriptor.mapFilter(UUID(), space: .personal)
        let filter = PhotoCollectionDescriptor.libraryFilter(UUID(), scope: .space(.personal))
        library.registerSessionCollection(map, snapshot: snapshot, source: .library(.shared))
        library.registerSessionCollection(filter, snapshot: snapshot, source: map)
        XCTAssertTrue(library.capabilities(for: filter).isShared)
        XCTAssertFalse(library.capabilities(for: filter).allowsPersonalActions)
        XCTAssertTrue(library.capabilities(for: filter).allowsSpaceItemActions)
    }

    func testSharedInclusionWarmsBothSharedCollectionsAndPreservesPersonalAndAlbums() async throws {
        let (library, filter, model, transport, root) = try await makeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(model.prepare())
        model.start(useCachedPages: false, includeSharedSpace: true)
        let finished = await waitUntil { @MainActor in model.progress.state == .finished }
        XCTAssertTrue(finished)
        let collections = await transport.itemCollections()
        XCTAssertEqual(Set(collections), [.library(.personal), .favorites(.personal), .library(.shared), .favorites(.shared), .album(54), .album(55)])
        _ = library
        _ = filter
    }

    func testCurrentDestinationDoesNotChangeAppWideScope() async throws {
        let (library, filter, model, transport, root) = try await makeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAvailability()
        XCTAssertTrue(model.prepare())
        model.refreshAvailability()
        XCTAssertEqual(model.targetTitle, "Personal Library, Favorites, and All Albums")
        model.start(useCachedPages: false)
        let finished = await waitUntil { @MainActor in model.progress.state == .finished }
        XCTAssertTrue(finished)

        let collections = await transport.itemCollections()
        XCTAssertEqual(collections, [.library(.personal), .favorites(.personal), .album(54), .album(55)])
        _ = library
        _ = filter
    }

    func testAlbumsOverviewAndMapStillPresentAppWideCommand() async throws {
        let (library, _, model, _, root) = try await makeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAvailability()
        XCTAssertTrue(model.canPresent)
        let map = PhotoCollectionDescriptor.mapFilter(UUID(), space: .personal)
        library.registerSessionCollection(map, snapshot: TimelineSnapshot(sections: [section()]))
        model.refreshAvailability()
        XCTAssertTrue(model.canPresent)
    }

    func testPreparingTargetDoesNotStartPageLoading() async throws {
        let (library, filter, model, transport, root) = try await makeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAvailability()
        XCTAssertTrue(model.prepare())

        try await Task.sleep(for: .milliseconds(100))
        let requests = await transport.itemRequestCount()
        let albumRequests = await transport.albumRequestCount()
        let albumTimelineRequests = await transport.albumTimelineRequestCount()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(albumRequests, 0)
        XCTAssertEqual(albumTimelineRequests, 0)
        XCTAssertEqual(model.progress.state, .idle)
        XCTAssertEqual(model.progress.processed, 0)
        _ = library
        _ = filter
    }

    func testFavoritesRevisionChangeCancelsActiveCapturedGeometry() async throws {
        let (library, _, model, transport, root) = try await makeModels(delay: .seconds(1))
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAvailability()
        XCTAssertTrue(model.prepare())
        model.start(useCachedPages: false)
        let admitted = await waitUntil { await transport.itemRequestCount() == 1 }
        XCTAssertTrue(admitted)

        library.registerSessionCollection(
            .favorites(.personal),
            snapshot: TimelineSnapshot(sections: [section(day: 19)])
        )
        let stale = await waitUntil { @MainActor in model.staleTimelineMessage != nil }
        XCTAssertTrue(stale)
        XCTAssertEqual(model.progress.state, .cancelled)
    }
}

private actor LoadModelTransport: TestPhotosTransport {
    let snapshot: TimelineSnapshot
    let item: PhotoItem
    let delay: Duration
    private var requestedCollections: [PhotoCollectionDescriptor] = []
    private var requestedAlbums = 0
    private var requestedAlbumTimelines = 0

    init(snapshot: TimelineSnapshot, item: PhotoItem, delay: Duration) {
        self.snapshot = snapshot
        self.item = item
        self.delay = delay
    }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(snapshot, initial: initial)
    }

    func albums() async throws -> [AlbumSummary] {
        requestedAlbums += 1
        return [
            .init(id: 54, name: "Trip", itemCount: 1),
            .init(id: 55, name: "Archive", itemCount: 1),
        ]
    }

    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        requestedAlbumTimelines += 1
        return offset == 0 ? [DayTimelineEntry(id: item.id, time: item.time)] : []
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let collection = request.collection

        requestedCollections.append(collection)
        if delay != .zero { try await Task.sleep(for: delay) }
        return try fixtureBatch([item], request: request, fields: fields)
    }

    func itemCollections() -> [PhotoCollectionDescriptor] { requestedCollections }
    func itemRequestCount() -> Int { requestedCollections.count }
    func albumRequestCount() -> Int { requestedAlbums }
    func albumTimelineRequestCount() -> Int { requestedAlbumTimelines }
}
