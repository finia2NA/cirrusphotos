import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor PeopleCacheTransport: TestPhotosTransport {
    var offline = false
    var calls = 0
    func setOffline() { offline = true }
    func collectionIndex(_ kind: CollectionIndexKind, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        guard kind == .person else { throw UnexpectedTransportCall("collectionIndex") }
        calls += 1
        if offline { throw TestFailure("Offline") }
        return [try CollectionIndexEntry.decoder(for: .person).decode(CollectionIndexEntry.self, from: Data(#"{"id":123,"name":"A","item_count":4,"additional":{"thumbnail":{"cache_key":"face"}}}"#.utf8))]
    }
}

final class PeopleCacheTests: XCTestCase {
    func testCachedIndexSurvivesFailedRefreshAndValidatesOncePerRun() async throws {
        let root = temporaryTestRoot("people-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PeopleCacheTransport()
        let credentials = SynologyCredentials(username: "fixture", password: "fixture")
        let first = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        var verified = false
        for await event in await first.collectionIndex(.person, space: .personal) { if case .value(let list, true) = event { verified = list.map(\.id) == [123] } }
        XCTAssertTrue(verified)
        for await _ in await first.collectionIndex(.person, space: .personal) {}
        let count = await transport.calls
        XCTAssertEqual(count, 1)
        let offline = PeopleCacheTransport()
        await offline.setOffline()
        let second = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: offline)
        var cached = false; var failed = false
        for await event in await second.collectionIndex(.person, space: .personal) {
            switch event {
            case .value(let list, false): cached = list.map(\.id) == [123]
            case .failure: failed = true
            default: break
            }
        }
        XCTAssertTrue(cached); XCTAssertTrue(failed)
    }
}
