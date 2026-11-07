import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor SharedMapTransport: TestPhotosTransport {
    var offline = false
    var blockBatch = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func block() { blockBatch = true }
    func release() { blockBatch = false; let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
    var duplicate = false
    var drift = false
    var catalogCalls = 0
    var batchCalls = 0
    var diffCalls = 0
    var detailSpaces: [PhotoSpace] = []
    var thumbnailSpaces: [PhotoSpace] = []
    let rows: [PhotoItem]
    init() throws {
        rows = try [
            #"{"id":1,"time":1704067200,"filename":"shared.jpg","type":"photo","additional":{"gps":{"latitude":10,"longitude":20}}}"#,
            #"{"id":2,"time":1704067200,"filename":"unlocated.jpg","type":"photo"}"#
        ].map { try JSONDecoder().decode(PhotoItem.self, from: Data($0.utf8)) }
    }
    func setOffline() { offline = true }
    func setDuplicate() { duplicate = true }
    func setDrift() { drift = true }
    var sharedDiffCalls = 0
    func diffVersion(space: PhotoSpace) async throws -> DiffCursor {
        guard space == .shared else { diffCalls += 1; throw TestFailure("Personal Diff must not run") }
        if offline { throw TestFailure("offline") }
        return DiffCursor(diffVersion: 1, versionTime: 1)
    }
    /// A drifting library keeps reporting a change, so a scan can never be fenced.
    func changes(since cursor: DiffCursor, space: PhotoSpace) async throws -> PhotoDiff {
        guard space == .shared else { diffCalls += 1; throw TestFailure("Personal Diff must not run") }
        sharedDiffCalls += 1
        if offline { throw TestFailure("offline") }
        return drift ? PhotoDiff(cursor: .init(diffVersion: cursor.diffVersion + 1, versionTime: cursor.versionTime + 1), modifiedItemIDs: [2], deletedItemIDs: [])
                     : PhotoDiff(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [])
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        guard collection == .library(.shared) else { throw TestFailure("Wrong map collection") }
        catalogCalls += 1
        if offline { throw TestFailure("offline") }
        return try CollectionDayCatalog(days: [CollectionDayCount(day: CaptureDay(time: 1704067200), count: drift && catalogCalls > 1 ? 1 : 2)], completeness: .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        guard request.collection == .library(.shared), fields == .locations else { throw TestFailure("Wrong inventory request") }
        batchCalls += 1
        if blockBatch { await withCheckedContinuation { waiting.append($0) } }
        return CollectionBatchResult(items: duplicate ? [rows[0], rows[0]] : rows, profile: fields)
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace) async throws -> Data {
        thumbnailSpaces.append(space)
        return Data("fixture-thumbnail".utf8)
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        detailSpaces.append(space)
        guard space == .shared else { throw TestFailure("Wrong detail space") }
        return rows.filter { ids.contains($0.id) }
    }
}

extension CachedPhotosRepository {
    fileprivate func sharedMapScanSubscribers() -> Int { metadata.sharedLocations.job?.subscribers.count ?? 0 }
}

final class SharedMapTests: XCTestCase, @unchecked Sendable {
    private let credentials = SynologyCredentials(username: "map-test", password: "unused")

    private func scan(_ repository: CachedPhotosRepository) async -> (cached: [PhotoLocationRecord], completed: LocationIndexValue?, failed: Bool) {
        var cached: [PhotoLocationRecord] = []
        var completed: LocationIndexValue?
        var failed = false
        for await event in await repository.locationIndex(space: .shared) {
            switch event {
            case .cached(let value): cached = value.records
            case .completed(let value, let verified): if verified { completed = value }
            case .failure: failed = true
            case .progress: break
            }
        }
        return (cached, completed, failed)
    }

    func testLastSharedMapSubscriberCancelsTheScanWithoutPublishingInventory() async throws {
        let root = temporaryTestRoot("shared-map-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedMapTransport()
        await transport.block()
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        let task = Task { for await _ in await repository.locationIndex(space: .shared) {} }
        let started = await waitUntil { await transport.batchCalls == 1 }
        XCTAssertTrue(started)
        let registered = await repository.sharedMapScanSubscribers()
        XCTAssertEqual(registered, 1)
        task.cancel()
        await task.value
        let cancelled = await waitUntil { await repository.sharedMapScanSubscribers() == 0 }
        XCTAssertTrue(cancelled)
        await transport.release()
        let namespace = await repository.metadataNamespace(for: PhotoSpace.shared)
        let version = try await repository.store.metadataState(namespace)
        XCTAssertFalse(version.inventoryComplete)
        let result = await scan(repository)
        XCTAssertFalse(result.failed)
        XCTAssertNotNil(result.completed)
    }

    func testSharedInventoryAndPinUseIsolatedScopeAndTheSharedFeed() async throws {
        let root = temporaryTestRoot("shared-map"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedMapTransport()
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        let result = await scan(repository)
        XCTAssertFalse(result.failed)
        let value = try XCTUnwrap(result.completed)
        XCTAssertEqual(value.records.map(\.id), [1])
        let personal = await repository.metadataNamespace(for: .library(.personal))
        let shared = await repository.metadataNamespace(for: .library(.shared))
        let sharedInventory = try await repository.store.metadataInventory(shared)
        let personalInventory = try await repository.store.metadataInventory(personal)
        XCTAssertEqual(Set(sharedInventory.map(\.id)), [1, 2], "Non-geotagged IDs participate in coverage")
        XCTAssertTrue(personalInventory.isEmpty)
        let sharedState = try await repository.store.metadataState(shared)
        XCTAssertTrue(sharedState.inventoryComplete)
        XCTAssertNotNil(sharedState.cursor, "The scan commits the Shared Diff cursor it was fenced with")

        let pin = try await repository.registerMapFilter(itemIDs: [1], locationRevision: value.revision)
        let source = await repository.mediaCollection(for: pin.descriptor)
        XCTAssertEqual(source, .library(.shared))
        let observationSource = await repository.metadataObservationSource(for: pin.descriptor)
        XCTAssertEqual(observationSource, .library(.shared))
        let observation = await repository.observeCollectionPages(collection: pin.descriptor, sections: Set(pin.snapshot.sections))
        await repository.publishDerivedPageChanges(ids: [1], space: .personal)
        await repository.publishMetadataInvalidation(collection: .library(.personal))
        let changes = await repository.takeCollectionPageChanges(observation.id)
        XCTAssertTrue(changes.isEmpty)
        var name: String?
        for await event in await repository.page(pin.snapshot.sections[0], collection: pin.descriptor) {
            if case .value(let page, let verified) = event, verified { name = page.slots.first?.item?.filename }
        }
        XCTAssertEqual(name, "shared.jpg")
        let detailSpaces = await transport.detailSpaces
        XCTAssertEqual(detailSpaces, [.shared])
        _ = try await repository.cacheThumbnailMeasurement(.init(unitID: 1, cacheKey: "key"), size: .sm, collection: pin.descriptor)
        let thumbnailSpaces = await transport.thumbnailSpaces
        XCTAssertEqual(thumbnailSpaces, [.shared])
        _ = await scan(repository)
        let batchCalls = await transport.batchCalls
        let diffCalls = await transport.diffCalls
        XCTAssertEqual(batchCalls, 1, "The Shared feed keeps the stored inventory current")
        XCTAssertEqual(diffCalls, 0, "Shared Space never joins the Personal feed")

        // The same numeric ID in Personal Space must not replace Shared records
        // or invalidate the existing Shared pin.
        _ = await repository.acceptLocationRecords([PhotoLocationRecord(id: 1, time: 1704067200,
            coordinate: .init(latitude: -10, longitude: -20), thumbnail: nil)], space: .personal)
        let authority = await repository.selectionAuthority(collection: pin.descriptor, snapshot: pin.snapshot)
        XCTAssertNotNil(authority)
        let controller = LibraryFilterController(repository: repository, snapshot: pin.snapshot, sourceCollection: pin.descriptor)
        await controller.indexCachedPages()
        let filtered = await controller.apply(LibraryFilter(extensions: ["jpg"]))
        XCTAssertEqual(filtered.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
        _ = try await repository.registerLibraryFilter(filtered)
        let filteredSource = await repository.mediaCollection(for: filtered.descriptor)
        XCTAssertEqual(filteredSource, .library(.shared))
        await controller.shutdown()
    }

    func testClosedSharedMapDoesNotResolveToPersonalAuthority() async throws {
        let root = temporaryTestRoot("shared-map-closed"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedMapTransport()
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        let result = await scan(repository)
        let value = try XCTUnwrap(result.completed)
        let pin = try await repository.registerMapFilter(itemIDs: [1], locationRevision: value.revision)
        await repository.unregisterMapFilter(pin.descriptor)
        let source = await repository.mediaCollection(for: pin.descriptor)
        XCTAssertEqual(source, pin.descriptor)
        do {
            _ = try await repository.resolveMetadataItems([1], priority: .visible, collection: pin.descriptor)
            XCTFail("An unregistered map cannot authorize item reads")
        } catch { }
        do {
            _ = try await repository.cacheThumbnailMeasurement(.init(unitID: 1, cacheKey: "key"), size: .sm, collection: pin.descriptor)
            XCTFail("An unregistered map cannot authorize thumbnail reads")
        } catch { }
        let spaces = await transport.detailSpaces
        XCTAssertTrue(spaces.isEmpty)
    }

    func testNextRunReusesTheSharedInventoryWithoutAScan() async throws {
        let root = temporaryTestRoot("shared-map-next-run"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedMapTransport()
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        _ = await scan(repository)
        let reopened = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        let result = await scan(reopened)
        XCTAssertEqual(result.completed?.records.map(\.id), [1])
        let batchCalls = await transport.batchCalls
        XCTAssertEqual(batchCalls, 1, "An empty Shared Diff proves the stored inventory current")
    }

    func testSharedInventoryRetainsCachedLocationsWhenNextRunIsOffline() async throws {
        let root = temporaryTestRoot("shared-map-offline"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedMapTransport()
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        _ = await scan(repository)
        await transport.setOffline()
        let reopened = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        let result = await scan(reopened)
        XCTAssertEqual(result.cached.map(\.id), [1])
        XCTAssertNil(result.completed)
        XCTAssertTrue(result.failed)
    }

    func testSharedScanRejectsDuplicatesAndCatalogDriftWithoutCommitting() async throws {
        for duplicate in [true, false] {
            let root = temporaryTestRoot("shared-map-invalid"); defer { try? FileManager.default.removeItem(at: root) }
            let transport = try SharedMapTransport()
            if duplicate { await transport.setDuplicate() } else { await transport.setDrift() }
            let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
            let result = await scan(repository)
            XCTAssertTrue(result.failed)
            XCTAssertNil(result.completed)
            let state = try await repository.store.metadataState(repository.metadataNamespace(for: .library(.shared)))
            XCTAssertFalse(state.inventoryComplete)
        }
    }

    func testSharedInventoryResetRevalidatesAndInvalidatesOldPin() async throws {
        let root = temporaryTestRoot("shared-map-reset"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedMapTransport()
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        let initial = await scan(repository)
        let value = try XCTUnwrap(initial.completed)
        let pin = try await repository.registerMapFilter(itemIDs: [1], locationRevision: value.revision)
        try await repository.clearMetadataCache()
        let authority = await repository.selectionAuthority(collection: pin.descriptor, snapshot: pin.snapshot)
        XCTAssertNil(authority)
        let result = await scan(repository)
        XCTAssertNotNil(result.completed)
        let batchCalls = await transport.batchCalls
        XCTAssertEqual(batchCalls, 2)
    }
}
