import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor DeletionTransport: TestPhotosTransport {
    private var existing: [Int64]
    private let refuses: Bool
    private let failsWrite: Bool
    private(set) var deletions: [(ids: [Int64], space: PhotoSpace)] = []

    init(ids: [Int64], refuses: Bool = false, failsWrite: Bool = false) {
        existing = ids
        self.refuses = refuses
        self.failsWrite = failsWrite
    }

    private func photo(_ id: Int64) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(id).jpg","time":1704067200,"type":"photo","additional":{"thumbnail":{"unit_id":\(id + 100),"cache_key":"k\(id)","sm":"ready","m":"ready","xl":"ready"}}}
        """.utf8))
    }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        guard !existing.isEmpty else { return try CollectionDayCatalog(sections: [], completeness: .complete) }
        return try CollectionDayCatalog(sections: [TimelineSection(offset: 0, limit: existing.count,
            list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: existing.count)])], completeness: .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        CollectionBatchResult(items: try existing.sorted().map(photo), profile: fields)
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        try ids.filter(existing.contains).map(photo)
    }
    func deleteItems(_ itemIDs: [Int64], space: PhotoSpace) async throws {
        deletions.append((itemIDs, space))
        if failsWrite { throw SynologyAPIError.unsupported("Write failed") }
        // The NAS reports the task as done even when it deleted nothing.
        if !refuses { existing.removeAll { itemIDs.contains($0) } }
    }
}

final class ItemDeletionTests: XCTestCase {
    private func selection(_ repository: CachedPhotosRepository, ordinals: [Int]) async throws -> ResolvedPhotoSelection {
        let collection = PhotoCollectionDescriptor.library(.shared)
        let timeline = try await repository.verifiedTimelineSnapshot(collection: collection)
        let authority = await repository.selectionAuthority(collection: collection, snapshot: timeline)
        let snapshot = PhotoSelectionSnapshot(collection: collection, timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(ordinals), knownItemIDsByOrdinal: [:], authority: authority)
        let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(snapshot)
        return try XCTUnwrap(resolved)
    }

    private func count(_ repository: CachedPhotosRepository) async throws -> Int {
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .library(.shared))
        return LibraryIndex(snapshot: timeline).totalCount
    }

    func testDeletionConfirmsAbsenceAndRefreshesTimelineAndAnnouncesInvalidation() async throws {
        let root = temporaryTestRoot("item-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DeletionTransport(ids: [1, 2, 3])
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        let initialCount = try await count(repository)
        XCTAssertEqual(initialCount, 3)
        let resolved = try await selection(repository, ordinals: [0, 1])
        let deleted = try await repository.deleteItems(resolved)
        XCTAssertEqual(deleted, 2)
        let calls = await transport.deletions
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.space, .shared)
        XCTAssertEqual(Set(calls.first?.ids ?? []), Set(resolved.items.map(\.id)))
        let remaining = try await count(repository)
        XCTAssertEqual(remaining, 1)
        var revisions = await repository.metadataCacheResets().makeAsyncIterator()
        let revision = await revisions.next()
        XCTAssertGreaterThan(revision ?? 0, 0)
    }

    func testItemsStillPresentAfterQueuedTaskReportFailureAndStillInvalidate() async throws {
        let root = temporaryTestRoot("item-deletion-refused")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DeletionTransport(ids: [1, 2], refuses: true)
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        _ = try await count(repository)
        let resolved = try await selection(repository, ordinals: [0])
        do {
            try await repository.deleteItems(resolved)
            XCTFail("An item that remains must not be reported as deleted")
        } catch RepositoryError.unconfirmed(let message) {
            XCTAssertTrue(message.contains("1 of 1"))
        }
        var revisions = await repository.metadataCacheResets().makeAsyncIterator()
        let revision = await revisions.next()
        XCTAssertGreaterThan(revision ?? 0, 0)
        let after = try await count(repository)
        XCTAssertEqual(after, 2)
    }

    func testFailedWriteIsReportedAfterReconciliation() async throws {
        let root = temporaryTestRoot("item-deletion-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DeletionTransport(ids: [1, 2], failsWrite: true)
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        _ = try await count(repository)
        let resolved = try await selection(repository, ordinals: [0])
        do {
            try await repository.deleteItems(resolved)
            XCTFail("A failed write must be reported")
        } catch SynologyAPIError.unsupported(let message) {
            XCTAssertEqual(message, "Write failed")
        }
        var revisions = await repository.metadataCacheResets().makeAsyncIterator()
        let revision = await revisions.next()
        XCTAssertGreaterThan(revision ?? 0, 0)
    }
}
