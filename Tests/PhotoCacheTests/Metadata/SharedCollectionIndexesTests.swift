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
    func diffVersion(space: PhotoSpace) async throws -> DiffCursor { if space == .personal { diffCalls += 1 }; throw SynologyAPIError.api(103) }
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
    func testFolderCoversSearchCachedDescendantsBreadthFirst() async throws {
        let root = temporaryTestRoot("folder-covers")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: SharedIndexTransport())
        try await repository.initializeMetadataEngine()
        let namespace = await repository.metadataNamespace(for: .library(.personal))
        func folder(_ id: Int64, parent: Int64, cover: Int64? = nil) throws -> FolderSummary {
            let thumbnail = cover.map { #", "additional": {"thumbnail": [{"unit_id": \#($0), "cache_key": "k\#($0)"}]}"# } ?? ""
            return try JSONDecoder().decode(FolderSummary.self, from: Data(#"{"id": \#(id), "name": "/f\#(id)", "parent": \#(parent)\#(thumbnail)}"#.utf8))
        }
        let top = try folder(1, parent: 0)
        let directories: [Int64: [FolderSummary]] = [
            1: [try folder(2, parent: 1), try folder(3, parent: 1, cover: 30)],
            2: [try folder(4, parent: 2, cover: 40), try folder(5, parent: 2, cover: 50), try folder(6, parent: 2, cover: 60), try folder(7, parent: 2, cover: 70)],
        ]
        for (id, children) in directories {
            let parent = id == 1 ? top : try folder(id, parent: 1)
            let admission = try await repository.store.metadataAdmission(namespace)
            try await repository.store.storeMetadataFolderDirectory(FolderDirectory(folder: parent, children: children), namespace: namespace, id: id, currentRun: repository.runID, admission: admission)
        }
        let covers = await repository.folderCovers(for: top, space: .personal)
        // The shallow leaf comes first, then the leaves under the nested folder, capped at four.
        XCTAssertEqual(covers.map(\.unitID), [30, 40, 50, 60])
        let own = await repository.folderCovers(for: try folder(9, parent: 1, cover: 90), space: .personal)
        XCTAssertEqual(own.map(\.unitID), [90])
        // A folder with its own photo and a subfolder shows its own cover first, then the subfolder's.
        let mixed = try folder(8, parent: 0, cover: 10)
        let mixedAdmission = try await repository.store.metadataAdmission(namespace)
        try await repository.store.storeMetadataFolderDirectory(
            FolderDirectory(folder: mixed, children: [try folder(3, parent: 8, cover: 30), try folder(4, parent: 8, cover: 40)]),
            namespace: namespace, id: 8, currentRun: repository.runID, admission: mixedAdmission)
        let withOwn = await repository.folderCovers(for: mixed, space: .personal)
        XCTAssertEqual(withOwn.map(\.unitID), [10, 30, 40])
        // Results persist: they are readable without recomputing, and a changed listing withdraws them.
        let stored = await repository.cachedFolderCovers(for: top, space: .personal)
        XCTAssertEqual(stored?.map(\.unitID), [30, 40, 50, 60])
        let admission = try await repository.store.metadataAdmission(namespace)
        try await repository.store.storeMetadataFolderDirectory(
            FolderDirectory(folder: top, children: [try folder(2, parent: 1), try folder(3, parent: 1, cover: 31)]),
            namespace: namespace, id: 1, currentRun: repository.runID, admission: admission)
        // The unrelated folder keeps its result for this run; the changed folder's was withdrawn.
        let unrelated = try await repository.store.metadataFolderCovers(namespace, id: 8)
        let run = await repository.runID
        XCTAssertEqual(unrelated?.validatedRun, run)
        let withdrawn = try await repository.store.metadataFolderCovers(namespace, id: 1)
        XCTAssertNil(withdrawn?.validatedRun)
        let recomputed = await repository.folderCovers(for: top, space: .personal)
        XCTAssertEqual(recomputed.map(\.unitID), [31, 40, 50, 60])
    }
}
