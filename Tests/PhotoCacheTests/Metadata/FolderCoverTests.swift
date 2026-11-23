import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor FolderCoverTransport: TestPhotosTransport {
    var calls: [PhotoSpace] = []
    var revision = "first"
    var lists = 0

    func changeCover() { revision = "second" }
    func diffVersion(space: PhotoSpace) async throws -> DiffCursor { throw SynologyAPIError.api(103) }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        try coverFolder(id == 0 ? 1 : id, parent: id == 0 ? 0 : 1)
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] {
        lists += 1
        return [try coverFolder(2, parent: 1, entries: #"{"cache_key":"\#(revision)","folder_cover_seq":0}"#)]
    }
    func folderThumbnail(folderID: Int64, cacheKey: String, sequence: Int64, space: PhotoSpace) async throws -> Data {
        calls.append(space)
        return Data("\(space.rawValue)-\(cacheKey)-\(sequence)".utf8)
    }
}

private func coverFolder(_ id: Int64, parent: Int64, entries: String = "") throws -> FolderSummary {
    try JSONDecoder().decode(FolderSummary.self, from: Data(
        #"{"id":\#(id),"parent":\#(parent),"name":"/f\#(id)","additional":{"thumbnail":[\#(entries)]}}"#.utf8))
}

private actor EmptyFolderTransport: TestPhotosTransport {
    var reads = 0
    func diffVersion(space: PhotoSpace) async throws -> DiffCursor { throw SynologyAPIError.api(103) }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        try coverFolder(id, parent: 1)
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] {
        reads += 1
        return []
    }
}

final class FolderCoverTests: XCTestCase {
    func testEmptyCoverSearchKeepsItsNetworkBound() async throws {
        let root = temporaryTestRoot("bounded-empty-covers")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = EmptyFolderTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"),
                                                     cacheRoot: root, transport: transport)
        try await repository.initializeMetadataEngine()
        let namespace = await repository.metadataNamespace(for: .shared)
        let folder = try coverFolder(1, parent: 0)
        let children = try (2...46).map { try coverFolder(Int64($0), parent: 1) }
        try await repository.store.storeMetadataFolderDirectory(.init(folder: folder, children: children),
            namespace: namespace, id: 1, currentRun: repository.runID,
            admission: repository.store.metadataAdmission(namespace))
        let result = try await repository.folderCovers(for: folder, space: .shared)
        XCTAssertTrue(result.resources.isEmpty)
        let reads = await transport.reads
        XCTAssertEqual(reads, 6)
    }

    func testServerCompositionAndCustomCoverTakePrecedence() async throws {
        let root = temporaryTestRoot("server-folder-covers")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FolderCoverTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"),
                                                     cacheRoot: root, transport: transport)
        let folder = try coverFolder(2, parent: 1, entries: #"""
        {"unit_id":8,"cache_key":"eight"},{"unit_id":3,"cache_key":"three"}
        """#)
        let covers = try await repository.folderCovers(for: folder, space: .shared)
        XCTAssertEqual(covers.resources, [
            .photo(.init(unitID: 8, cacheKey: "eight")), .photo(.init(unitID: 3, cacheKey: "three"))])
        let custom = try coverFolder(2, parent: 1, entries: #"""
        {"unit_id":8,"cache_key":"eight"},{"cache_key":"custom","folder_cover_seq":0}
        """#)
        let selected = try await repository.folderCovers(for: custom, space: .shared)
        XCTAssertEqual(selected.resources, [.custom(folderID: 2, cacheKey: "custom", sequence: 0)])
        let listCalls = await transport.lists
        XCTAssertEqual(listCalls, 0)
    }

    func testCustomImageCacheIsolatesSpacesAndRevisionsAndWorksOffline() async throws {
        let root = temporaryTestRoot("folder-cover-images")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FolderCoverTransport()
        let credentials = SynologyCredentials(username: "fixture", password: "unused")
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        for space in PhotoSpace.allCases {
            var result: Data?
            for await event in await repository.folderCoverImage(folderID: 2, cacheKey: "first", sequence: 0,
                                                                 space: space, allowNetwork: true) {
                if case .value(let data, _) = event { result = data }
            }
            XCTAssertEqual(result, Data("\(space.rawValue)-first-0".utf8))
        }
        for await _ in await repository.folderCoverImage(folderID: 2, cacheKey: "second", sequence: 0,
                                                         space: .shared, allowNetwork: true) {}
        for await _ in await repository.folderCoverImage(folderID: 2, cacheKey: "second", sequence: 1,
                                                         space: .shared, allowNetwork: true) {}
        await repository.shutdown()
        let reopened = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        var cached: Data?
        for await event in await reopened.folderCoverImage(folderID: 2, cacheKey: "first", sequence: 0,
                                                           space: .shared, allowNetwork: false) {
            if case .value(let data, false) = event { cached = data }
        }
        XCTAssertEqual(cached, Data("shared-first-0".utf8))
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertNotEqual(CacheKey.folderCover(namespace: "a", space: .shared, folderID: 2, cacheKey: "first", sequence: 0),
                          CacheKey.folderCover(namespace: "b", space: .shared, folderID: 2, cacheKey: "first", sequence: 0))
    }

    func testRefreshReadsSharedFoldersWithoutDiffCursor() async throws {
        let root = temporaryTestRoot("folder-cover-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FolderCoverTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"),
                                                     cacheRoot: root, transport: transport)
        for await _ in await repository.folderDirectory(id: 0, space: .shared) {}
        await transport.changeCover()
        // Diff is unavailable in this fake. Folder validation must still be withdrawn.
        try? await repository.refreshMetadata()
        var snapshots: [FolderDirectory] = []
        for await event in await repository.folderDirectory(id: 0, space: .shared) {
            if case .value(let directory, _) = event { snapshots.append(directory) }
        }
        XCTAssertEqual(snapshots.first?.children.first?.additional?.thumbnail,
                       [.custom(cacheKey: "first", sequence: 0)])
        XCTAssertEqual(snapshots.last?.children.first?.additional?.thumbnail,
                       [.custom(cacheKey: "second", sequence: 0)])
        let calls = await transport.lists
        XCTAssertEqual(calls, 2)
    }

    func testChangedSourceBypassesPersistedFallbackAndEmptySourceRecomputesAfterRefresh() async throws {
        let root = temporaryTestRoot("folder-cover-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"),
                                                     cacheRoot: root, transport: FolderCoverTransport())
        try await repository.initializeMetadataEngine()
        let namespace = await repository.metadataNamespace(for: .shared)
        let empty = try coverFolder(2, parent: 1)
        let old = FolderCoverPresentation(folder: empty, resources: [.photo(.init(unitID: 8, cacheKey: "old"))])
        try await repository.store.storeMetadataFolderCovers(old, namespace: namespace, id: 2,
            currentRun: repository.runID, admission: repository.store.metadataAdmission(namespace))
        let custom = try coverFolder(2, parent: 1, entries: #"{"cache_key":"new","folder_cover_seq":0}"#)
        let supplied = try await repository.folderCovers(for: custom, space: .shared)
        XCTAssertEqual(supplied.resources, [.custom(folderID: 2, cacheKey: "new", sequence: 0)])
        let cached = await repository.cachedFolderCovers(for: custom, space: .shared)
        XCTAssertEqual(cached, supplied)
        // Removal of a custom selection must allow the empty-cover fallback to run afresh.
        try await repository.store.withdrawFolderValidation(namespace: namespace,
            admission: repository.store.metadataAdmission(namespace))
        let recomputed = try await repository.folderCovers(for: empty, space: .shared)
        XCTAssertNotEqual(recomputed.resources, old.resources)
        let stored = await repository.cachedFolderCovers(for: empty, space: .shared)
        XCTAssertEqual(stored, recomputed)
    }

    func testRefreshFencesOldDirectoryAndDerivedCoverWrites() async throws {
        let root = temporaryTestRoot("folder-cover-fences")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"),
                                                     cacheRoot: root, transport: FolderCoverTransport())
        try await repository.initializeMetadataEngine()
        let namespace = await repository.metadataNamespace(for: .shared)
        let admission = try await repository.store.metadataAdmission(namespace)
        let folder = try coverFolder(2, parent: 1)
        try await repository.store.withdrawFolderValidation(namespace: namespace, admission: admission)
        do {
            try await repository.store.storeMetadataFolderDirectory(.init(folder: folder, children: []),
                namespace: namespace, id: 2, currentRun: repository.runID, admission: admission)
            XCTFail("An old directory must not regain validation")
        } catch is MetadataAdmissionError {}
        do {
            try await repository.store.storeMetadataFolderCovers(.init(folder: folder, resources: []),
                namespace: namespace, id: 2, currentRun: repository.runID, admission: admission)
            XCTFail("An old derived cover must not regain validation")
        } catch is MetadataAdmissionError {}
    }
}
