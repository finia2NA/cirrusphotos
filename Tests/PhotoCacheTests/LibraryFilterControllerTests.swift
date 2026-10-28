import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class LibraryFilterControllerTests: XCTestCase {
    private func item(_ id: Int64, day: Int64, camera: String) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(id).JPG","time":\(day),"type":"photo",
         "additional":{"resolution":{"width":4000,"height":3000},"exif":{"camera":"\(camera)"}}}
        """.utf8))
    }

    private func sections(_ count: Int) -> [TimelineSection] {
        (0..<count).map { index in
            TimelineSection(offset: 0, limit: 1,
                list: [TimelineDay(year: 2024, month: 4, day: 20 - index, itemCount: 1)])
        }
    }

    private func repository(transport: ScannerTransport, root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: .init(username: "filter", password: "pw", otpSecret: "unused"),
                                   cacheRoot: root, transport: transport)
    }

    func testPersistentFailureSettlesAndRetriesOnlyExplicitly() async throws {
        let root = temporaryTestRoot("FilterFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: sections(1))
        let transport = ScannerTransport(snapshot: snapshot, pages: [:], persistentFailures: [0])
        let controller = LibraryFilterController(repository: try repository(transport: transport, root: root),
                                                 snapshot: snapshot)
        await controller.loadInitialBatch()
        let firstSettled = await waitUntil { await transport.callCount(offset: 0) == 1 }
        XCTAssertTrue(firstSettled)
        try await Task.sleep(for: .milliseconds(80))
        let firstCount = await transport.callCount(offset: 0)
        XCTAssertEqual(firstCount, 1, "a failed section must not spin")

        await controller.retryFailed()
        let retrySettled = await waitUntil { await transport.callCount(offset: 0) == 2 }
        XCTAssertTrue(retrySettled)
        try await Task.sleep(for: .milliseconds(80))
        let retryCount = await transport.callCount(offset: 0)
        XCTAssertEqual(retryCount, 2, "one explicit retry admits one new request")
    }

    func testCacheDiscoveryFindsSparseCurrentTimelinePagesWithoutTransport() async throws {
        let root = temporaryTestRoot("FilterSparseCacheDiscovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSections = sections(6)
        let snapshot = TimelineSnapshot(sections: sourceSections)
        let transport = ScannerTransport(snapshot: snapshot, pages: [:])
        let repository = try repository(transport: transport, root: root)
        try await seedMetadataCatalog(snapshot, repository: repository)
        for index in [0, 3, 5] {
            let cached = try item(Int64(index + 1),
                                  day: 1_713_571_200 - Int64(index * 86_400),
                                  camera: "DSC-HX60")
            try await seedMetadataPage([cached], section: sourceSections[index], repository: repository)

        }
        let controller = LibraryFilterController(repository: repository, snapshot: snapshot)

        let initial = await controller.apply(LibraryFilter(cameras: ["DSC-HX60"]))
        XCTAssertTrue(initial.referencesBySection.isEmpty, "Apply must not wait for cache discovery")
        await controller.indexCachedPages()
        let event = await controller.currentEvent()
        XCTAssertEqual(event.registration?.referencesBySection.flatMap { $0 }.map(\.itemID), [1, 4, 6])
        XCTAssertEqual(event.catalog.cameras, ["DSC-HX60"])
        let calls = await transport.totalCalls()
        XCTAssertEqual(calls, 0)
    }

    func testCacheDiscoveryIgnoresPageOutsideCurrentTimeline() async throws {
        let root = temporaryTestRoot("FilterObsoleteCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = sections(2)
        let obsolete = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2020, month: 1, day: 1, itemCount: 1)])
        let snapshot = TimelineSnapshot(sections: current)
        let transport = ScannerTransport(snapshot: snapshot, pages: [:])
        let repository = try repository(transport: transport, root: root)
        let cached = try item(99, day: 1_577_836_800, camera: "Obsolete")
        try await seedMetadataPage([cached], section: obsolete, repository: repository)


        let registration = await LibraryFilterController(repository: repository, snapshot: snapshot)
            .apply(LibraryFilter(cameras: ["Obsolete"]))

        XCTAssertTrue(registration.referencesBySection.flatMap { $0 }.isEmpty)
        let calls = await transport.totalCalls()
        XCTAssertEqual(calls, 0)
    }

    func testLateProvisionalCannotReplaceVerifiedRecords() async throws {
        let root = temporaryTestRoot("FilterVerifiedPrecedence")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: sections(1))
        let transport = ScannerTransport(snapshot: snapshot, pages: [:])
        let controller = LibraryFilterController(
            repository: try repository(transport: transport, root: root), snapshot: snapshot
        )
        let verified = try item(1, day: 1_713_571_200, camera: "Current")
        let stale = try item(1, day: 1_713_571_200, camera: "Stale")
        await controller.ingest(sectionIndex: 0, items: [verified], verified: true)
        await controller.ingest(sectionIndex: 0, items: [stale], verified: false)

        let current = await controller.apply(LibraryFilter(cameras: ["Current"]))
        XCTAssertEqual(current.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
        let staleResult = await controller.apply(LibraryFilter(cameras: ["Stale"]))
        XCTAssertTrue(staleResult.referencesBySection.flatMap { $0 }.isEmpty)
    }

    func testDirectionalDemandIsBoundedAndUsesVisibleSourceAnchor() async throws {
        let root = temporaryTestRoot("FilterDirectionalDemand")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSections = sections(20)
        let snapshot = TimelineSnapshot(sections: sourceSections)
        var pages: [Int: [PhotoItem]] = [:]
        for index in sourceSections.indices {
            pages[index] = [try item(Int64(index + 1), day: 1_713_571_200 - Int64(index * 86_400), camera: "Other")]
        }
        let transport = ScannerTransport(snapshot: snapshot, pages: pages, delay: .milliseconds(10))
        let controller = LibraryFilterController(
            repository: try repository(transport: transport, root: root), snapshot: snapshot
        )
        let anchor = try item(11, day: 1_713_571_200 - 10 * 86_400, camera: "Anchor")
        await controller.ingest(sectionIndex: 10, items: [anchor], verified: true)
        _ = await controller.apply(LibraryFilter(cameras: ["Anchor"]))

        await controller.demandVisibleResultSections([0], direction: .older, userScrollGeneration: 1)
        let loadedOlder = await waitUntil { await transport.totalCalls() == 8 }
        XCTAssertTrue(loadedOlder)
        let olderOffsets = await transport.calledOffsets()
        XCTAssertEqual(olderOffsets, Set(11...18))
        await controller.demandVisibleResultSections([0], direction: .newer, userScrollGeneration: 2)
        let loadedNewer = await waitUntil { await transport.totalCalls() == 16 }
        XCTAssertTrue(loadedNewer)
        let allOffsets = await transport.calledOffsets()
        let maximum = await transport.maximumConcurrentReads()
        XCTAssertEqual(allOffsets, Set(2...9).union(11...18))
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    func testFailedSectionDoesNotBlockLoadingOlderUnseenSections() async throws {
        let root = temporaryTestRoot("FilterFailureProgress")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSections = sections(10)
        var pages: [Int: [PhotoItem]] = [:]
        for index in sourceSections.indices {
            pages[index] = [try item(Int64(index + 1),
                                     day: 1_713_571_200 - Int64(index * 86_400),
                                     camera: "C\(index)")]
        }
        let snapshot = TimelineSnapshot(sections: sourceSections)
        let transport = ScannerTransport(snapshot: snapshot, pages: pages,
                                         persistentFailures: [0])
        let controller = LibraryFilterController(
            repository: try repository(transport: transport, root: root),
            snapshot: snapshot
        )

        await controller.loadInitialBatch()
        let firstBatchLoaded = await waitUntil { await transport.totalCalls() == 8 }
        XCTAssertTrue(firstBatchLoaded)
        await controller.loadInitialBatch()
        let secondBatchLoaded = await waitUntil { await transport.totalCalls() == 10 }
        XCTAssertTrue(secondBatchLoaded)
        let failedCalls = await transport.callCount(offset: 0)
        XCTAssertEqual(failedCalls, 1,
                       "tail loading must not implicitly retry the failed section")
    }

    func testCachedProvisionalIsReplacedByVerifiedCatalog() async throws {
        let root = temporaryTestRoot("FilterReplacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let section = sections(1)[0]
        let cached = try item(1, day: 1_713_571_200, camera: "Cached Camera")
        let current = try item(1, day: 1_713_571_200, camera: "Current Camera")
        let snapshot = TimelineSnapshot(sections: [section])
        let repository = try repository(transport: ScannerTransport(snapshot: snapshot, pages: [0: [current]]), root: root)
        try await seedMetadataPage([cached], section: section, repository: repository)

        let controller = LibraryFilterController(repository: repository, snapshot: snapshot)
        let box = FilterEventBox()
        let observation = Task {
            for await event in await controller.observe() { await box.record(event) }
        }
        await controller.indexCachedPages()
        await controller.loadInitialBatch()
        let replaced = await waitUntil { await box.verified == 1 }
        XCTAssertTrue(replaced)
        observation.cancel()
        let sawCached = await box.sawCamera("Cached Camera")
        let latest = await box.latestCatalog()
        XCTAssertTrue(sawCached)
        XCTAssertEqual(latest, ["Current Camera"])
    }

    func testVideoOnlyFilterPublishesMatchingResultAndCameraCatalog() async throws {
        let root = temporaryTestRoot("FilterVideoOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let section = TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 20, itemCount: 2)])
        let photo = try item(1, day: 1_713_571_200, camera: "Photo Camera")
        let video = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":2,"filename":"clip.MOV","time":1713571200,"type":"video",
         "additional":{"resolution":{"width":1920,"height":1080},
         "exif":{"camera":"Video Camera"}}}
        """.utf8))
        let snapshot = TimelineSnapshot(sections: [section])
        let transport = ScannerTransport(snapshot: snapshot, pages: [0: [photo, video]])
        let controller = LibraryFilterController(
            repository: try repository(transport: transport, root: root),
            snapshot: snapshot
        )
        let box = FilterEventBox()
        let observation = Task {
            for await event in await controller.observe() { await box.record(event) }
        }
        await controller.ingest(sectionIndex: 0, items: [photo, video], verified: true)
        let registration = await controller.apply(LibraryFilter(mediaKinds: [.video]))
        observation.cancel()

        XCTAssertEqual(registration.referencesBySection.flatMap { $0 }.map(\.itemID), [2])
        let cameras = await box.latestCatalog()
        XCTAssertEqual(Set(cameras), ["Photo Camera", "Video Camera"])
    }

    func testDerivedPageRestoresSparseSyntheticOrder() async throws {
        let root = temporaryTestRoot("FilterSparse")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSections = [TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 20, itemCount: 2)])]
        let first = try item(1, day: 1_713_571_200, camera: "A")
        let second = try item(2, day: 1_713_571_200, camera: "B")
        let snapshot = TimelineSnapshot(sections: sourceSections)
        let transport = ScannerTransport(snapshot: snapshot, pages: [0: [first, second]])
        let repository = try repository(transport: transport, root: root)
        for await _ in await repository.timeline(collection: .personalLibrary) {}
        let synthetic = TimelineSection(offset: 0, limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 20, itemCount: 2)])
        let descriptor = PhotoCollectionDescriptor.libraryFilter(UUID())
        let registration = LibraryFilterRegistration(descriptor: descriptor,
            snapshot: TimelineSnapshot(sections: [synthetic]),
            referencesBySection: [[
                .init(sourceSectionIndex: 0, sourcePageOffset: 1, itemID: second.id),
                .init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: first.id),
            ]], filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: snapshot).fingerprint)
        try await repository.registerLibraryFilter(registration)
        var result: [PhotoItem] = []
        for await event in await repository.page(synthetic, collection: descriptor) {
            if case .value(let items, let verified) = event, verified { let items = items.completeItems ?? []; result = items }
        }
        XCTAssertEqual(result.map(\.id), [2, 1])
    }
}

private actor FilterEventBox {
    private var events: [LibraryFilterControllerEvent] = []
    var verified: Int { events.last?.progress.verified ?? 0 }
    func record(_ event: LibraryFilterControllerEvent) { events.append(event) }
    func sawCamera(_ value: String) -> Bool { events.contains { $0.catalog.cameras.contains(value) } }
    func latestCatalog() -> [String] { events.last?.catalog.cameras ?? [] }
}

private actor ScannerTransport: PhotosTransport {
    let snapshot: TimelineSnapshot
    let pages: [Int: [PhotoItem]]
    let persistentFailures: Set<Int>
    let delay: Duration
    private var calls: [Int: Int] = [:]
    private var active = 0
    private var maximumActive = 0

    init(snapshot: TimelineSnapshot, pages: [Int: [PhotoItem]],
         persistentFailures: Set<Int> = [], delay: Duration = .zero) {
        self.snapshot = snapshot; self.pages = pages
        self.persistentFailures = persistentFailures; self.delay = delay
    }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(snapshot, initial: initial)
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let indices = snapshot.sections.indices.filter { position in
            guard let bounds = snapshot.sections[position].dateBounds else { return false }
            return bounds.start >= request.oldestDay.startTime && bounds.end <= request.newestDay.endTime
        }
        for index in indices { calls[index, default: 0] += 1 }
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        if indices.contains(where: persistentFailures.contains) { throw TestFailure("persistent failure") }
        let rows = try indices.flatMap { index in
            try pages[index, default: []].map { try fixtureItem($0, on: CaptureDay(time: snapshot.sections[index].dateBounds!.start)) }
        }
        return .init(items: Array(rows.dropFirst(request.offset).prefix(request.limit)), profile: fields)
    }
    func items(ids: [Int64]) async throws -> [PhotoItem] {
        let rows = Dictionary(pages.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { rows[$0] }
    }

    func callCount(offset: Int) -> Int { calls[offset, default: 0] }
    func totalCalls() -> Int { calls.values.reduce(0, +) }
    func maximumConcurrentReads() -> Int { maximumActive }
    func calledOffsets() -> Set<Int> { Set(calls.keys) }
}
