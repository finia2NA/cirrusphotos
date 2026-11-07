import Foundation
import TimelineCore
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor InventoryTransport: TestPhotosTransport {
    let items: [PhotoItem]
    let catalogCount: Int
    let supported: Bool
    let offline: Bool
    let changeOnCall: Int?
    let changedIDs: [Int64]
    let mergedIDs: [Int64]
    var scans = 0
    var changes = 0
    var catalogs = 0
    var failScan = false
    func setScanFailure() { failScan = true }
    init(items: [PhotoItem], count: Int? = nil, supported: Bool = true, offline: Bool = false, changeOnCall: Int? = nil,
         changedIDs: [Int64] = [2], mergedIDs: [Int64] = []) {
        self.items = items; catalogCount = count ?? items.count; self.supported = supported; self.offline = offline; self.changeOnCall = changeOnCall
        self.changedIDs = changedIDs; self.mergedIDs = mergedIDs
    }
    func login(credentials: SynologyCredentials) async throws { if offline { throw SynologyAPIError.transport("fixture offline") } }
    func diffVersion(space: PhotoSpace) async throws -> DiffCursor {
        guard supported else { throw SynologyAPIError.api(103) }
        return .init(diffVersion: 1, versionTime: 1)
    }
    func changes(since cursor: DiffCursor, space: PhotoSpace) async throws -> PhotoDiff {
        changes += 1
        return .init(cursor: .init(diffVersion: Int64(changes + 1), versionTime: Int64(changes + 1)), modifiedItemIDs: changeOnCall == changes ? changedIDs : [], deletedItemIDs: [],
                     mergedItemIDs: changeOnCall == changes ? mergedIDs : [])
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        catalogs += 1
        return try CollectionDayCatalog(days: catalogCount == 0 ? [] : [.init(day: CaptureDay(year: 2024, month: 1, day: 1), count: catalogCount)], completeness: initial ? .partial : .complete)
    }
    func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem] {
        scans += 1
        if failScan { throw SynologyAPIError.transport("fixture scan unavailable") }
        guard offset < items.count else { return [] }
        return Array(items[offset..<min(offset + limit, items.count)])
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { items.filter { ids.contains($0.id) } }
    func counts() -> (scans: Int, changes: Int, catalogs: Int) { (scans, changes, catalogs) }
}
final class LocationIndexTests: XCTestCase, @unchecked Sendable {
    private func item(_ id: Int64, located: Bool) throws -> PhotoItem {
        let gps = located ? #", "additional":{"gps":{"latitude":10,"longitude":20}}"# : ""
        return try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":1704067200,\"type\":\"photo\"\(gps)}".utf8))
    }
    private func repository(root: URL, transport: InventoryTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: .init(username: "inventory", password: "unused"), cacheRoot: root, transport: transport)
    }
    private func events(_ repository: CachedPhotosRepository) async -> [LocationIndexEvent] {
        var result: [LocationIndexEvent] = []
        for await event in await repository.locationIndex(space: .personal) { result.append(event) }
        return result
    }
    private func completed(_ events: [LocationIndexEvent]) -> [PhotoLocationRecord]? {
        for case .completed(let value, true) in events { return value.records }
        return nil
    }
    func testCompleteInventoryIncludesItemsWithoutGPSAndMapIsOnlyAProjection() async throws {
        let root = temporaryTestRoot("inventory-complete"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try InventoryTransport(items: [item(1, located: true), item(2, located: false)])
        let repository = try repository(root: root, transport: transport)
        let output = await events(repository)
        XCTAssertEqual(completed(output)?.map(\.id), [1])
        let namespace = await repository.personalMetadataNamespace
        let all = try await repository.store.metadataItemTimes(namespace, ids: [1, 2])
        XCTAssertEqual(Set(all.map(\.id)), [1, 2])
        let state = try await repository.store.metadataState(namespace)
        XCTAssertTrue(state.inventoryComplete)
    }
    func testWarmUnchangedRelaunchUsesOneSharedSourceCheckAndNoScanOrCatalogRead() async throws {
        let root = temporaryTestRoot("inventory-warm"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try repository(root: root, transport: InventoryTransport(items: [item(1, located: true)]))
        let firstOutput = await events(first)
        XCTAssertNotNil(completed(firstOutput))
        let transport = InventoryTransport(items: [])
        let second = try repository(root: root, transport: transport)
        let output = await events(second)
        XCTAssertEqual(completed(output)?.map(\.id), [1])
        let counts = await transport.counts()
        XCTAssertEqual(counts.scans, 0); XCTAssertEqual(counts.catalogs, 0); XCTAssertEqual(counts.changes, 1)
        XCTAssertTrue(output.contains { if case .cached = $0 { true } else { false } })
    }
    func testDiffAddingAnItemKeepsTheInventoryWithoutAScan() async throws {
        let root = temporaryTestRoot("inventory-diff-add"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try repository(root: root, transport: InventoryTransport(items: [item(1, located: true)]))
        _ = await events(first)
        let transport = try InventoryTransport(items: [item(1, located: true), item(3, located: true)], changeOnCall: 1, changedIDs: [3])
        let second = try repository(root: root, transport: transport)
        let output = await events(second)
        XCTAssertEqual(completed(output)?.map(\.id).sorted(), [1, 3])
        let state = try await second.store.metadataState(second.personalMetadataNamespace)
        XCTAssertTrue(state.inventoryComplete)
        let counts = await transport.counts()
        XCTAssertEqual(counts.scans, 0)
    }
    func testLivePhotoMergeRemovesTheAbsorbedItemWithoutAScan() async throws {
        for alreadyIndexed in [false, true] {
            let root = temporaryTestRoot("inventory-merge-\(alreadyIndexed)"); defer { try? FileManager.default.removeItem(at: root) }
            let initial = try alreadyIndexed ? [item(1, located: true), item(9, located: false)] : [item(1, located: true)]
            let first = try repository(root: root, transport: InventoryTransport(items: initial))
            _ = await events(first)
            // The still (3) arrives in modify; its absorbed video item (9) is merged and no longer exists.
            let transport = try InventoryTransport(items: [item(1, located: true), item(3, located: true)], changeOnCall: 1,
                                                   changedIDs: [3], mergedIDs: [9])
            let second = try repository(root: root, transport: transport)
            let output = await events(second)
            XCTAssertEqual(completed(output)?.map(\.id).sorted(), [1, 3])
            let namespace = await second.personalMetadataNamespace
            let state = try await second.store.metadataState(namespace)
            XCTAssertTrue(state.inventoryComplete)
            let remaining = try await second.store.metadataItemTimes(namespace, ids: [9])
            XCTAssertTrue(remaining.isEmpty)
            let counts = await transport.counts()
            XCTAssertEqual(counts.scans, 0, "alreadyIndexed=\(alreadyIndexed)")
        }
    }
    func testMergeThatLeavesTheInventoryShortOfTheLibraryFallsBackToAScan() async throws {
        let root = temporaryTestRoot("inventory-merge-mismatch"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try repository(root: root, transport: InventoryTransport(items: [item(1, located: true)]))
        _ = await events(first)
        // The library lists an item the feed never named, so the merged interval cannot be trusted.
        let transport = try InventoryTransport(items: [item(1, located: true), item(3, located: true), item(4, located: true)],
                                               changeOnCall: 1, changedIDs: [3], mergedIDs: [9])
        let second = try repository(root: root, transport: transport)
        let output = await events(second)
        XCTAssertEqual(completed(output)?.map(\.id).sorted(), [1, 3, 4])
        let counts = await transport.counts()
        XCTAssertEqual(counts.scans, 1)
    }
    func testOfflineKeepsCachedPinsWithoutClaimingCompleteCurrentCoverage() async throws {
        let root = temporaryTestRoot("inventory-offline"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try repository(root: root, transport: InventoryTransport(items: [item(1, located: true)]))
        _ = await events(first)
        let second = try repository(root: root, transport: InventoryTransport(items: [], offline: true))
        let output = await events(second)
        XCTAssertTrue(output.contains { if case .cached(let value) = $0 { value.records.count == 1 } else { false } })
        XCTAssertNil(completed(output))
        XCTAssertTrue(output.contains { if case .failure = $0 { true } else { false } })
    }
    func testShortScanCannotCommitCompleteInventoryAgainstLargerCatalog() async throws {
        let root = temporaryTestRoot("inventory-incomplete"); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root: root, transport: InventoryTransport(items: [item(1, located: true)], count: 2))
        let repositoryOutput = await events(repository)
        XCTAssertNil(completed(repositoryOutput))
        let state = try await repository.store.metadataState(repository.personalMetadataNamespace)
        XCTAssertFalse(state.inventoryComplete)
    }
    func testUnsupportedSourceUsesAuthoritativeBaselineAgainOnNextRun() async throws {
        let root = temporaryTestRoot("inventory-conventional"); defer { try? FileManager.default.removeItem(at: root) }
        let photos = try [item(1, located: true)]
        let first = try repository(root: root, transport: InventoryTransport(items: photos, supported: false))
        let firstOutput = await events(first)
        XCTAssertNotNil(completed(firstOutput))
        let transport = InventoryTransport(items: photos, supported: false)
        let second = try repository(root: root, transport: transport)
        let secondOutput = await events(second)
        XCTAssertNotNil(completed(secondOutput))
        let counts = await transport.counts()
        XCTAssertEqual(counts.scans, 1)
    }
    func testChangesBeforeBaselineAreReconciledBeforeTheScanStarts() async throws {
        let root = temporaryTestRoot("inventory-before"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try InventoryTransport(items: [item(1, located: true), item(2, located: false)], changeOnCall: 1)
        let repository = try repository(root: root, transport: transport)
        let repositoryOutput = await events(repository)
        XCTAssertNotNil(completed(repositoryOutput))
        let counts = await transport.counts()
        XCTAssertEqual(counts.scans, 1)
    }
    func testChangesDuringBaselineInvalidateCoverageAndDoNotCommitPartialProjection() async throws {
        let root = temporaryTestRoot("inventory-during"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try InventoryTransport(items: [item(1, located: true), item(2, located: false)], changeOnCall: 2)
        let repository = try repository(root: root, transport: transport)
        let repositoryOutput = await events(repository)
        XCTAssertNil(completed(repositoryOutput))
        let state = try await repository.store.metadataState(repository.personalMetadataNamespace)
        XCTAssertFalse(state.inventoryComplete)
        let counts = await transport.counts()
        XCTAssertEqual(counts.scans, 1)
    }
    func testTrimmingInventoryCannotReuseSameRunMemoryProofForPartialPins() async throws {
        let root = temporaryTestRoot("inventory-trim"); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try InventoryTransport(items: [item(1, located: true)])
        let repository = try repository(root: root, transport: transport)
        let initial = await events(repository)
        XCTAssertNotNil(completed(initial))
        try await repository.store.setBudget(1)
        await transport.setScanFailure()
        let after = await events(repository)
        XCTAssertNil(completed(after))
        let state = try await repository.store.metadataState(repository.personalMetadataNamespace)
        XCTAssertFalse(state.inventoryComplete)
        let calls = await transport.counts()
        XCTAssertEqual(calls.scans, 1, "A budget too small for its catalog must not start a futile rebuild")
    }

}
