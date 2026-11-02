import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor SubjectsCacheTransport: PhotosTransport {
    var offline = false
    var calls = 0
    func setOffline() { offline = true }
    func subjects(space: PhotoSpace) async throws -> [SubjectSummary] {
        calls += 1
        if offline { throw TestFailure("Offline") }
        return [try JSONDecoder().decode(SubjectSummary.self, from: Data(#"{"id":123,"name":"A","item_count":4,"additional":{"thumbnail":{"unit_id":123,"cache_key":"face","m":"ready"}}}"#.utf8))]
    }
}

final class SubjectsCacheTests: XCTestCase {
    func testCachedIndexSurvivesFailedRefreshAndValidatesOncePerRun() async throws {
        let root = temporaryTestRoot("subjects-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SubjectsCacheTransport()
        let credentials = SynologyCredentials(username: "fixture", password: "fixture")
        let first = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        var verified = false
        for await event in await first.subjects() { if case .value(let list, true) = event { verified = list.map(\.id) == [123] } }
        XCTAssertTrue(verified)
        for await _ in await first.subjects() {}
        let count = await transport.calls
        XCTAssertEqual(count, 1)
        let offline = SubjectsCacheTransport()
        await offline.setOffline()
        let second = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: offline)
        var cached = false; var failed = false
        for await event in await second.subjects() {
            switch event {
            case .value(let list, false): cached = list.map(\.id) == [123]
            case .failure: failed = true
            default: break
            }
        }
        XCTAssertTrue(cached); XCTAssertTrue(failed)
    }
}
