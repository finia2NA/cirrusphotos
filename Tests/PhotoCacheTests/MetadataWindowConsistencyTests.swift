import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor WindowMetadataTransport: PhotosTransport {
    var edited = false
    let day = try! CaptureDay(year: 2024, month: 1, day: 1)
    var pendingChange = false
    var batches = 0
    func change() { edited = true; pendingChange = true }
    func photo(_ id: Int64) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(day.startTime),\"type\":\"photo\",\"filename\":\"\(edited && id == 1 ? "edited" : "original").jpg\"}".utf8))
    }
    func diffVersion() async throws -> DiffCursor { .init(diffVersion: 1, versionTime: 1) }
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        let modified: [Int64] = pendingChange ? [1] : []
        pendingChange = false
        return .init(cursor: .init(diffVersion: edited ? 2 : 1, versionTime: edited ? 2 : 1), modifiedItemIDs: modified, deletedItemIDs: [])
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: [.init(day: day, count: 2)], completeness: initial ? .partial : .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        batches += 1
        return try .init(items: edited ? [photo(2), photo(1)] : [photo(1), photo(2)], profile: fields)
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { try ids.map(photo) }
    func batchCount() -> Int { batches }
}
private struct WindowNoNetworkTransport: PhotosTransport {}
final class MetadataWindowConsistencyTests: XCTestCase, @unchecked Sendable {
    func testSameCountSourceChangeRetiresVerifiedWindowDespiteUnchangedFingerprint() async throws {
        let root = temporaryTestRoot("window-source"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = WindowMetadataTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "window", password: "unused"), cacheRoot: root, transport: transport)
        let snapshot = try await repository.verifiedTimelineSnapshot(collection: .library(.personal))
        let window = LibraryPageWindow(repository: repository, collection: .library(.personal))
        let events = await window.events()
        let observer = Task { for await _ in events {} }
        await window.update(snapshot: snapshot, allowNetwork: true, visible: [0], prefetch: [])
        let initial = await waitUntil { await window.retainedPages().first?.verified == true }
        XCTAssertTrue(initial)
        await transport.change()
        try await repository.reconcileMetadataSource(force: true)
        let changed = await waitUntil(attempts: 1000) {
            let page = await window.retainedPages().first
            return page?.verified == true && page?.slots.map(\.itemID) == [2, 1]
        }
        XCTAssertTrue(changed)
        let current = try await repository.verifiedTimelineSnapshot(collection: .library(.personal))
        XCTAssertEqual(LibraryIndex(snapshot: current).fingerprint, LibraryIndex(snapshot: snapshot).fingerprint)
        let pages = await window.retainedPages()
        XCTAssertEqual(pages.first?.slots.last?.item?.filename, "edited.jpg")
        observer.cancel(); await window.cancelAll()
    }
    func testNewDayRebasesRetainedSlotRatherThanRelabelingItsSectionIndex() async throws {
        let root = temporaryTestRoot("window-rebase"); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "window", password: "unused"), cacheRoot: root, transport: WindowNoNetworkTransport())
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        let old = TimelineSection(offset: 0, limit: 1, list: [.init(year: 2024, month: 1, day: 1, itemCount: 1)])
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":\(day.startTime),\"type\":\"photo\"}".utf8))
        try await seedMetadataPage([photo], section: old, repository: repository, validatedRun: repository.runID)
        let window = LibraryPageWindow(repository: repository, collection: .library(.personal))
        await window.update(snapshot: .init(sections: [old]), allowNetwork: false, visible: [0], prefetch: [])
        let loaded = await waitUntil { await window.retainedPages().count == 1 }
        XCTAssertTrue(loaded)
        let newest = TimelineSection(offset: 0, limit: 1, list: [.init(year: 2024, month: 1, day: 2, itemCount: 1)])
        await window.update(snapshot: .init(sections: [newest, old]), allowNetwork: false, visible: [1], prefetch: [])
        let pages = await window.retainedPages()
        XCTAssertEqual(pages.map(\.sectionIndex), [1])
        XCTAssertEqual(pages.first?.slots.map(\.itemID), [1])
        XCTAssertTrue(pages.first?.verified == true)
        await window.cancelAll()
    }
}
