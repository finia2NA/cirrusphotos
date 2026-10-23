import Foundation
import XCTest
import PhotoCache
import SynologyAPI
@testable import SynoTimelineApp

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
            credentials: .init(username: "load-model", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://load-model.example.invalid")!,
            cacheRoot: root,
            transport: transport
        )
        let library = LibraryModel(repository: repository)
        await library.load()
        let filter = LibraryFilterModel()
        filter.configure(library: library)
        let coordinator = TimelineSectionLoadModel()
        coordinator.configure(library: library, filter: filter)
        return (library, filter, coordinator, transport, root)
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
        XCTAssertEqual(collections, [.personalLibrary, .favorites, .album(54), .album(55)])
        XCTAssertNotNil(library.snapshot(for: .personalLibrary))
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
        XCTAssertEqual(collections, [.personalLibrary, .favorites, .album(54), .album(55)])
        _ = library
        _ = filter
    }

    func testAlbumsOverviewAndMapStillPresentAppWideCommand() async throws {
        let (library, _, model, _, root) = try await makeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAvailability()
        XCTAssertTrue(model.canPresent)
        let map = PhotoCollectionDescriptor.mapFilter(UUID())
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
            .favorites,
            snapshot: TimelineSnapshot(sections: [section(day: 19)])
        )
        let stale = await waitUntil { @MainActor in model.staleTimelineMessage != nil }
        XCTAssertTrue(stale)
        XCTAssertEqual(model.progress.state, .cancelled)
    }
}

private actor LoadModelTransport: PhotosTransport {
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

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        snapshot
    }

    func albums() async throws -> [AlbumSummary] {
        requestedAlbums += 1
        return [
            .init(id: 54, name: "Trip", itemCount: 1),
            .init(id: 55, name: "Archive", itemCount: 1),
        ]
    }

    func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot {
        requestedAlbumTimelines += 1
        return snapshot
    }

    func items(in section: TimelineSection,
               collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        requestedCollections.append(collection)
        if delay != .zero { try await Task.sleep(for: delay) }
        return [item]
    }

    func itemCollections() -> [PhotoCollectionDescriptor] { requestedCollections }
    func itemRequestCount() -> Int { requestedCollections.count }
    func albumRequestCount() -> Int { requestedAlbums }
    func albumTimelineRequestCount() -> Int { requestedAlbumTimelines }
}
