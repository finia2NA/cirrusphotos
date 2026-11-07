import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor OwnedAlbumThumbnailTransport: TestPhotosTransport {
    var albums: [Int64] = []
    var personalCount = 0
    var detailAlbums: [Int64] = []
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] {
        detailAlbums.append(albumID)
        return try ids.map { try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\($0),\"time\":100,\"type\":\"photo\"}".utf8)) }
    }
    func albumThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64) async throws -> Data {
        albums.append(albumID)
        return Data("album".utf8)
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace) async throws -> Data {
        personalCount += 1
        return Data("personal".utf8)
    }
}

final class OwnedAlbumThumbnailTests: XCTestCase {
    func testOwnedAlbumUsesAlbumAuthorityAndIsolatedCache() async throws {
        let root = temporaryTestRoot("OwnedAlbumThumbnails")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OwnedAlbumThumbnailTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "unused"),
            baseURL: URL(string: "https://example.invalid")!, cacheRoot: root, transport: transport)
        let descriptor = ThumbnailInfo(unitID: 10, cacheKey: "same")
        for collection in [PhotoCollectionDescriptor.library(.personal), .album(69)] {
            for await _ in await repository.thumbnail(descriptor, size: .sm, allowNetwork: true, collection: collection) {}
        }
        let albums = await transport.albums
        let personalCount = await transport.personalCount
        XCTAssertEqual(albums, [69])
        XCTAssertEqual(personalCount, 1)
        try await repository.initializeMetadataEngine()
        let items = try await repository.resolveMetadataItems([5], priority: .visible, collection: .album(69))
        XCTAssertEqual(items.map(\.id), [5])
        let detailAlbums = await transport.detailAlbums
        XCTAssertEqual(detailAlbums, [69])
    }
}
