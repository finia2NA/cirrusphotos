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
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
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
        let namespace = await repository.personalMetadataNamespace
        let run = current ? await repository.runID : "previous-run"
        _ = try await repository.store.storeMetadataDetails(items, namespace: namespace, currentRun: run, admission: repository.store.metadataAdmission(namespace))
        let records = try await repository.store.metadataCachedLocations(namespace)
        let value = await repository.acceptLocationRecords(records, space: .personal)
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
        try await repository.store.evictMetadataDetails(namespace: repository.personalMetadataNamespace, itemIDs: [1])
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
        try await repository.store.evictMetadataDetails(namespace: repository.personalMetadataNamespace, itemIDs: [999])
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
        let value = await repository.acceptLocationRecords(try await repository.store.metadataCachedLocations(repository.personalMetadataNamespace), space: .personal)
        let second = try await repository.registerMapFilter(itemIDs: [1], locationRevision: value.revision)
        try await repository.store.evictMetadataDetails(namespace: repository.personalMetadataNamespace, itemIDs: [1])
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
        _ = await repository.acceptLocationRecords([], space: .personal)
        let invalid = await pages(repository, registration: registration, allowNetwork: false)
        XCTAssertTrue(invalid.isEmpty)
        try await repository.clearMetadataCache()
        let reset = await pages(repository, registration: registration, allowNetwork: false)
        XCTAssertTrue(reset.isEmpty)
    }
    func testSelectionLeaseSurvivesViewDismissalAndReleasesAfterResolution() async throws {
        let root = temporaryTestRoot("map-selection-lease"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try item(7)
        let transport = CanonicalFilterTransport([photo])
        let repository = try repository(root: root, transport: transport)
        let map = try await register(repository, items: [photo])
        let selection = PhotoSelectionSnapshot(collection: map.descriptor, timeline: map.snapshot,
            timelineFingerprint: LibraryIndex(snapshot: map.snapshot).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [:], authority: map.authority)
        try await repository.store.evictMetadataDetails(namespace: repository.personalMetadataNamespace, itemIDs: [7])
        await transport.block()
        let task = Task { await SelectionItemResolver(repository: repository).resolve(selection) }
        let started = await waitUntil { await transport.stats().lookups.count == 1 }
        XCTAssertTrue(started)
        await repository.unregisterMapFilter(map.descriptor)
        await transport.release()
        let result = await task.value
        XCTAssertEqual(result?.map(\.id), [7])
        let current = await repository.latestTimelineSnapshot(collection: map.descriptor)
        XCTAssertNil(current)
    }

    func testSelectionRejectsSameShapeFilterReplacementAndMapInvalidation() async throws {
        let root = temporaryTestRoot("filter-selection-authority"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = try [item(1, camera: "A"), item(2, camera: "B")]
        let repository = try repository(root: root, transport: CanonicalFilterTransport(photos))
        let map = try await register(repository, items: photos, current: true)
        let controller = LibraryFilterController(repository: repository, snapshot: map.snapshot, sourceCollection: map.descriptor)
        await controller.indexCachedPages()
        let first = await controller.apply(LibraryFilter(cameras: ["A"]))
        let authority = try await repository.registerLibraryFilter(first)
        let selection = PhotoSelectionSnapshot(collection: first.descriptor, timeline: first.snapshot,
            timelineFingerprint: LibraryIndex(snapshot: first.snapshot).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [:], authority: authority)
        let original = await SelectionItemResolver(repository: repository).resolve(selection)
        XCTAssertEqual(original?.map(\.id), [1])
        // Replace the same descriptor with a different ID and identical geometry.
        let other = await controller.apply(LibraryFilter(cameras: ["B"]))
        XCTAssertEqual(LibraryIndex(snapshot: first.snapshot).fingerprint, LibraryIndex(snapshot: other.snapshot).fingerprint)
        let replacement = LibraryFilterRegistration(descriptor: first.descriptor, snapshot: other.snapshot,
            referencesBySection: other.referencesBySection, filter: other.filter, revision: other.revision,
            sourceFingerprint: other.sourceFingerprint, sourceCollection: other.sourceCollection)
        _ = try await repository.replaceLibraryFilterSnapshot(replacement)
        let replaced = await SelectionItemResolver(repository: repository).resolve(selection)
        XCTAssertNil(replaced)
        let current = try await repository.replaceLibraryFilterSnapshot(first)
        let next = PhotoSelectionSnapshot(collection: first.descriptor, timeline: first.snapshot,
            timelineFingerprint: LibraryIndex(snapshot: first.snapshot).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [:], authority: current)
        _ = await repository.acceptLocationRecords([], space: .personal)
        let invalid = await SelectionItemResolver(repository: repository).resolve(next)
        XCTAssertNil(invalid)
        await controller.shutdown()
    }

    func testCancelledSelectionReleasesDismissedMap() async throws {
        let root = temporaryTestRoot("map-selection-cancel"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try item(8)
        let transport = CanonicalFilterTransport([photo])
        let repository = try repository(root: root, transport: transport)
        let map = try await register(repository, items: [photo])
        try await repository.store.evictMetadataDetails(namespace: repository.personalMetadataNamespace, itemIDs: [8])
        let selection = PhotoSelectionSnapshot(collection: map.descriptor, timeline: map.snapshot,
            timelineFingerprint: LibraryIndex(snapshot: map.snapshot).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [:], authority: map.authority)
        await transport.block()
        let task = Task { await SelectionItemResolver(repository: repository).resolve(selection) }
        let started = await waitUntil { await transport.stats().lookups.count == 1 }
        XCTAssertTrue(started)
        await repository.unregisterMapFilter(map.descriptor)
        task.cancel()
        await transport.release()
        let result = await task.value
        XCTAssertNil(result)
        let current = await repository.latestTimelineSnapshot(collection: map.descriptor)
        XCTAssertNil(current)
    }

    func testCapturedSelectionRetainsRegistrationBeforeResolverStarts() async throws {
        let root = temporaryTestRoot("map-selection-acceptance"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try item(9)
        let repository = try repository(root: root, transport: CanonicalFilterTransport([photo]))
        let map = try await register(repository, items: [photo], current: true)
        let selection = PhotoSelectionSnapshot(collection: map.descriptor, timeline: map.snapshot,
            timelineFingerprint: LibraryIndex(snapshot: map.snapshot).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [:], authority: map.authority)
        await repository.unregisterMapFilter(map.descriptor)
        let result = await SelectionItemResolver(repository: repository).resolve(selection)
        XCTAssertEqual(result?.map(\.id), [9])
        let removed = await waitUntil { await repository.latestTimelineSnapshot(collection: map.descriptor) == nil }
        XCTAssertTrue(removed)
    }

    func testFilteredMapSelectionRetainsBothRegistrationsAfterDismissal() async throws {
        let root = temporaryTestRoot("filtered-map-selection"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = try [item(1, camera: "A"), item(2, camera: "B")]
        let repository = try repository(root: root, transport: CanonicalFilterTransport(photos))
        let map = try await register(repository, items: photos, current: true)
        let controller = LibraryFilterController(repository: repository, snapshot: map.snapshot, sourceCollection: map.descriptor)
        await controller.indexCachedPages()
        let filter = await controller.apply(LibraryFilter(cameras: ["B"]))
        let authority = try await repository.registerLibraryFilter(filter)
        let selection = PhotoSelectionSnapshot(collection: filter.descriptor, timeline: filter.snapshot,
            timelineFingerprint: LibraryIndex(snapshot: filter.snapshot).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [:], authority: authority)
        await repository.unregisterLibraryFilter(filter.descriptor)
        await repository.unregisterMapFilter(map.descriptor)
        let result = await SelectionItemResolver(repository: repository).resolve(selection)
        XCTAssertEqual(result?.map(\.id), [2])
        let mapRemoved = await waitUntil { await repository.latestTimelineSnapshot(collection: map.descriptor) == nil }
        let filterRemoved = await waitUntil { await repository.latestTimelineSnapshot(collection: filter.descriptor) == nil }
        XCTAssertTrue(mapRemoved)
        XCTAssertTrue(filterRemoved)
        await controller.shutdown()
    }

}
