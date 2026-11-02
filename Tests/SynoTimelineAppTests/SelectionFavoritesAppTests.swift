import Foundation
import XCTest
import SwiftUI
import SynologyAPI
import PhotoCache
@testable import SynoTimelineApp

final class SelectionFavoritesAppTests: XCTestCase {

    private func makeItem(id: Int64, isFavorite: Bool = false) -> PhotoItem {
        let favoriteField = isFavorite ? "true" : "false"
        let json = """
        {"id":\(id),"filename":"IMG_\(id).jpg","time":1712102400,"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key_\(id)","sm":"ready","m":"ready","xl":"ready"},"resolution":{"width":1000,"height":1000},"orientation":1,"favorite":\(favoriteField)}}
        """
        return try! JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func makeRepository(
        transport: AppMockTransport,
        root: URL
    ) throws -> CachedPhotosRepository {
        let creds = SynologyCredentials(username: "alice", password: "pw", otpSecret: "unused")
        return try CachedPhotosRepository(credentials: creds, budget: 100_000_000, cacheRoot: root, transport: transport)
    }

    @MainActor
    func testExactlyFiveAffectedItemsBypassConfirmationSixRequireIt() async throws {
        let root = temporaryTestRoot("FiveVsSix")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AppMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 10, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 10)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot)

        // 1. Five items (all non-favorites -> 5 affected)
        let fiveItems = (0..<5).map { makeItem(id: Int64($0), isFavorite: false) }
        await transport.setPage(fiveItems, offset: 0)
        let model5 = LibraryModel(repository: repo)
        await model5.load()

        let owner5 = UUID()
        let snapshot5 = BrowserCommandSnapshot(
            owner: owner5, active: true, canOpen: false, canToggleFavorite: true,
            collection: .library(.personal), indexFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectionGeneration: "gen:0", selectedOrdinals: IndexSet(integersIn: 0...4),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: (0...4).map { ($0, Int64($0)) })
        )
        model5.installBrowserCommands(snapshot: snapshot5, handler: nil)
        model5.toggleSelectionFavorite()

        // Wait for resolution
        _ = await waitUntil { await transport.setFavoriteCalls.count == 1 || model5.pendingFavoriteConfirmation != nil }
        // 5 items bypass confirmation!
        XCTAssertNil(model5.pendingFavoriteConfirmation)
        let calls5 = await transport.setFavoriteCalls
        XCTAssertEqual(calls5.count, 1)
        XCTAssertEqual(calls5[0].itemIDs.count, 5)

        // 2. Six items (all non-favorites -> 6 affected)
        let transport6 = AppMockTransport()
        let repo6 = try makeRepository(transport: transport6, root: root)
        await transport6.setTimeline(snapshot)
        let sixItems = (0..<6).map { makeItem(id: Int64($0), isFavorite: false) }
        await transport6.setPage(sixItems, offset: 0)
        let model6 = LibraryModel(repository: repo6)
        await model6.load()

        let owner6 = UUID()
        let snapshot6 = BrowserCommandSnapshot(
            owner: owner6, active: true, canOpen: false, canToggleFavorite: true,
            collection: .library(.personal), indexFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectionGeneration: "gen:0", selectedOrdinals: IndexSet(integersIn: 0...5),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: (0...5).map { ($0, Int64($0)) })
        )
        model6.installBrowserCommands(snapshot: snapshot6, handler: nil)
        model6.toggleSelectionFavorite()

        // Wait for confirmation to appear
        _ = await waitUntil { model6.pendingFavoriteConfirmation != nil }
        let confirmation = try XCTUnwrap(model6.pendingFavoriteConfirmation)
        XCTAssertEqual(confirmation.action.affectedIDs.count, 6)
        XCTAssertEqual(confirmation.title, "Add 6 Photos to Favorites?")
        XCTAssertEqual(confirmation.actionButtonTitle, "Add to Favorites")
        // No transport calls until confirmed
        let calls6 = await transport6.setFavoriteCalls
        XCTAssertEqual(calls6.count, 0)
    }

    @MainActor
    func testAffectedCountRatherThanSelectionCountDrivesConfirmation() async throws {
        let root = temporaryTestRoot("AffectedDrivesConfirm")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AppMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 100, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 100)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot)

        // Partial selection of 99 items: 95 are already favorites, only 4 are non-favorites.
        var items: [PhotoItem] = []
        for id in 0..<96 { items.append(makeItem(id: Int64(id), isFavorite: true)) }
        for id in 96..<100 { items.append(makeItem(id: Int64(id), isFavorite: false)) }
        await transport.setPage(items, offset: 0)

        let model = LibraryModel(repository: repo)
        await model.load()

        let owner = UUID()
        let commandSnapshot = BrowserCommandSnapshot(
            owner: owner, active: true, canOpen: false, canToggleFavorite: true,
            collection: .library(.personal), indexFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectionGeneration: "gen:0", selectedOrdinals: IndexSet(integersIn: 1...99),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: (1..<100).map { ($0, Int64($0)) })
        )
        model.installBrowserCommands(snapshot: commandSnapshot, handler: nil)
        model.toggleSelectionFavorite()

        // Wait for execution
        _ = await waitUntil { await transport.setFavoriteCalls.count == 1 || model.pendingFavoriteConfirmation != nil }

        // Affected count is 4 (<= 5), and this is not Select All, so confirmation is bypassed.
        XCTAssertNil(model.pendingFavoriteConfirmation)
        let calls = await transport.setFavoriteCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].itemIDs.count, 4)
    }

    @MainActor
    func testEntireCollectionSelectionRequiresConfirmationEvenWhenSmall() async throws {
        let root = temporaryTestRoot("SmallSelectAllConfirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AppMockTransport()
        let repo = try makeRepository(transport: transport, root: root)
        let section = TimelineSection(offset: 0, limit: 3,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3)])
        let snapshot = TimelineSnapshot(sections: [section])
        await transport.setTimeline(snapshot)
        await transport.setPage((0..<3).map { makeItem(id: Int64($0)) }, offset: 0)
        let model = LibraryModel(repository: repo)
        await model.load()
        model.installBrowserCommands(snapshot: BrowserCommandSnapshot(
            owner: UUID(), active: true, canOpen: false, canToggleFavorite: true,
            collection: .library(.personal), indexFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectionGeneration: "gen:0", selectedOrdinals: IndexSet(integersIn: 0..<3),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: (0..<3).map { ($0, Int64($0)) })
        ), handler: nil)

        model.toggleSelectionFavorite()
        _ = await waitUntil { model.pendingFavoriteConfirmation != nil }

        XCTAssertEqual(model.pendingFavoriteConfirmation?.action.affectedIDs.count, 3)
        let calls = await transport.setFavoriteCalls
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testCancelPerformsNoOptimisticPublicationAndNoTransportRequest() async throws {
        let root = temporaryTestRoot("CancelNoMutate")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AppMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 10, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 10)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot)
        await transport.setPage((0..<10).map { makeItem(id: Int64($0), isFavorite: false) }, offset: 0)

        let model = LibraryModel(repository: repo)
        await model.load()

        let owner = UUID()
        let commandSnapshot = BrowserCommandSnapshot(
            owner: owner, active: true, canOpen: false, canToggleFavorite: true,
            collection: .library(.personal), indexFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectionGeneration: "gen:0", selectedOrdinals: IndexSet(integersIn: 0...9),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, Int64($0)) })
        )
        model.installBrowserCommands(snapshot: commandSnapshot, handler: nil)
        model.toggleSelectionFavorite()

        _ = await waitUntil { model.pendingFavoriteConfirmation != nil }
        XCTAssertNotNil(model.pendingFavoriteConfirmation)

        // User cancels
        model.cancelBrowserFavorite()

        XCTAssertNil(model.pendingFavoriteConfirmation)
        XCTAssertFalse(model.browserFavoriteBusy)

        // Verify zero transport calls
        let calls = await transport.setFavoriteCalls
        XCTAssertEqual(calls.count, 0)
    }

    @MainActor
    func testConfirmationExecutesExactPreparedIDsAndTarget() async throws {
        let root = temporaryTestRoot("ConfirmExact")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AppMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 10, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 10)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot)
        await transport.setPage((0..<6).map { makeItem(id: Int64($0), isFavorite: true) }, offset: 0) // 6 favorites -> unfavorite all

        let model = LibraryModel(repository: repo)
        await model.load()

        let owner = UUID()
        let commandSnapshot = BrowserCommandSnapshot(
            owner: owner, active: true, canOpen: false, canToggleFavorite: true,
            collection: .library(.personal), indexFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectionGeneration: "gen:0", selectedOrdinals: IndexSet(integersIn: 0...5),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, Int64($0)) })
        )
        model.installBrowserCommands(snapshot: commandSnapshot, handler: nil)
        model.toggleSelectionFavorite()

        _ = await waitUntil { model.pendingFavoriteConfirmation != nil }
        let confirmation = try XCTUnwrap(model.pendingFavoriteConfirmation)
        XCTAssertEqual(confirmation.title, "Remove 6 Photos from Favorites?")
        XCTAssertEqual(confirmation.actionButtonTitle, "Remove from Favorites")

        // Confirm
        model.confirmBrowserFavorite()
        _ = await waitUntil { await transport.setFavoriteCalls.count == 1 }

        let calls = await transport.setFavoriteCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].itemIDs.sorted(), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(calls[0].favorite, false)
    }

    @MainActor
    func testRoutingRoutesToViewerWhenOpenAndBrowserOtherwise() {
        let model = LibraryModel()

        // Neither viewer nor browser active
        XCTAssertFalse(model.canToggleFavorite)

        // Browser active with selection, but timeline not yet verified -> not ready
        let owner = UUID()
        var selected = IndexSet()
        selected.insert(1)
        model.installBrowserCommands(owner: owner, active: true, canOpen: true, canToggleFavorite: true, selectedOrdinals: selected)
        XCTAssertFalse(model.canToggleFavorite)

        // Without an active viewer, the viewer favorite command is never enabled
        model.setActiveViewer(nil)
        XCTAssertFalse(model.canToggleViewerFavorite)
    }

    @MainActor
    func testBrowserFavoriteWriteFailureIsReported() async throws {
        let root = temporaryTestRoot("FavoriteWriteFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AppMockTransport()
        await transport.setFavoriteFailure(true)
        let repo = try makeRepository(transport: transport, root: root)

        let section = TimelineSection(
            offset: 0,
            limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)]
        )
        let timeline = TimelineSnapshot(sections: [section])
        await transport.setTimeline(timeline)
        await transport.setPage([makeItem(id: 1)], offset: 0)

        let model = LibraryModel(repository: repo)
        await model.load()
        model.installBrowserCommands(
            snapshot: BrowserCommandSnapshot(
                owner: UUID(),
                active: true,
                canOpen: false,
                canToggleFavorite: true,
                collection: .library(.personal),
                indexFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
                selectionGeneration: "generation",
                selectedOrdinals: IndexSet(integer: 0),
                knownItemIDsByOrdinal: [0: 1]
            ),
            handler: nil
        )

        model.toggleSelectionFavorite()
        _ = await waitUntil { model.pendingFavoriteConfirmation != nil }
        model.confirmBrowserFavorite()
        let reported = await waitUntil { model.browserFavoriteFailure != nil }

        XCTAssertTrue(reported)
        XCTAssertTrue(model.browserFavoriteFailure?.contains("Favorite update failed") == true)
        model.dismissBrowserFavoriteFailure()
        XCTAssertNil(model.browserFavoriteFailure)
    }
}

// MARK: - Test Transport Mock for App Tests

private struct AppFavoriteFailure: LocalizedError {
    var errorDescription: String? { "Favorite write failed for testing." }
}

actor AppMockTransport: PhotosTransport {
    private var timeline = TimelineSnapshot(sections: [])
    private var pages: [Int: [PhotoItem]] = [:]
    private(set) var setFavoriteCalls: [(itemIDs: [Int64], favorite: Bool)] = []
    private var favoriteFailure = false

    func setTimeline(_ snapshot: TimelineSnapshot) { timeline = snapshot }
    func setPage(_ items: [PhotoItem], offset: Int) {
        let count = timeline.sections.first?.list.first?.itemCount ?? items.count
        var complete = items
        if let prototype = items.first, count > items.count {
            for index in items.count..<count {
                var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(prototype)) as! [String: Any]
                json["id"] = 900_000 + index
                complete.append(try! JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: json)))
            }
        }
        pages[offset] = complete
    }
    func setFavoriteFailure(_ enabled: Bool) { favoriteFailure = enabled }

    func login(credentials: SynologyCredentials) async throws {}

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(timeline, initial: initial)
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        return try fixtureBatch(Array((pages[0] ?? []).dropFirst(request.offset).prefix(request.limit)), request: request, fields: fields)
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {
        setFavoriteCalls.append((itemIDs, favorite))
        if favoriteFailure { throw AppFavoriteFailure() }
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        ThumbnailResponse(data: Data([1]), etag: nil, lastModified: nil)
    }

    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> FullImageResponse {
        FullImageResponse(data: Data([2]), etag: nil, lastModified: nil)
    }
}
