import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

/// Forwards the requests an album load makes to the real client and counts them.
private actor CountingTransport: TestPhotosTransport {
    let base: SynologyClient
    private(set) var counts: [String: Int] = [:]
    init(base: SynologyClient) { self.base = base }
    private func count(_ name: String) { counts[name, default: 0] += 1 }

    func login(credentials: SynologyCredentials) async throws { try await base.login(credentials: credentials) }
    func diffVersion(space: PhotoSpace) async throws -> DiffCursor { count("diffVersion"); return try await base.diffVersion(space: space) }
    func changes(since cursor: DiffCursor, space: PhotoSpace) async throws -> PhotoDiff {
        count("changes"); return try await base.changes(since: cursor, space: space)
    }
    func userEvents(since cursor: DiffCursor) async throws -> UserEventDiff { count("userEvents"); return try await base.userEvents(since: cursor) }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { count("items"); return try await base.items(ids: ids, space: space) }
    func albums() async throws -> [AlbumSummary] { count("albums"); return try await base.albums() }
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        count("albumCatalog"); return try await base.readAlbumCatalogBatch(albumID: albumID, offset: offset, limit: limit)
    }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] {
        count("albumItems"); return try await base.albumItems(ids: ids, albumID: albumID)
    }
    func readFolderCatalogBatch(folderID: Int64, offset: Int, limit: Int, space: PhotoSpace) async throws -> [DayTimelineEntry] {
        count("folderCatalog"); return try await base.readFolderCatalogBatch(folderID: folderID, offset: offset, limit: limit, space: space)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        count("collectionBatch"); return try await base.readCollectionBatch(request, fields: fields)
    }
}

/// Opt-in end-to-end check of the folder catalog proof. A runner passes `LIVE_FOLDER_ID`
/// for a folder that holds photos and `LIVE_FOLDER_MEMBER` for one of them.
final class LiveFolderProofTests: XCTestCase {
    func testFolderCatalogProofAgainstLiveNAS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_ALBUM_PROOF"] == "1",
              let folderID = environment["LIVE_FOLDER_ID"].flatMap(Int64.init),
              let member = environment["LIVE_FOLDER_MEMBER"].flatMap(Int64.init) else {
            throw XCTSkip("Set RUN_LIVE_ALBUM_PROOF=1 with the folder fixture IDs.")
        }
        let credentials = try CredentialStore.load()
        guard credentials.username.lowercased() == "phototest" else { throw XCTSkip("Runs only on the disposable account.") }
        let root = temporaryTestRoot("SynoLiveFolderProof")
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = PhotoCollectionDescriptor.folder(folderID, space: .personal)
        var repositories: [CachedPhotosRepository] = []

        func run(_ label: String) async throws -> [String: Int] {
            let transport = CountingTransport(base: try SynologyClient(credentials: credentials))
            let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
            repositories.append(repository)
            var sections: [TimelineSection] = []
            for await event in await repository.timeline(collection: collection) {
                if case .value(let snapshot, true) = event { sections = snapshot.sections }
                if case .failure(let error) = event { XCTFail("\(label) timeline: \(error.localizedDescription)") }
            }
            for section in sections {
                for await event in await repository.page(section, collection: collection) {
                    if case .failure(let error) = event { XCTFail("\(label) page: \(error.localizedDescription)") }
                }
            }
            let counts = await transport.counts
            print("LIVE folder \(label): \(counts.sorted { $0.key < $1.key })")
            return counts
        }

        let cold = try await run("cold")
        XCTAssertEqual(cold["folderCatalog"], 1)
        let warm = try await run("warm")
        XCTAssertNil(warm["folderCatalog"], "an untouched folder needs no catalog read")
        XCTAssertNil(warm["collectionBatch"])

        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        try await client.setRating(itemIDs: [member], rating: 4, space: .personal)
        try await Task.sleep(for: .seconds(15))
        let rated = try await run("rated")
        XCTAssertEqual(rated["folderCatalog"], 1, "a changed member's folder is read again")
    }
}

/// Opt-in end-to-end check of the album proof against the disposable account. A runner
/// creates the album and passes `LIVE_ALBUM_ID`, `LIVE_ALBUM_MEMBER` and `LIVE_ALBUM_EXTRA`.
final class LiveAlbumProofTests: XCTestCase {
    func testAlbumProofAgainstLiveNAS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_ALBUM_PROOF"] == "1",
              let albumID = environment["LIVE_ALBUM_ID"].flatMap(Int64.init),
              let member = environment["LIVE_ALBUM_MEMBER"].flatMap(Int64.init),
              let extra = environment["LIVE_ALBUM_EXTRA"].flatMap(Int64.init) else {
            throw XCTSkip("Set RUN_LIVE_ALBUM_PROOF=1 with the album fixture IDs.")
        }
        let credentials = try CredentialStore.load()
        guard credentials.username.lowercased() == "phototest" else { throw XCTSkip("Runs only on the disposable account.") }
        let root = temporaryTestRoot("SynoLiveAlbumProof")
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = PhotoCollectionDescriptor.album(albumID)
        var repositories: [CachedPhotosRepository] = []

        func run(_ label: String) async throws -> (counts: [String: Int], ids: [Int64]) {
            let transport = CountingTransport(base: try SynologyClient(credentials: credentials))
            let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
            repositories.append(repository)
            for await _ in await repository.albums() {}
            var sections: [TimelineSection] = []
            for await event in await repository.timeline(collection: collection) {
                if case .value(let snapshot, true) = event { sections = snapshot.sections }
                if case .failure(let error) = event { XCTFail("\(label) timeline: \(error.localizedDescription)") }
            }
            var ids: [Int64] = []
            for section in sections {
                for await event in await repository.page(section, collection: collection) {
                    if case .value(let page, true) = event { ids += (page.completeItems ?? []).map(\.id) }
                    if case .failure(let error) = event { XCTFail("\(label) page: \(error.localizedDescription)") }
                }
            }
            let counts = await transport.counts
            print("LIVE \(label): \(counts.sorted { $0.key < $1.key }) ids=\(ids.sorted())")
            return (counts, ids)
        }

        let cold = try await run("cold")
        XCTAssertEqual(cold.counts["albumCatalog"], 1)

        let warm = try await run("warm")
        XCTAssertNil(warm.counts["albumCatalog"], "an unchanged album needs no catalog read")
        XCTAssertNil(warm.counts["albumItems"], "its copies are proven by the Personal feed")
        XCTAssertNil(warm.counts["collectionBatch"])
        XCTAssertEqual(warm.ids.sorted(), cold.ids.sorted())

        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        try await client.setRating(itemIDs: [member], rating: 3, space: .personal)
        try await Task.sleep(for: .seconds(15))
        let rated = try await run("rated")
        XCTAssertNil(rated.counts["albumCatalog"], "a rating leaves the album version unchanged")
        XCTAssertGreaterThanOrEqual((rated.counts["albumItems"] ?? 0) + (rated.counts["collectionBatch"] ?? 0), 1,
                                    "the rated member's album copy is read again")

        try await client.addItems([extra], toAlbum: albumID)
        try await Task.sleep(for: .seconds(15))
        let added = try await run("added")
        XCTAssertEqual(added.counts["albumCatalog"], 1, "a new member changes the album version")
        XCTAssertTrue(added.ids.contains(extra))
    }
}
