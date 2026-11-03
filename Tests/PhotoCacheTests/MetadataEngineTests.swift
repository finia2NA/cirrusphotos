import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor EngineTransport: TestPhotosTransport {
    var versionCalls = 0
    var changeCalls = 0
    var mode: Mode
    enum Mode: Sendable { case empty, partial, tooLarge, rejected, unsupported, offline }
    init(_ mode: Mode) { self.mode = mode }
    func diffVersion() async throws -> DiffCursor {
        versionCalls += 1
        return DiffCursor(diffVersion: 100, versionTime: 100)
    }
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        changeCalls += 1
        switch mode {
        case .empty: return PhotoDiff(cursor: .init(diffVersion: 2, versionTime: 2), modifiedItemIDs: [], deletedItemIDs: [])
        case .partial: return PhotoDiff(cursor: .init(diffVersion: 2, versionTime: 2), modifiedItemIDs: [], deletedItemIDs: [], hasNext: true)
        case .tooLarge: throw SynologyAPIError.responseTooLarge(4 * 1024 * 1024)
        case .rejected: throw SynologyAPIError.api(700)
        case .unsupported: throw SynologyAPIError.api(103)
        case .offline: throw SynologyAPIError.transport("fixture offline")
        }
    }
    func counts() -> (Int, Int) { (versionCalls, changeCalls) }
}
private actor FavoriteEventTransport: TestPhotosTransport {
    let unsupported: Bool
    init(unsupported: Bool) { self.unsupported = unsupported }
    func diffVersion() async throws -> DiffCursor { DiffCursor(diffVersion: 100, versionTime: 100) }
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        PhotoDiff(cursor: .init(diffVersion: 2, versionTime: 2), modifiedItemIDs: [], deletedItemIDs: [])
    }
    func userEvents(since cursor: DiffCursor) async throws -> UserEventDiff {
        guard cursor.diffVersion == 1 else { return UserEventDiff(cursor: .init(diffVersion: 2, versionTime: 2), favorites: []) }
        return UserEventDiff(cursor: .init(diffVersion: 2, versionTime: 2), favorites: [.init(itemIDs: [5], favorite: true)],
                             hasUnsupportedActivity: unsupported)
    }
}
final class MetadataEngineTests: XCTestCase, @unchecked Sendable {
    private func repository(_ transport: EngineTransport, root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: .init(username: "fixture", password: "fixture", otpSecret: nil), cacheRoot: root, transport: transport)
    }
    private func seedCheckpoint(_ repository: CachedPhotosRepository) async throws -> MetadataStoreVersion {
        try await repository.initializeMetadataEngine()
        let namespace = await repository.personalMetadataNamespace
        let store = await repository.store
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: true, currentRun: "prior", admission: store.metadataAdmission(namespace))
        return try await store.metadataState(namespace)
    }
    func testOneSourceCheckServesAllConcurrentDemands() async throws {
        let root = temporaryTestRoot("engine-shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = EngineTransport(.empty)
        let repository = try repository(transport, root: root)
        _ = try await seedCheckpoint(repository)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await repository.reconcileMetadataSource() } }
            try await group.waitForAll()
        }
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 1)
        let state = try await repository.store.metadataState(repository.personalMetadataNamespace)
        XCTAssertEqual(state.cursor, .init(diffVersion: 2, versionTime: 2))
        let run = await repository.runID
        XCTAssertEqual(state.proofRun, run, "An empty terminal interval proves cached content")
    }
    func testFavoriteEventsAdvanceTheCursorWithProofAndUnknownEventsRecover() async throws {
        for unsupported in [false, true] {
            let root = temporaryTestRoot("engine-favorite-events")
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "fixture", otpSecret: nil), cacheRoot: root,
                                                        transport: FavoriteEventTransport(unsupported: unsupported))
            let old = try await seedCheckpoint(repository)
            try await repository.reconcileMetadataSource()
            let state = try await repository.store.metadataState(repository.personalMetadataNamespace)
            if unsupported {
                XCTAssertEqual(state.resetEpoch, old.resetEpoch + 1); XCTAssertNil(state.proofRun)
            } else {
                XCTAssertEqual(state.resetEpoch, old.resetEpoch)
                XCTAssertEqual(state.cursor, .init(diffVersion: 2, versionTime: 2))
                let run = await repository.runID
                XCTAssertEqual(state.proofRun, run)
                XCTAssertEqual(state.revision, old.revision + 1, "Favorite changes supersede in-flight writes")
            }
        }
    }
    func testRejectedPartialOversizedIntervalsRecoverOnceAndUnsupportedInvalidatesWithoutProof() async throws {
        for mode in [EngineTransport.Mode.partial, .tooLarge, .rejected, .unsupported] {
            let root = temporaryTestRoot("engine-repair")
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = EngineTransport(mode)
            let repository = try repository(transport, root: root)
            let old = try await seedCheckpoint(repository)
            try await repository.reconcileMetadataSource()
            let state = try await repository.store.metadataState(repository.personalMetadataNamespace)
            XCTAssertEqual(state.resetEpoch, old.resetEpoch + 1)
            XCTAssertFalse(state.inventoryComplete)
            let counts = await transport.counts()
            XCTAssertEqual(counts.1, 1)
            switch mode {
            case .unsupported: XCTAssertNil(state.cursor); XCTAssertEqual(counts.0, 0)
            default: XCTAssertEqual(state.cursor, .init(diffVersion: 100, versionTime: 100)); XCTAssertEqual(counts.0, 1)
            }
        }
    }
    func testOfflineRetainsCheckpointWithoutRepairLoop() async throws {
        let root = temporaryTestRoot("engine-offline")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = EngineTransport(.offline)
        let repository = try repository(transport, root: root)
        let old = try await seedCheckpoint(repository)
        do { try await repository.reconcileMetadataSource(); XCTFail("Offline succeeded") } catch { }
        let current = try await repository.store.metadataState(repository.personalMetadataNamespace)
        XCTAssertEqual(current, old)
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 1)
    }
}
