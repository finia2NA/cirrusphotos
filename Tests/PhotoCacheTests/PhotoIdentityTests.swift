import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class PhotoIdentityTests: XCTestCase, @unchecked Sendable {
    private let scopes: [PhotoContentScope] = [
        .space(.personal), .space(.shared), .album(7),
        .incomingAlbum(ownerID: 1, albumID: 7), .incomingAlbum(ownerID: 2, albumID: 7)
    ]

    func testIdenticalIDsAndMediaRevisionsRemainIsolatedByAuthority() throws {
        XCTAssertEqual(Set(scopes.map { PhotoItemIdentity(scope: $0, itemID: 42) }).count, scopes.count)
        let thumbnail = ThumbnailInfo(unitID: 99, cacheKey: "same", sm: "ready")
        let thumbnails = scopes.map { CacheKey.thumbnailIdentity(scope: $0, namespace: "account", descriptor: thumbnail, size: .sm, collection: .library(.personal)) }
        XCTAssertEqual(Set(thumbnails.map(\.key)).count, scopes.count)
        XCTAssertEqual(Set(thumbnails.map(\.family)).count, scopes.count)
        let originals = scopes.map { CacheKey.fullImage(namespace: "account", resource: FullImageResource(scope: $0, unitID: 99, cacheKey: "same")) }
        XCTAssertEqual(Set(originals).count, scopes.count)
        let videos = scopes.map { CacheKey.videoSegment(namespace: "account", resource: VideoPlaybackResource(scope: $0, unitID: 99, cacheKey: "same", filename: nil, variant: .original), index: 0) }
        XCTAssertEqual(Set(videos).count, scopes.count)
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let section = try CollectionDayPager.snapshot(catalog: CollectionDayCatalog(days: [.init(day: day, count: 1)], completeness: .complete)).sections[0]
        let pages = scopes.map { CacheKey.page(scope: $0, namespace: "account", section: section, collection: .library(.personal)) }
        XCTAssertEqual(Set(pages).count, scopes.count)
    }

    func testCanonicalDetailsWithCollidingItemIDsDoNotOverwriteOtherSpace() async throws {
        let root = temporaryTestRoot("space-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiskCache(root: root, budget: 10_000_000)
        try await store.initializeMetadataStore()
        for scope in scopes {
            let namespace = MetadataNamespace(account: "same-account", scope: scope)
            let bytes = Data("{\"id\":42,\"time\":1704067200,\"type\":\"photo\",\"filename\":\"\(scope.cacheComponent).jpg\"}".utf8)
            let item = try JSONDecoder().decode(PhotoItem.self, from: bytes)
            let admission = try await store.metadataAdmission(namespace)
            _ = try await store.storeMetadataDetails([item], namespace: namespace, currentRun: "run", admission: admission)
        }
        for scope in scopes {
            let details = try await store.metadataDetails(MetadataNamespace(account: "same-account", scope: scope), ids: [42], currentRun: "run")
            XCTAssertEqual(details[42]?.item?.filename, "\(scope.cacheComponent).jpg")
        }
    }

    func testUnsupportedMediaScopeFailsBeforePersonalAuthenticationOrRequest() async throws {
        let client = SynologyClient(baseURL: URL(string: "https://example.invalid")!)
        for scope in scopes where scope.space == nil {
            if case .incomingAlbum = scope {
                do {
                    _ = try await client.fullImage(FullImageResource(scope: scope, unitID: 99, cacheKey: "same"))
                    XCTFail("Incoming media context must not fall through to Personal Space")
                } catch SynologyAPIError.unsupported { }
            }
            do {
                try await client.streamVideoRange(VideoPlaybackResource(scope: scope, unitID: 99, cacheKey: "same", filename: nil, variant: .original), range: 0...9, receive: { _ in })
                XCTFail("Unimplemented video context must not fall through to Personal Space")
            } catch SynologyAPIError.unsupported { }
        }
    }

    func testOriginEvidenceDoesNotReplaceExplicitItemAndUnitIdentity() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":42,\"owner_user_id\":0,\"time\":1704067200,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":99,\"cache_key\":\"r\"}}}".utf8))
        XCTAssertEqual(item.ownerUserID, 0)
        let scope = PhotoContentScope.album(7)
        XCTAssertEqual(item.identity(in: scope), PhotoItemIdentity(scope: scope, itemID: 42))
        let original = try XCTUnwrap(item.fullImageResource(in: scope))
        XCTAssertEqual(original.scope, scope)
        XCTAssertEqual(original.unitID, 99)
        let encoded = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(PhotoItem.self, from: encoded).ownerUserID, 0)
    }
}
