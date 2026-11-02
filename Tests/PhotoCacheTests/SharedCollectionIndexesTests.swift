import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor SharedIndexTransport: PhotosTransport {
    var offline = false
    var diffCalls = 0
    var peopleCalls: [PhotoSpace: Int] = [:]
    func setOffline() { offline = true }
    func diffVersion() async throws -> DiffCursor { diffCalls += 1; throw SynologyAPIError.api(103) }
    func people(space: PhotoSpace) async throws -> [PersonSummary] {
        peopleCalls[space, default: 0] += 1
        if offline { throw SynologyAPIError.transport("offline") }
        return [try JSONDecoder().decode(PersonSummary.self, from: Data("{\"id\":1,\"name\":\"\(space.rawValue)\",\"item_count\":1}".utf8))]
    }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        if offline { throw SynologyAPIError.transport("offline") }
        return try JSONDecoder().decode(FolderSummary.self, from: Data("{\"id\":1,\"name\":\"\(space.rawValue)\",\"parent\":0}".utf8))
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] { [] }
}

final class SharedCollectionIndexesTests: XCTestCase {
    func testIndexesAndDirectoriesKeepIdenticalIDsSeparateAndRetainOfflineCache() async throws {
        let root = temporaryTestRoot("shared-indexes")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedIndexTransport()
        let credentials = SynologyCredentials(username: "fixture", password: "unused")
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        // Shared discovery must not join the Personal Space reconciliation job.
        for await _ in await repository.people(space: .shared) {}
        for await _ in await repository.folderDirectory(id: 0, space: .shared) {}
        let diffBeforePersonal = await transport.diffCalls
        XCTAssertEqual(diffBeforePersonal, 0)
        for space in PhotoSpace.allCases {
            var name: String?
            for await event in await repository.people(space: space) {
                if case .value(let list, true) = event { name = list.first?.name }
            }
            XCTAssertEqual(name, space.rawValue)
            for await _ in await repository.folderDirectory(id: 0, space: space) {}
        }
        let calls = await transport.peopleCalls
        XCTAssertEqual(calls, [.personal: 1, .shared: 1])
        await transport.setOffline()
        let reopened = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        for space in PhotoSpace.allCases {
            var cached: String?; var failed = false
            for await event in await reopened.people(space: space) {
                if case .value(let list, false) = event { cached = list.first?.name }
                if case .failure = event { failed = true }
            }
            XCTAssertEqual(cached, space.rawValue); XCTAssertTrue(failed)
            var folderName: String?
            for await event in await reopened.folderDirectory(id: 0, space: space) {
                if case .value(let directory, false) = event { folderName = directory.folder.name }
            }
            XCTAssertEqual(folderName, space.rawValue)
        }
    }
}
