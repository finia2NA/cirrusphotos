import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor SharedIndexTransport: TestPhotosTransport {
    var offline = false
    var blocked = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func blockPeople() { blocked = true }
    func releasePeople() { blocked = false; let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
    var diffCalls = 0
    var peopleCalls: [PhotoSpace: Int] = [:]
    func setOffline() { offline = true }
    func diffVersion() async throws -> DiffCursor { diffCalls += 1; throw SynologyAPIError.api(103) }
    func collectionIndex(_ kind: CollectionIndexKind, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        guard kind == .person else { throw UnexpectedTransportCall("collectionIndex") }
        peopleCalls[space, default: 0] += 1
        if offline { throw SynologyAPIError.transport("offline") }
        if blocked { await withCheckedContinuation { waiting.append($0) } }
        return [try CollectionIndexEntry.decoder(for: .person).decode(CollectionIndexEntry.self, from: Data("{\"id\":1,\"name\":\"\(space.rawValue)\",\"item_count\":1}".utf8))]
    }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        if offline { throw SynologyAPIError.transport("offline") }
        return try JSONDecoder().decode(FolderSummary.self, from: Data("{\"id\":1,\"name\":\"\(space.rawValue)\",\"parent\":0}".utf8))
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] { [] }
}

extension CachedPhotosRepository {
    fileprivate func peopleSubscriberCount(_ space: PhotoSpace) -> Int { metadata.collectionIndexJobs[CollectionIndexJobKey(kind: .person, space: space)]?.subscribers.count ?? 0 }
}

final class SharedCollectionIndexesTests: XCTestCase {
    func testSharedIndexSubscribersCoalesceAndCancelIndependently() async throws {
        let root = temporaryTestRoot("shared-index-subscribers")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedIndexTransport()
        await transport.blockPeople()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        let first = Task { for await _ in await repository.collectionIndex(.person, space: .shared) {} }
        let started = await waitUntil { await transport.peopleCalls[.shared] == 1 }
        XCTAssertTrue(started)
        let second = Task { () -> [CollectionIndexEntry]? in
            var result: [CollectionIndexEntry]?
            for await event in await repository.collectionIndex(.person, space: .shared) {
                if case .value(let people, true) = event { result = people }
            }
            return result
        }
        let joined = await waitUntil { await repository.peopleSubscriberCount(.shared) == 2 }
        XCTAssertTrue(joined)
        first.cancel()
        let left = await waitUntil { await repository.peopleSubscriberCount(.shared) == 1 }
        XCTAssertTrue(left)
        await transport.releasePeople()
        await first.value
        let result = await second.value
        XCTAssertEqual(result?.first?.name, "shared")
        let calls = await transport.peopleCalls
        XCTAssertEqual(calls[.shared], 1)
    }

    func testSharedFoldersValidateWhenPersonalAndSharedRevisionsDiffer() async throws {
        let root = temporaryTestRoot("shared-folder-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedIndexTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        try await repository.initializeMetadataEngine()
        let personal = await repository.personalMetadataNamespace
        let shared = await repository.metadataNamespace(for: .library(.shared))
        try await repository.store.applyMetadataChanges(namespace: personal, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: true, currentRun: repository.runID, admission: repository.store.metadataAdmission(personal))
        let personalVersion = try await repository.store.metadataState(personal)
        let sharedVersion = try await repository.store.metadataState(shared)
        XCTAssertNotEqual(personalVersion.revision, sharedVersion.revision)
        var result: FolderDirectory?
        for await event in await repository.folderDirectory(id: 0, space: .shared) {
            switch event {
            case .value(let value, true): result = value
            case .failure(let message): XCTFail(message.localizedDescription)
            default: break
            }
        }
        XCTAssertEqual(result?.folder.name, "shared")
        let persisted = try await repository.store.metadataFolderDirectory(shared, id: 0)
        XCTAssertEqual(persisted?.0.folder.name, "shared")
    }

    func testIndexesAndDirectoriesKeepIdenticalIDsSeparateAndRetainOfflineCache() async throws {
        let root = temporaryTestRoot("shared-indexes")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedIndexTransport()
        let credentials = SynologyCredentials(username: "fixture", password: "unused")
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        // Shared discovery must not join the Personal Space reconciliation job.
        for await _ in await repository.collectionIndex(.person, space: .shared) {}
        for await _ in await repository.folderDirectory(id: 0, space: .shared) {}
        let diffBeforePersonal = await transport.diffCalls
        XCTAssertEqual(diffBeforePersonal, 0)
        for space in PhotoSpace.allCases {
            var name: String?
            for await event in await repository.collectionIndex(.person, space: space) {
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
            for await event in await reopened.collectionIndex(.person, space: space) {
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
