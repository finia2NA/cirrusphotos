import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor IncomingThumbnailTransport: PhotosTransport {
    var personalRequests = 0
    var references: [String] = []

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        personalRequests += 1
        return ThumbnailResponse(data: Data("personal".utf8), etag: nil, lastModified: nil)
    }

    func incomingThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, reference: String,
                           etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        references.append(reference)
        return ThumbnailResponse(data: Data(reference.utf8), etag: nil, lastModified: nil)
    }
}

private extension CachedPhotosRepository {
    func installIncoming(_ album: IncomingAlbum, for collection: PhotoCollectionDescriptor) {
        incomingAccess[collection] = album
    }
}

final class IncomingThumbnailTests: XCTestCase {
    func testIncomingThumbnailsAreIsolatedAndRequireAccess() async throws {
        let root = temporaryTestRoot("IncomingThumbnails")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = IncomingThumbnailTransport()
        let credentials = SynologyCredentials(username: "test", password: "unused")
        let server = URL(string: "https://example.invalid")!
        let repository = try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                                     cacheRoot: root, transport: transport)
        let descriptor = ThumbnailInfo(unitID: 10, cacheKey: "same")
        let first = PhotoCollectionDescriptor.incomingAlbum(ownerID: 1, albumID: 2)
        let second = PhotoCollectionDescriptor.incomingAlbum(ownerID: 3, albumID: 2)
        let album = try JSONDecoder().decode(IncomingAlbum.self, from: Data(#"{"id":2,"name":"Shared","item_count":1,"passphrase":"session-reference","additional":{"access_permission":{"view":true}}}"#.utf8))
        await repository.installIncoming(album, for: first)

        var firstValues: [Data] = []
        for await event in await repository.thumbnail(descriptor, size: .sm, allowNetwork: true, collection: first) {
            if case .value(let data, _) = event { firstValues.append(data) }
        }
        XCTAssertEqual(firstValues, [Data("session-reference".utf8)])
        var secondValues: [Data] = []
        for await event in await repository.thumbnail(descriptor, size: .sm, allowNetwork: true, collection: second) {
            if case .value(let data, _) = event { secondValues.append(data) }
        }
        XCTAssertTrue(secondValues.isEmpty)
        let references = await transport.references
        let personalRequests = await transport.personalRequests
        XCTAssertEqual(references, ["session-reference"])
        XCTAssertEqual(personalRequests, 0)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        XCTAssertNotEqual(CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: .sm, collection: first),
                          CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: .sm, collection: second))
        XCTAssertNotEqual(CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: .sm, collection: first),
                          CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: .sm))
    }
}
