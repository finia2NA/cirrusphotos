import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class MixedAlbumAuthorityTests: XCTestCase {
    private func item(_ revision: String, owner: Int = 0, id: Int = 5) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"owner_user_id\":\(owner),\"time\":1704067200,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":9,\"cache_key\":\"\(revision)\"}}}".utf8))
    }

    func testOwnerZeroAloneDoesNotEstablishOrigin() throws {
        let member = try item("album")
        let collision = try item("other")
        XCTAssertEqual(try CachedPhotosRepository.uniqueAlbumItemSpace([member], candidates: [.personal: [member], .shared: [collision]]), .personal)
        XCTAssertEqual(try CachedPhotosRepository.uniqueAlbumItemSpace([member], candidates: [.personal: [collision], .shared: [member]]), .shared)
        XCTAssertThrowsError(try CachedPhotosRepository.uniqueAlbumItemSpace([member], candidates: [.personal: [member], .shared: [member]]))
        XCTAssertThrowsError(try CachedPhotosRepository.uniqueAlbumItemSpace([member], candidates: [.personal: [], .shared: [collision]]))
    }

    func testMixedSpaceActionCannotCollapseIdentitiesIntoOneWrite() throws {
        let personal = try item("personal", owner: 11)
        let shared = try item("shared", id: 6)
        XCTAssertThrowsError(try CachedPhotosRepository.uniqueAlbumItemSpace([personal, shared], candidates: [.personal: [personal], .shared: [shared]]))
    }
}

private actor RestrictedAlbumTransport: TestPhotosTransport {
    let member: PhotoItem
    var writes = 0
    init(member: PhotoItem) { self.member = member }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] { [member] }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        guard space == .personal else { throw SynologyAPIError.api(105) }
        return [member]
    }
    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws { writes += 1 }
}

extension MixedAlbumAuthorityTests {
    func testRestrictedOtherSpaceDoesNotAuthorizePersonalWriteOrPoisonCanonicalDetails() async throws {
        let member = try item("album", owner: 11)
        let root = temporaryTestRoot("restricted-album-origin")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RestrictedAlbumTransport(member: member)
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "fixture"), cacheRoot: root, transport: transport)
        let section = TimelineSection(offset: 0, limit: 1, list: [.init(year: 2024, month: 1, day: 1, itemCount: 1)])
        do {
            try await repository.setFavoritesBatch(action: .init(affectedIDs: [member.id], targetFavorite: true, sectionsByID: [member.id: section], collection: .album(3), itemsByID: [member.id: member]))
            XCTFail("An inaccessible domain must not be interpreted as an empty domain")
        } catch SynologyAPIError.api(105) { }
        let writes = await transport.writes
        XCTAssertEqual(writes, 0)
        let namespace = await repository.personalMetadataNamespace
        let details = try await repository.store.metadataDetails(namespace, ids: [member.id], currentRun: repository.runID)
        XCTAssertNil(details[member.id]?.item)
        let albumNamespace = await repository.metadataNamespace(for: .album(3))
        XCTAssertEqual(albumNamespace.scope, .album(3))
    }
}
