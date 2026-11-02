import Foundation
import XCTest
@testable import SynologyAPI
@testable import PhotoCache

private actor UploadRefreshTransport: TestPhotosTransport {
    var catalogCalls = 0
    var shouldFail = false
    func setFailure(_ value: Bool) { shouldFail = value }
    func login(credentials: SynologyCredentials) async throws {}
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        catalogCalls += 1
        return try CollectionDayCatalog(days: [], completeness: .complete)
    }
    func uploadPhoto(at url: URL, destination: PhotoUploadDestination, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult {
        if shouldFail { throw SynologyAPIError.transport("uncertain fixture") }
        return try JSONDecoder().decode(PhotoUploadResult.self, from: Data(#"{"action":"new","id":1,"unit_id":2}"#.utf8))
    }
    func calls() -> Int { catalogCalls }
}

private actor AlbumUploadTransport: TestPhotosTransport {
    var uploads = 0
    var owner: Int64 = 1
    var albumReads = 0
    func setOwner(_ value: Int64) { owner = value }
    func login(credentials: SynologyCredentials) async throws {}
    func diffVersion() async throws -> DiffCursor { .init(diffVersion: 1, versionTime: 1) }
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff { .init(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: []) }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: [], completeness: .complete)
    }
    func currentPhotosUserID() async throws -> Int64 { 1 }
    func album(id: Int64) async throws -> AlbumSummary { albumReads += 1; return AlbumSummary(id: id, name: "Fixture", itemCount: 0, type: "normal", ownerUserID: owner) }
    func albums() async throws -> [AlbumSummary] { [AlbumSummary(id: 77, name: "Fixture", itemCount: 0, type: "normal", ownerUserID: owner)] }
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] { [] }
    func uploadPhoto(at url: URL, destination: PhotoUploadDestination, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult {
        uploads += 1
        return try JSONDecoder().decode(PhotoUploadResult.self, from: Data(#"{"action":"ignore","id":1,"unit_id":2}"#.utf8))
    }
    func counts() -> (Int, Int) { (uploads, albumReads) }
}

final class PhotoUploadRefreshTests: XCTestCase, @unchecked Sendable {
    func testAlbumUploadVerifiesOwnershipAndRefreshesAlbum() async throws {
        let root = temporaryTestRoot("upload-album")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumUploadTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "fixture"), cacheRoot: root, transport: transport)
        let result = try await repository.uploadPhoto(at: URL(fileURLWithPath: "/fixture.png"), destination: .album(77), progress: { _ in })
        XCTAssertEqual(result.action, "ignore")
        let (uploads, reads) = await transport.counts()
        XCTAssertEqual(uploads, 1)
        XCTAssertGreaterThanOrEqual(reads, 2)
        await transport.setOwner(2)
        do {
            _ = try await repository.uploadPhoto(at: URL(fileURLWithPath: "/fixture.png"), destination: .album(77), progress: { _ in })
            XCTFail("Expected ownership rejection")
        } catch { }
        let (after, _) = await transport.counts()
        XCTAssertEqual(after, 1)
    }
    func testSuccessAndUncertainFailureBothRefreshTheSharedLibrary() async throws {
        let root = temporaryTestRoot("upload-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = UploadRefreshTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "fixture"), cacheRoot: root, transport: transport)
        _ = try await repository.verifiedTimelineSnapshot(collection: .library(.shared))
        let before = await transport.calls()
        _ = try await repository.uploadPhoto(at: URL(fileURLWithPath: "/fixture.png"), destination: .timeline(.shared), progress: { _ in })
        let after = await transport.calls()
        XCTAssertGreaterThan(after, before)
        await transport.setFailure(true)
        do {
            _ = try await repository.uploadPhoto(at: URL(fileURLWithPath: "/fixture.png"), destination: .timeline(.shared), progress: { _ in })
            XCTFail("Expected uncertain upload failure")
        } catch { }
        let afterFailure = await transport.calls()
        XCTAssertGreaterThan(afterFailure, after)
    }
}
