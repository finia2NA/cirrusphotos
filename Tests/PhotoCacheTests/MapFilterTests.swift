import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor CanonicalFilterTransport: PhotosTransport {
    var rows: [Int64: PhotoItem]
    var blocked = false
    var released = false
    var requests: [[Int64]] = []
    var pageRequests = 0
    init(_ items: [PhotoItem]) { rows = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }
    func block() { blocked = true }
    func release() { released = true }
    func items(ids: [Int64]) async throws -> [PhotoItem] {
        requests.append(ids)
        while blocked && !released { try await Task.sleep(for: .milliseconds(2)) }
        return ids.compactMap { rows[$0] }
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        pageRequests += 1
        throw TestFailure("Derived IDs must use the common detail lookup")
    }
    func stats() -> (lookups: [[Int64]], pages: Int) { (requests, pageRequests) }
}
final class MapFilterTests: XCTestCase, @unchecked Sendable {
    private func item(_ id: Int64, camera: String = "A") throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":1704067200,\"type\":\"photo\",\"additional\":{\"gps\":{\"latitude\":10,\"longitude\":20},\"exif\":{\"camera\":\"\(camera)\"}}}".utf8))
    }
    private func repository(root: URL, transport: CanonicalFilterTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: .init(username: "filter", password: "unused"), cacheRoot: root, transport: transport)
    }
    private func register(_ repository: CachedPhotosRepository, items: [PhotoItem], current: Bool = false) async throws -> MapFilterRegistration {
        try await repository.initializeMetadataEngine()
        let namespace = await repository.metadataNamespace
        let run = current ? await repository.runID : "previous-run"
        _ = try await repository.store.storeMetadataDetails(items, namespace: namespace, currentRun: run, admission: repository.store.metadataAdmission(namespace))
        let records = try await repository.store.metadataCachedLocations(namespace)
        let value = await repository.acceptLocationRecords(records)
        return try await repository.registerMapFilter(itemIDs: items.map(\.id), locationRevision: value.revision)
    }
    private func pages(_ repository: CachedPhotosRepository, registration: MapFilterRegistration,
                       allowNetwork: Bool = true) async -> [PhotoPageSnapshot] {
        var values: [PhotoPageSnapshot] = []
        for await event in await repository.page(registration.snapshot.sections[0], collection: registration.descriptor, allowNetwork: allowNetwork) {
            if case .value(let page, _) = event { values.append(page) }
        }
        return values
    }
    func testCachedSparseDerivedPagePreservesIDsAndShowsOtherItemsOffline() async throws {
        let root = temporaryTestRoot("map-sparse"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = try [item(1), item(2)]
        let transport = CanonicalFilterTransport(photos)
        let repository = try repository(root: root, transport: transport)
        let registration = try await register(repository, items: photos)
        try await repository.store.evictMetadataDetails(namespace: repository.metadataNamespace, itemIDs: [1])
        let values = await pages(repository, registration: registration, allowNetwork: false)
        let page = try XCTUnwrap(values.first)
        XCTAssertEqual(page.slots.map(\.itemID), [1, 2])
        XCTAssertNil(page.slots[0].item); XCTAssertEqual(page.slots[1].item?.id, 2)
        XCTAssertFalse(page.verified)
        let stats = await transport.stats()
        XCTAssertTrue(stats.lookups.isEmpty); XCTAssertEqual(stats.pages, 0)
    }
    func testMetadataFilterUsesMapMembership() async throws {
        let root = temporaryTestRoot("map-metadata-filter"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = try [item(1, camera: "A"), item(2, camera: "B")]
        let repository = try repository(root: root, transport: CanonicalFilterTransport(photos))
        let map = try await register(repository, items: photos, current: true)
        let controller = LibraryFilterController(repository: repository, snapshot: map.snapshot, sourceCollection: map.descriptor)
        await controller.indexCachedPages()
        let filtered = await controller.apply(LibraryFilter(cameras: ["B"]))
        XCTAssertEqual(filtered.referencesBySection.flatMap { $0 }.map(\.itemID), [2])
        try await repository.registerLibraryFilter(filtered)
        await repository.unregisterMapFilter(map.descriptor)
        var events = 0
        for await event in await repository.page(filtered.snapshot.sections[0], collection: filtered.descriptor, allowNetwork: false) {
            if case .value = event { events += 1 }
        }
        XCTAssertEqual(events, 0, "A closed map must not authorize its derived filter")
        await controller.shutdown()
    }

    func testMapFilterOptionsAreCachedForSessionAndRemovedOnClose() async throws {
        let root = temporaryTestRoot("map-options-cache"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = try [item(1, camera: "Map Camera")]
        let repository = try repository(root: root, transport: CanonicalFilterTransport(photos))
        let map = try await register(repository, items: photos, current: true)
        let controller = LibraryFilterController(repository: repository, snapshot: map.snapshot, sourceCollection: map.descriptor)
        await controller.indexCachedPages()
        let saved = try await repository.loadFilterOptionCatalog(for: map.descriptor).0
        XCTAssertEqual(saved?.cameras, ["Map Camera"])
        await controller.shutdown()
        await repository.unregisterMapFilter(map.descriptor)
        let removed = try await repository.loadFilterOptionCatalog(for: map.descriptor).0
        XCTAssertNil(removed)
    }

    func testPinUsesOneIDLookupRegardlessOfLargeDayCatalog() async throws {
        let root = temporaryTestRoot("map-pin-lookup"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try item(999)
        let transport = CanonicalFilterTransport([photo])
        let repository = try repository(root: root, transport: transport)
        let registration = try await register(repository, items: [photo])
        try await repository.store.evictMetadataDetails(namespace: repository.metadataNamespace, itemIDs: [999])
        let values = await pages(repository, registration: registration)
        XCTAssertEqual(values.last?.completeItems?.map(\.id), [999])
        XCTAssertTrue(values.last?.verified == true)
        let stats = await transport.stats()
        XCTAssertEqual(stats.lookups, [[999]]); XCTAssertEqual(stats.pages, 0)
    }
    func testTwoDerivedCollectionsShareCanonicalLookupAndOneCancellationKeepsOtherDemand() async throws {
        let root = temporaryTestRoot("map-shared-lookup"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try item(1)
        let transport = CanonicalFilterTransport([photo])
        let repository = try repository(root: root, transport: transport)
        let first = try await register(repository, items: [photo])
        let value = await repository.acceptLocationRecords(try await repository.store.metadataCachedLocations(repository.metadataNamespace))
        let second = try await repository.registerMapFilter(itemIDs: [1], locationRevision: value.revision)
        try await repository.store.evictMetadataDetails(namespace: repository.metadataNamespace, itemIDs: [1])
        await transport.block()
        let left = Task { await self.pages(repository, registration: first) }
        let right = Task { await self.pages(repository, registration: second) }
        let started = await waitUntil { await transport.stats().lookups.count == 1 }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(20))
        left.cancel(); await transport.release()
        let result = await right.value
        XCTAssertTrue(result.last?.verified == true)
        let stats = await transport.stats()
        XCTAssertEqual(stats.lookups.count, 1)
    }
    func testRegistrationRevisionAndResetInvalidateDerivedMembership() async throws {
        let root = temporaryTestRoot("map-registration"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try item(1)
        let repository = try repository(root: root, transport: CanonicalFilterTransport([photo]))
        let registration = try await register(repository, items: [photo], current: true)
        _ = await repository.acceptLocationRecords([])
        let invalid = await pages(repository, registration: registration, allowNetwork: false)
        XCTAssertTrue(invalid.isEmpty)
        try await repository.clearMetadataCache()
        let reset = await pages(repository, registration: registration, allowNetwork: false)
        XCTAssertTrue(reset.isEmpty)
    }
}
