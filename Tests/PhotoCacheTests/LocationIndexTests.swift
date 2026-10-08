import Foundation
import TimelineCore
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor LocationFakeTransport: PhotosTransport {
    var timelineSnapshot = TimelineSnapshot(sections: [])
    var pages: [Int: [PhotoItem]] = [:]
    var scanCalls: [Int] = []
    var timelineCalls = 0
    var pageFailure: String?
    var failScanAfterFirstPage = false

    func configure(timelineSnapshot: TimelineSnapshot,
                   pages: [Int: [PhotoItem]],
                   pageFailure: String? = nil,
                   failScanAfterFirstPage: Bool = false) {
        self.timelineSnapshot = timelineSnapshot
        self.pages = pages
        self.pageFailure = pageFailure
        self.failScanAfterFirstPage = failScanAfterFirstPage
    }

    func login(credentials: SynologyCredentials) async throws {}

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        timelineCalls += 1
        return timelineSnapshot
    }

    func albums() async throws -> [AlbumSummary] { throw TestFailure("Unexpected album-list request") }

    func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot {
        throw TestFailure("Unexpected album-timeline request")
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        throw TestFailure("Unexpected item-page request")
    }

    func locationScanPage(offset: Int, limit: Int) async throws -> [PhotoItem] {
        scanCalls.append(offset)
        if failScanAfterFirstPage, scanCalls.count > 1 { throw TestFailure("Scan failed") }
        if let pageFailure { throw TestFailure(pageFailure) }
        return pages[offset] ?? []
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        throw TestFailure("Unexpected favorite write")
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        throw TestFailure("Unexpected thumbnail request")
    }

    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse {
        throw TestFailure("Unexpected original-image request")
    }
}

final class LocationIndexTests: XCTestCase {
    private let server = URL(string: "https://example.invalid")!
    private let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")
    private let day = Int64(1_704_067_200)

    private func root() -> URL { temporaryTestRoot("SynoLocationTest") }

    private func makeRepository(root: URL, transport: LocationFakeTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    private func section(limit: Int = 5) -> TimelineSection {
        TimelineSection(offset: 0, limit: limit,
                        list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: limit)])
    }

    private func item(_ id: Int64, lat: Double? = nil, lon: Double? = nil) throws -> PhotoItem {
        var gps = ""
        if let lat, let lon {
            gps = ",\"gps\":{\"latitude\":\(lat),\"longitude\":\(lon)}"
        }
        let json = """
        {"id":\(id),"time":\(day + id),"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"\(id)_rev"}\(gps)}}
        """
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func loadTimeline(_ repository: CachedPhotosRepository) async {
        for await _ in await repository.timeline() {}
    }

    private func runIndex(_ repository: CachedPhotosRepository) async -> [LocationIndexEvent] {
        var events: [LocationIndexEvent] = []
        for await event in await repository.locationIndex() { events.append(event) }
        return events
    }

    private func completedRecords(_ events: [LocationIndexEvent]) -> [PhotoLocationRecord] {
        for case .completed(let value, _) in events { return value.records }
        return []
    }

    func testScanPaginationStopsOnEmptyPage() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocationFakeTransport()
        let fullPage = try (1...LocationScanTestLimit.value).map { try item(Int64($0), lat: 10, lon: 20) }
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 2000)]),
                                  pages: [0: fullPage, 1000: [], 2000: []])
        let repository = try makeRepository(root: root, transport: transport)
        await loadTimeline(repository)

        let events = await runIndex(repository)
        let records = completedRecords(events)
        XCTAssertEqual(records.count, fullPage.count)
        XCTAssertTrue(records.allSatisfy { $0.coordinate == PhotoCoordinate(latitude: 10, longitude: 20) })
        let calls = await transport.scanCalls
        XCTAssertTrue(calls.contains(0))
        XCTAssertTrue(calls.contains(1000))
        XCTAssertFalse(calls.contains(3000), "The scan must stop after the empty page")
    }

    func testRecordsFilterMissingAndInvalidGPS() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocationFakeTransport()
        let items = [
            try item(1, lat: 35.5, lon: 139.25),
            try item(2),
            try item(3, lat: 120, lon: 10),
            try item(4, lat: -33.86, lon: 151.21),
        ]
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 4)]),
                                  pages: [0: items])
        let repository = try makeRepository(root: root, transport: transport)
        await loadTimeline(repository)

        let records = completedRecords(await runIndex(repository))
        XCTAssertEqual(records.map(\.id), [1, 4])
        XCTAssertEqual(records.first?.thumbnail?.unitID, 1)
        XCTAssertEqual(records.first?.time, day + 1)
    }

    func testProgressUsesExactTimelineTotal() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocationFakeTransport()
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 2,
                            list: [TimelineDay(year: 2024, month: 1, day: 2, itemCount: 2)]),
            TimelineSection(offset: 0, limit: 3,
                            list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 3)]),
        ])
        await transport.configure(timelineSnapshot: snapshot,
                                  pages: [0: [try item(1, lat: 1, lon: 1), try item(2, lat: 2, lon: 2)]])
        let repository = try makeRepository(root: root, transport: transport)
        await loadTimeline(repository)

        let events = await runIndex(repository)
        var progress: [(Int, Int?)] = []
        for case .progress(let scanned, let total) in events { progress.append((scanned, total)) }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.0, 2)
        XCTAssertEqual(progress.first?.1, 5)
    }

    func testEqualFingerprintSkipsScanOnSecondRepository() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [section(limit: 2)])
        let firstTransport = LocationFakeTransport()
        await firstTransport.configure(timelineSnapshot: snapshot,
                                       pages: [0: [try item(1, lat: 1, lon: 1)]])
        let first = try makeRepository(root: root, transport: firstTransport)
        await loadTimeline(first)
        let firstEvents = await runIndex(first)
        XCTAssertEqual(completedRecords(firstEvents).map(\.id), [1])
        let firstCalls = await firstTransport.scanCalls
        XCTAssertEqual(firstCalls, [0, 1000])

        let secondTransport = LocationFakeTransport()
        await secondTransport.configure(timelineSnapshot: snapshot, pages: [:])
        let second = try makeRepository(root: root, transport: secondTransport)
        await loadTimeline(second)
        var cached: [PhotoLocationRecord] = []
        var completed = false
        for await event in await second.locationIndex() {
            switch event {
            case .cached(let value): cached = value.records
            case .completed(let value, let verified):
                completed = true
                XCTAssertTrue(verified)
                XCTAssertEqual(value.records.map(\.id), [1])
            case .progress, .failure:
                XCTFail("A verified cached index must not scan")
            }
        }
        XCTAssertEqual(cached.map(\.id), [1])
        XCTAssertTrue(completed)
        let secondCalls = await secondTransport.scanCalls
        XCTAssertTrue(secondCalls.isEmpty, "A matching fingerprint must skip the network entirely")
    }

    func testIndexOpenedBeforeLibraryLoadValidatesTimelineBeforeReusingCachedPayload() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [section(limit: 2)])
        let firstTransport = LocationFakeTransport()
        await firstTransport.configure(timelineSnapshot: snapshot,
                                       pages: [0: [try item(1, lat: 1, lon: 1)]])
        let first = try makeRepository(root: root, transport: firstTransport)
        await loadTimeline(first)
        _ = await runIndex(first)

        let secondTransport = LocationFakeTransport()
        await secondTransport.configure(timelineSnapshot: snapshot,
                                        pages: [0: [try item(9, lat: 9, lon: 9)]])
        let second = try makeRepository(root: root, transport: secondTransport)

        // Deliberately open Map before the app's eager timeline load. The location
        // pipeline must validate/join that resource itself before trusting the old
        // fingerprint, rather than scanning with a nil fingerprint or blessing a
        // merely cached timeline from this run.
        let events = await runIndex(second)
        XCTAssertEqual(completedRecords(events).map(\.id), [1])
        let timelineCalls = await secondTransport.timelineCalls
        let scanCalls = await secondTransport.scanCalls
        XCTAssertEqual(timelineCalls, 1)
        XCTAssertTrue(scanCalls.isEmpty)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let stored = try await second.store.get(CacheKey.locationIndex(namespace: namespace))
        let payload = try JSONDecoder().decode(LocationIndexPayload.self,
                                               from: try XCTUnwrap(stored).data)
        XCTAssertEqual(payload.sourceTimelineFingerprint,
                       LibraryIndex(snapshot: snapshot).fingerprint)
    }

    func testIndexOpenedBeforeLibraryLoadStoresTheAuthoritativeChangedFingerprint() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocationFakeTransport()
        let changed = TimelineSnapshot(sections: [section(limit: 3)])
        await transport.configure(timelineSnapshot: changed,
                                  pages: [0: [try item(2, lat: 2, lon: 2)]])
        let repository = try makeRepository(root: root, transport: transport)

        let events = await runIndex(repository)
        XCTAssertEqual(completedRecords(events).map(\.id), [2])
        let timelineCalls = await transport.timelineCalls
        XCTAssertEqual(timelineCalls, 2, "A cold Personal Library validates through initial and full timeline requests")

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let stored = try await repository.store.get(CacheKey.locationIndex(namespace: namespace))
        let payload = try JSONDecoder().decode(LocationIndexPayload.self,
                                               from: try XCTUnwrap(stored).data)
        XCTAssertEqual(payload.sourceTimelineFingerprint,
                       LibraryIndex(snapshot: changed).fingerprint)
    }

    func testDifferingFingerprintRescansAndReplacesPayload() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let firstTransport = LocationFakeTransport()
        await firstTransport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 1)]),
                                       pages: [0: [try item(1, lat: 1, lon: 1)]])
        let first = try makeRepository(root: root, transport: firstTransport)
        await loadTimeline(first)
        _ = await runIndex(first)

        let secondTransport = LocationFakeTransport()
        let changed = TimelineSnapshot(sections: [section(limit: 3)])
        await secondTransport.configure(timelineSnapshot: changed,
                                        pages: [0: [try item(2, lat: 2, lon: 2), try item(3, lat: 3, lon: 3)]])
        let second = try makeRepository(root: root, transport: secondTransport)
        await loadTimeline(second)
        let events = await runIndex(second)
        XCTAssertEqual(completedRecords(events).map(\.id), [2, 3])
        let calls = await secondTransport.scanCalls
        XCTAssertFalse(calls.isEmpty)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let stored = try await second.store.get(CacheKey.locationIndex(namespace: namespace))
        let payload = try JSONDecoder().decode(LocationIndexPayload.self,
                                               from: try XCTUnwrap(stored).data)
        XCTAssertEqual(payload.records.map(\.id), [2, 3])
        XCTAssertEqual(payload.scannedItemCount, 2)
        XCTAssertEqual(payload.sourceTimelineFingerprint, LibraryIndex(snapshot: changed).fingerprint)
    }

    func testFailureAfterCachedEmissionKeepsCachedRecords() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let firstTransport = LocationFakeTransport()
        await firstTransport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 1)]),
                                       pages: [0: [try item(1, lat: 1, lon: 1)]])
        let first = try makeRepository(root: root, transport: firstTransport)
        await loadTimeline(first)
        _ = await runIndex(first)

        let secondTransport = LocationFakeTransport()
        await secondTransport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 2)]),
                                        pages: [0: [try item(9, lat: 9, lon: 9)]],
                                        pageFailure: "Network unavailable")
        let second = try makeRepository(root: root, transport: secondTransport)
        await loadTimeline(second)
        var cached: [PhotoLocationRecord] = []
        var failure: String?
        var completed = false
        for await event in await second.locationIndex() {
            switch event {
            case .cached(let value): cached = value.records
            case .failure(let message): failure = message
            case .completed: completed = true
            case .progress: break
            }
        }
        XCTAssertEqual(cached.map(\.id), [1])
        XCTAssertNotNil(failure)
        XCTAssertFalse(completed)
    }

    func testPayloadSchemaDiscardForcesRescan() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [section(limit: 1)])
        let transport = LocationFakeTransport()
        await transport.configure(timelineSnapshot: snapshot,
                                  pages: [0: [try item(5, lat: 5, lon: 5)]])
        let repository = try makeRepository(root: root, transport: transport)
        await loadTimeline(repository)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let stale = LocationIndexPayload(schemaVersion: 99,
                                         sourceTimelineFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
                                         scannedItemCount: 1,
                                         records: [])
        try await repository.store.put(CacheKey.locationIndex(namespace: namespace), kind: .locationIndex,
                                       data: JSONEncoder().encode(stale), validatedRun: nil)

        let events = await runIndex(repository)
        XCTAssertTrue(events.contains { if case .cached = $0 { return true } else { return false } } == false)
        XCTAssertEqual(completedRecords(events).map(\.id), [5])
        let calls = await transport.scanCalls
        XCTAssertFalse(calls.isEmpty)

        let stored = try await repository.store.get(CacheKey.locationIndex(namespace: namespace))
        let payload = try JSONDecoder().decode(LocationIndexPayload.self,
                                               from: try XCTUnwrap(stored).data)
        XCTAssertEqual(payload.schemaVersion, LocationIndexPayload.currentSchemaVersion)
    }

    func testPayloadRoundTripThroughCache() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocationFakeTransport()
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 1)]),
                                  pages: [0: [try item(7, lat: 48.8584, lon: 2.2945)]])
        let repository = try makeRepository(root: root, transport: transport)
        await loadTimeline(repository)
        _ = await runIndex(repository)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let stored = try await repository.store.get(CacheKey.locationIndex(namespace: namespace))
        let entry = try XCTUnwrap(stored)
        XCTAssertEqual(entry.kind, .locationIndex)
        let payload = try JSONDecoder().decode(LocationIndexPayload.self, from: entry.data)
        XCTAssertEqual(payload.schemaVersion, LocationIndexPayload.currentSchemaVersion)
        XCTAssertEqual(payload.records.count, 1)
        XCTAssertEqual(payload.records.first?.coordinate,
                       PhotoCoordinate(latitude: 48.8584, longitude: 2.2945))
        XCTAssertEqual(payload.records.first?.thumbnail?.cacheKey, "7_rev")
        XCTAssertEqual(payload.scannedItemCount, 1)
    }

    func testRetentionClassMapping() async throws {
        XCTAssertEqual(CachePriorityPolicy.defaultClass(for: .locationIndex), .locationIndex)
        let timelineIndex = try XCTUnwrap(CachePriorityPolicy.highestToLowest.firstIndex(of: .activeTimeline))
        let locationIndex = try XCTUnwrap(CachePriorityPolicy.highestToLowest.firstIndex(of: .locationIndex))
        let pageIndex = try XCTUnwrap(CachePriorityPolicy.highestToLowest.firstIndex(of: .metadataPage))
        XCTAssertEqual(locationIndex, timelineIndex + 1)
        XCTAssertLessThan(locationIndex, pageIndex)

        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocationFakeTransport()
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [section(limit: 1)]),
                                  pages: [0: [try item(1, lat: 1, lon: 1)]])
        let repository = try makeRepository(root: root, transport: transport)
        await loadTimeline(repository)
        _ = await runIndex(repository)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let retention = try await repository.store.retentionClass(forKey: CacheKey.locationIndex(namespace: namespace))
        XCTAssertEqual(retention, .locationIndex)
    }
}

private enum LocationScanTestLimit {
    /// Mirrors the repository's 1000-item scan page so a full page continues the scan.
    static let value = 1000
}
