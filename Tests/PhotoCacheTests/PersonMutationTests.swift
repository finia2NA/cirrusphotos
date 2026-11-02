import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor PersonMutationTransport: TestPhotosTransport {
    var sharedName = "Original"
    var failAfterWrite = false
    var sourcePresent = true
    var refreshedCollections: [PhotoCollectionDescriptor] = []
    func setFailAfterWrite() { failAfterWrite = true }
    private func person(_ name: String) throws -> CollectionIndexEntry {
        try CollectionIndexEntry.decoder(for: .person).decode(CollectionIndexEntry.self, from: Data("{\"id\":1,\"name\":\"\(name)\",\"item_count\":1}".utf8))
    }
    func collectionIndex(_ kind: CollectionIndexKind, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        guard kind == .person else { throw UnexpectedTransportCall("collectionIndex") }
        var result = [try person(space == .shared ? sharedName : "Personal")]
        if space == .shared && sourcePresent {
            result.append(try CollectionIndexEntry.decoder(for: .person).decode(CollectionIndexEntry.self, from: Data(#"{"id":2,"name":"Source","item_count":1}"#.utf8)))
        }
        return result
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        refreshedCollections.append(collection)
        return try CollectionDayCatalog(days: [], completeness: .complete)
    }
    func mergePerson(sourceID: Int64, targetID: Int64, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
        sourcePresent = false
        sharedName = name
        return try person(name)
    }
    func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
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
        for space in PhotoSpace.allCases { for await _ in await repository.collectionIndex(.person, space: space) {} }
        try await repository.renamePerson(id: 1, name: "Updated", space: .shared)
        var shared: String?; var personal: String?
        for await event in await repository.collectionIndex(.person, space: .shared) { if case .value(let list, true) = event { shared = list.first?.name } }
        for await event in await repository.collectionIndex(.person, space: .personal) { if case .value(let list, true) = event { personal = list.first?.name } }
        XCTAssertEqual(shared, "Updated")
        XCTAssertEqual(personal, "Personal")
    }

    func testMergeRefreshesPeopleAndTargetTimeline() async throws {
        let root = temporaryTestRoot("person-merge")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PersonMutationTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.collectionIndex(.person, space: .shared) {}
        try await repository.mergePerson(sourceID: 2, targetID: 1, name: "Combined", space: .shared)
        var ids: [Int64] = []
        for await event in await repository.collectionIndex(.person, space: .shared) { if case .value(let list, true) = event { ids = list.map(\.id) } }
        XCTAssertEqual(ids, [1])
        let collections = await transport.refreshedCollections
        XCTAssertTrue(collections.contains(.person(1, space: .shared)))
    }

    func testUncertainWriteStillReconcilesIndex() async throws {
        let root = temporaryTestRoot("person-uncertain")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PersonMutationTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        for await _ in await repository.collectionIndex(.person, space: .shared) {}
        await transport.setFailAfterWrite()
        do {
            try await repository.renamePerson(id: 1, name: "Updated", space: .shared)
            XCTFail("A lost response must be reported as uncertain")
        } catch { }
        var refreshed: String?
        for await event in await repository.collectionIndex(.person, space: .shared) { if case .value(let list, true) = event { refreshed = list.first?.name } }
        XCTAssertEqual(refreshed, "Updated")
    }
}
