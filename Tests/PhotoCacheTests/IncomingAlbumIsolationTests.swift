import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class IncomingAlbumIsolationTests: XCTestCase {
    func testIncomingIdentityRoundTripsAndDoesNotCollideWithOwnedAlbum() throws {
        let incoming = PhotoCollectionDescriptor.incomingAlbum(ownerID: 7, albumID: 42)
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: incoming.rawValue), incoming)
        XCTAssertNotEqual(incoming.rawValue, PhotoCollectionDescriptor.album(42).rawValue)
        XCTAssertNotEqual(incoming.rawValue, PhotoCollectionDescriptor.incomingAlbum(ownerID: 8, albumID: 42).rawValue)
    }

    func testScopedMetadataDoesNotOverwritePersonalOrAnotherOwner() async throws {
        let root = temporaryTestRoot("incoming-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "unused"), cacheRoot: root)
        try await repository.initializeMetadataEngine()
        let store = await repository.store
        let personal = await repository.personalMetadataNamespace
        let first = await repository.metadataNamespace(for: .incomingAlbum(ownerID: 7, albumID: 42))
        let second = await repository.metadataNamespace(for: .incomingAlbum(ownerID: 8, albumID: 42))
        func item(_ time: Int) throws -> PhotoItem {
            try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":\(time),\"type\":\"photo\"}".utf8))
        }
        for (namespace, time) in [(personal, 100), (first, 200), (second, 300)] {
            let admission = try await store.metadataAdmission(namespace)
            _ = try await store.storeMetadataDetails([item(time)], namespace: namespace, currentRun: "run", admission: admission)
        }
        let firstDetails = try await store.metadataDetails(first, ids: [1], currentRun: "run")
        let secondDetails = try await store.metadataDetails(second, ids: [1], currentRun: "run")
        let personalDetails = try await store.metadataDetails(personal, ids: [1], currentRun: "run")
        XCTAssertEqual(firstDetails[1]?.item?.time, 200)
        XCTAssertEqual(secondDetails[1]?.item?.time, 300)
        XCTAssertEqual(personalDetails[1]?.item?.time, 100)
    }
}

private actor IncomingFixtureTransport: TestPhotosTransport {
    var upload = true
    var download = true
    var downloadCalls = 0
    var writes: [[Int64]] = []
    let time: Int64 = 1711929600
    func setUpload(_ value: Bool) { upload = value }
    func setDownload(_ value: Bool) { download = value }
    func incomingAlbums() async throws -> [IncomingAlbum] {
        let payload = """
        {"id":42,"owner_user_id":7,"name":"Shared","item_count":2,"passphrase":"fixture-reference","additional":{"access_permission":{"view":true,"upload":\(upload),"download":\(download)}}}
        """
        return [try JSONDecoder().decode(IncomingAlbum.self, from: Data(payload.utf8))]
    }
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        offset == 0 ? [.init(id: 1, time: time)] : []
    }
    func readIncomingAlbumCatalogBatch(reference: String, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        guard reference == "fixture-reference" else { throw TestFailure() }
        return offset == 0 ? [.init(id: 1, time: time), .init(id: 2, time: time)] : []
    }
    func makeItem(_ name: String, id: Int = 1) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"filename\":\"\(name)\",\"time\":\(time),\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":\(id),\"cache_key\":\"fixture\"}}}".utf8))
    }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] { try ids.map { try makeItem("personal", id: Int($0)) } }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { space == .personal ? try ids.map { try makeItem("personal", id: Int($0)) } : [] }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        try fixtureBatch([makeItem("personal")], request: request, fields: fields)
    }
    func readIncomingCollectionBatch(_ request: CollectionPageRequest, reference: String, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        guard reference == "fixture-reference" else { throw TestFailure() }
        return try fixtureBatch([makeItem("shared"), makeItem("shared2", id: 2)], request: request, fields: fields)
    }
    func downloadIncomingPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, reference: String,
                                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        guard reference == "fixture-reference", itemIDs == [1] else { throw TestFailure() }
        downloadCalls += 1
        return .init(temporaryURL: URL(fileURLWithPath: "/tmp/fixture"), filename: "shared.jpg")
    }
    func addItems(_ itemIDs: [Int64], toSharedAlbumReference reference: String) async throws {
        guard reference == "fixture-reference" else { throw TestFailure() }
        writes.append(itemIDs)
    }
}

extension IncomingAlbumIsolationTests {
    func testDownloadRequiresFreshGrantAndCorrectAlbumScope() async throws {
        let root = temporaryTestRoot("incoming-download")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = IncomingFixtureTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "unused"), cacheRoot: root, transport: transport)
        let incoming = PhotoCollectionDescriptor.incomingAlbum(ownerID: 7, albumID: 42)
        _ = try await repository.downloadPhotos(itemIDs: [1], kind: .original, collection: incoming, progress: { _ in })
        await transport.setDownload(false)
        do {
            _ = try await repository.downloadPhotos(itemIDs: [1], kind: .original, collection: incoming, progress: { _ in })
            XCTFail("Revoked permission must reject the download")
        } catch { }
        do {
            _ = try await repository.downloadPhotos(itemIDs: [1], kind: .original, collection: .incomingAlbum(ownerID: 8, albumID: 42), progress: { _ in })
            XCTFail("Another owner's album must not reuse access")
        } catch { }
        let calls = await transport.downloadCalls
        XCTAssertEqual(calls, 1)
    }

    func testBrowseAndContributionRespectScopeAndFreshPermission() async throws {
        let root = temporaryTestRoot("incoming-browse")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = IncomingFixtureTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "unused"), cacheRoot: root, transport: transport)
        let incoming = PhotoCollectionDescriptor.incomingAlbum(ownerID: 7, albumID: 42)
        let owned = PhotoCollectionDescriptor.album(42)
        for await _ in await repository.incomingAlbums() { }
        let ownedTimeline = try await repository.verifiedTimelineSnapshot(collection: owned)
        let sharedTimeline = try await repository.verifiedTimelineSnapshot(collection: incoming)
        func resolve(_ collection: PhotoCollectionDescriptor, _ timeline: TimelineSnapshot) async throws -> ResolvedPhotoSelection {
            let authority = await repository.selectionAuthority(collection: collection, snapshot: timeline)
            let selection = PhotoSelectionSnapshot(collection: collection, timeline: timeline,
                timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint, selectedOrdinals: IndexSet(integer: 0),
                knownItemIDsByOrdinal: [0: 1], authority: authority)
            let receipt = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection)
            return try XCTUnwrap(receipt)
        }
        let personalSelection = try await resolve(owned, ownedTimeline)
        let incomingSelection = try await resolve(incoming, sharedTimeline)
        let sharedAuthority = await repository.selectionAuthority(collection: incoming, snapshot: sharedTimeline)
        let multiple = PhotoSelectionSnapshot(collection: incoming, timeline: sharedTimeline,
            timelineFingerprint: LibraryIndex(snapshot: sharedTimeline).fingerprint, selectedOrdinals: IndexSet(integersIn: 0..<2),
            knownItemIDsByOrdinal: [0: 1, 1: 2], authority: sharedAuthority)
        let multipleItems = await SelectionDownloadResolver(repository: repository).resolve(multiple)
        XCTAssertEqual(multipleItems?.map(\.id), [1, 2])
        XCTAssertEqual(personalSelection.items.first?.filename, "personal")
        XCTAssertEqual(incomingSelection.items.first?.filename, "shared")
        let filtered = PhotoCollectionDescriptor.libraryFilter(UUID(), scope: incoming.contentScope)
        let registration = LibraryFilterRegistration(descriptor: filtered, snapshot: sharedTimeline,
            referencesBySection: [[.init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1)]],
            filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: sharedTimeline).fingerprint,
            sourceCollection: incoming)
        let filterAuthority = try await repository.registerLibraryFilter(registration)
        let filterSelection = PhotoSelectionSnapshot(collection: filtered, timeline: sharedTimeline,
            timelineFingerprint: LibraryIndex(snapshot: sharedTimeline).fingerprint, selectedOrdinals: IndexSet(integer: 0),
            knownItemIDsByOrdinal: [0: 1], authority: filterAuthority)
        let downloadedSelection = await SelectionDownloadResolver(repository: repository).resolve(filterSelection)
        XCTAssertEqual(downloadedSelection?.first?.filename, "shared")
        let filteredReceipt = await SelectionItemResolver(repository: repository).resolveWithReceipt(filterSelection)
        let filteredShared = try XCTUnwrap(filteredReceipt)
        XCTAssertEqual(filteredShared.items.first?.filename, "shared")
        do {
            try await repository.addItems(filteredShared, toIncomingAlbum: incoming)
            XCTFail("Filtered incoming IDs cannot be contributed as personal IDs")
        } catch { }
        await transport.setUpload(false)
        do {
            try await repository.addItems(personalSelection, toIncomingAlbum: incoming)
            XCTFail("Revoked permission must reject the write")
        } catch { }
        let writesAfterRevocation = await transport.writes
        XCTAssertTrue(writesAfterRevocation.isEmpty)
        await transport.setUpload(true)
        do {
            try await repository.addItems(incomingSelection, toIncomingAlbum: incoming)
            XCTFail("Incoming IDs cannot be contributed as personal IDs")
        } catch { }
        try await repository.addItems(personalSelection, toIncomingAlbum: incoming)
        let writes = await transport.writes
        XCTAssertEqual(writes, [[1]])
    }
}
