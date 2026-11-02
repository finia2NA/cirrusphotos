import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor PersonMutationTransport: PhotosTransport {
    var sharedName = "Original"
    var failAfterWrite = false
    func setFailAfterWrite() { failAfterWrite = true }
    private func person(_ name: String) throws -> PersonSummary {
        try JSONDecoder().decode(PersonSummary.self, from: Data("{\"id\":1,\"name\":\"\(name)\",\"item_count\":1}".utf8))
    }
    func people(space: PhotoSpace) async throws -> [PersonSummary] {
        [try person(space == .shared ? sharedName : "Personal")]
    }
    func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws -> PersonSummary {
        sharedName = name
        if failAfterWrite { throw SynologyAPIError.transport("connection lost") }
        return try person(name)
    }
}

final class PersonMutationTests: XCTestCase {
    func testRenameRefreshesOnlyTheAffectedSpace() async throws {
        let root = temporaryTestRoot("person-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PersonMutationTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        for space in PhotoSpace.allCases { for await _ in await repository.people(space: space) {} }
        try await repository.renamePerson(id: 1, name: "Updated", space: .shared)
        var shared: String?; var personal: String?
        for await event in await repository.people(space: .shared) { if case .value(let list, true) = event { shared = list.first?.name } }
        for await event in await repository.people(space: .personal) { if case .value(let list, true) = event { personal = list.first?.name } }
        XCTAssertEqual(shared, "Updated")
        XCTAssertEqual(personal, "Personal")
    }

    func testUncertainWriteStillReconcilesIndex() async throws {
        let root = temporaryTestRoot("person-uncertain")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PersonMutationTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.people(space: .shared) {}
        await transport.setFailAfterWrite()
        do {
            try await repository.renamePerson(id: 1, name: "Updated", space: .shared)
            XCTFail("A lost response must be reported as uncertain")
        } catch { }
        var refreshed: String?
        for await event in await repository.people(space: .shared) { if case .value(let list, true) = event { refreshed = list.first?.name } }
        XCTAssertEqual(refreshed, "Updated")
    }
}
