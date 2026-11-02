import Foundation
import TimelineCore
import XCTest
import SynologyAPI
@testable import PhotoCache

final class SelectionInfoResolverTests: XCTestCase {

    private func makeItem(id: Int64, time: Int64 = 1712102400, type: String = "photo",
                          filesize: Int64? = nil, latitude: Double? = nil,
                          longitude: Double? = nil) -> PhotoItem {
        let size = filesize.map { ",\"filesize\":\($0)" } ?? ""
        var gps = ""
        if let latitude, let longitude {
            gps = ",\"gps\":{\"latitude\":\(latitude),\"longitude\":\(longitude)}"
        }
        let json = """
        {"id":\(id),"filename":"IMG_\(id).jpg","time":\(time),"type":"\(type)"\(size),"additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key_\(id)","sm":"ready","m":"ready","xl":"ready"},"resolution":{"width":1000,"height":1000}\(gps)}}
        """
        return try! JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func makeRepository(transport: InfoResolverMockTransport, root: URL, snapshot: TimelineSnapshot) async throws -> CachedPhotosRepository {
        await transport.setSnapshot(snapshot)
        let creds = SynologyCredentials(username: "alice", password: "pw", otpSecret: "unused")
        return try CachedPhotosRepository(credentials: creds, budget: 100_000_000,
                                          cacheRoot: root, transport: transport)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, _ count: Int) -> TimelineDay {
        TimelineDay(year: year, month: month, day: day, itemCount: count)
    }

    private func start(_ section: TimelineSection) -> Int64 {
        section.dateBounds!.start
    }

    private func seedPage(_ items: [PhotoItem], section: TimelineSection,
                          repository: CachedPhotosRepository) async throws {
        try await seedMetadataPage(items, section: section, repository: repository)
    }

    private func collectAll(_ stream: AsyncStream<SelectionInfo>) async -> [SelectionInfo] {
        var results: [SelectionInfo] = []
        for await info in stream { results.append(info) }
        return results
    }

    func testAtomicSelectionFenceRejectsSameShapePageReplacement() async throws {
        let root = temporaryTestRoot("selection-membership-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let first = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        let second = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 1, 1)])
        let snapshot = TimelineSnapshot(sections: [first, second])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)
        let run = await repo.runID
        try await seedMetadataPage([makeItem(id: 1)], section: first, repository: repo, validatedRun: run)
        try await seedMetadataPage([makeItem(id: 2)], section: second, repository: repo, validatedRun: run)
        let namespace = await repo.personalMetadataNamespace
        let store = await repo.store
        let firstPage = try await store.metadataPage(DayPageAddress(section: first, collection: .library(.personal)), namespace: namespace, currentRun: run)
        let secondPage = try await store.metadataPage(DayPageAddress(section: second, collection: .library(.personal)), namespace: namespace, currentRun: run)
        let one = try XCTUnwrap(firstPage), two = try XCTUnwrap(secondPage)
        let proofs = [SelectionMembershipProof(address: one.address, revision: one.membershipRevision, offsetsAndIDs: [(0, 1)]),
                      SelectionMembershipProof(address: two.address, revision: two.membershipRevision, offsetsAndIDs: [(0, 2)])]
        let initiallyValid = try await store.verifySelectionMembership(proofs, namespace: namespace, currentRun: run)
        XCTAssertTrue(initiallyValid)
        try await seedMetadataPage([makeItem(id: 3)], section: first, repository: repo, validatedRun: run)
        let afterReplacement = try await store.verifySelectionMembership(proofs, namespace: namespace, currentRun: run)
        XCTAssertFalse(afterReplacement)
    }

    func testDownloadSelectionResolvesVerifiedPhotosAndRejectsChangedIdentity() async throws {
        let root = temporaryTestRoot("DownloadSelection")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let section = TimelineSection(offset: 0, limit: 3, list: [day(2024, 4, 3, 3)])
        await transport.setPage([makeItem(id: 1), makeItem(id: 2, type: "video"), makeItem(id: 3)], start: start(section))
        let snapshot = TimelineSnapshot(sections: [section])
        let repository = try await makeRepository(transport: transport, root: root, snapshot: snapshot)
        for await _ in await repository.timeline(collection: .library(.personal)) {}
        let selection = PhotoSelectionSnapshot(collection: .library(.personal), timeline: snapshot,
            timelineFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            selectedOrdinals: IndexSet(integersIn: 0...2), knownItemIDsByOrdinal: [0: 1])
        let allItems = await SelectionItemResolver(repository: repository).resolve(selection)
        XCTAssertEqual(allItems?.map(\.id), [1, 2, 3])
        let resolver = SelectionDownloadResolver(repository: repository)
        let result = await resolver.resolve(collection: .library(.personal), snapshot: snapshot,
                                            selectedOrdinals: IndexSet(integersIn: 0...2),
                                            knownItemIDsByOrdinal: [0: 1])
        XCTAssertEqual(result?.map(\.id), [1, 3])
        let changed = await resolver.resolve(collection: .library(.personal), snapshot: snapshot,
                                             selectedOrdinals: IndexSet(integer: 0),
                                             knownItemIDsByOrdinal: [0: 999])
        XCTAssertNil(changed)
    }

    func testSelectionAcrossTwoSectionsPublishesExactSummary() async throws {
        let root = temporaryTestRoot("TwoSections")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec0 = TimelineSection(offset: 0, limit: 2, list: [day(2024, 4, 3, 2)])
        let sec1 = TimelineSection(offset: 0, limit: 2, list: [day(2024, 4, 1, 2)])
        await transport.setPage([makeItem(id: 1, filesize: 100), makeItem(id: 2, filesize: 200)],
                                start: start(sec0))
        await transport.setPage([makeItem(id: 3, type: "video", filesize: 300),
                                 makeItem(id: 4, filesize: 400)], start: start(sec1))
        let snapshot = TimelineSnapshot(sections: [sec0, sec1])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...3))
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        let first = try XCTUnwrap(initial)
        XCTAssertEqual(first.itemCount, 4)
        XCTAssertEqual(first.newestDayID, "2024-04-03")
        XCTAssertEqual(first.oldestDayID, "2024-04-01")
        XCTAssertNil(first.cumulativeSize)
        XCTAssertFalse(first.isComplete)
        XCTAssertFalse(first.hadFailure)

        var last = first
        while let info = await iterator.next() { last = info }
        XCTAssertEqual(last.itemCount, 4)
        XCTAssertEqual(last.resolvedCount, 4)
        XCTAssertEqual(last.photoCount, 3)
        XCTAssertEqual(last.videoCount, 1)
        XCTAssertEqual(last.cumulativeSize, 1000)
        XCTAssertTrue(last.isComplete)
        XCTAssertFalse(last.hadFailure)
    }

    func testCachedThenVerifiedDoesNotDoubleCountSize() async throws {
        let root = temporaryTestRoot("CachedThenVerified")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        let item = makeItem(id: 1, filesize: 100)
        await transport.setPage([item], start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)
        try await seedPage([item], section: sec, repository: repo)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0))
        let emissions = await collectAll(stream)
        let sizes = emissions.compactMap(\.cumulativeSize)
        XCTAssertEqual(sizes, [100])
        XCTAssertEqual(emissions.last?.cumulativeSize, 100)
        XCTAssertEqual(emissions.last?.isComplete, true)
        XCTAssertEqual(emissions.last?.hadFailure, false)
    }

    func testVerifiedPageCanSupplySizeMissingFromCachedPage() async throws {
        let root = temporaryTestRoot("CachedMissingSize")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        await transport.setPage([makeItem(id: 1, filesize: 250)], start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)
        try await seedPage([makeItem(id: 1)], section: sec, repository: repo)

        let emissions = await collectAll(SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0)))

        XCTAssertEqual(emissions.last?.cumulativeSize, 250)
        XCTAssertEqual(emissions.last?.resolvedCount, 1)
        XCTAssertEqual(emissions.last?.isComplete, true)
        XCTAssertEqual(emissions.last?.hadFailure, false)
    }

    func testSingleOrdinalProducesItem() async throws {
        let root = temporaryTestRoot("SingleOrdinal")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        await transport.setPage([makeItem(id: 7, filesize: 12_345)], start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0))
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        let first = try XCTUnwrap(initial)
        XCTAssertEqual(first.itemCount, 1)
        XCTAssertNil(first.singleItem)

        var last = first
        while let info = await iterator.next() { last = info }
        XCTAssertEqual(last.singleItem?.id, 7)
        XCTAssertEqual(last.cumulativeSize, 12_345)
        XCTAssertTrue(last.isComplete)
    }

    func testFailedPageKeepsExactCountAndDateWithoutSize() async throws {
        let root = temporaryTestRoot("FailedPage")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        await transport.setFailure(start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0))
        let emissions = await collectAll(stream)
        let last = try XCTUnwrap(emissions.last)
        XCTAssertEqual(last.itemCount, 1)
        XCTAssertEqual(last.newestDayID, "2024-04-03")
        XCTAssertEqual(last.oldestDayID, "2024-04-03")
        XCTAssertNil(last.cumulativeSize)
        XCTAssertTrue(last.isComplete)
        XCTAssertTrue(last.hadFailure)
    }

    func testCachedValueIsEmittedWithoutWaitingForVerification() async throws {
        let root = temporaryTestRoot("CachedFirst")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        let item = makeItem(id: 1, filesize: 100)
        await transport.setPage([item], start: start(sec))
        await transport.setBlocked(true)
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)
        try await seedPage([item], section: sec, repository: repo)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0))
        var iterator = stream.makeAsyncIterator()
        let initialValue = await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertNil(initial.cumulativeSize)
        XCTAssertFalse(initial.isComplete)

        let cachedValue = await iterator.next()
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertEqual(cached.cumulativeSize, 100)
        XCTAssertTrue(cached.isComplete)
        XCTAssertFalse(cached.hadFailure)

        await transport.releaseBlocked()
    }

    func testCoordinatesAccumulateAcrossSectionsInSelectionOrder() async throws {
        let root = temporaryTestRoot("CoordinatesAcross")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec0 = TimelineSection(offset: 0, limit: 2, list: [day(2024, 4, 3, 2)])
        let sec1 = TimelineSection(offset: 0, limit: 2, list: [day(2024, 4, 1, 2)])
        await transport.setPage([makeItem(id: 1, latitude: 10, longitude: 11),
                                 makeItem(id: 2, latitude: 20, longitude: 21)],
                                start: start(sec0))
        await transport.setPage([makeItem(id: 3, latitude: 30, longitude: 31),
                                 makeItem(id: 4, latitude: 40, longitude: 41)],
                                start: start(sec1))
        let snapshot = TimelineSnapshot(sections: [sec0, sec1])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...3))
        let emissions = await collectAll(stream)
        let last = try XCTUnwrap(emissions.last)
        XCTAssertEqual(last.coordinates, [
            PhotoCoordinate(latitude: 10, longitude: 11),
            PhotoCoordinate(latitude: 20, longitude: 21),
            PhotoCoordinate(latitude: 30, longitude: 31),
            PhotoCoordinate(latitude: 40, longitude: 41),
        ])
    }

    func testSectionReEmissionReplacesCoordinatesWithoutDuplicating() async throws {
        let root = temporaryTestRoot("CoordinatesReplace")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        let item = makeItem(id: 1, filesize: 100, latitude: 48.8584, longitude: 2.2945)
        await transport.setPage([item], start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)
        try await seedPage([item], section: sec, repository: repo)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0))
        let emissions = await collectAll(stream)
        XCTAssertLessThanOrEqual(emissions.map(\.coordinates.count).max() ?? 0, 1)
        XCTAssertEqual(emissions.last?.coordinates,
                       [PhotoCoordinate(latitude: 48.8584, longitude: 2.2945)])
    }

    func testUnlocatedItemsAreSkipped() async throws {
        let root = temporaryTestRoot("CoordinatesSkipped")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 3, list: [day(2024, 4, 3, 3)])
        await transport.setPage([makeItem(id: 1, latitude: 1, longitude: 2),
                                 makeItem(id: 2),
                                 makeItem(id: 3, latitude: 3, longitude: 4)],
                                start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...2))
        let emissions = await collectAll(stream)
        XCTAssertEqual(emissions.last?.coordinates, [
            PhotoCoordinate(latitude: 1, longitude: 2),
            PhotoCoordinate(latitude: 3, longitude: 4),
        ])
    }

    func testSingleItemSelectionYieldsOneCoordinate() async throws {
        let root = temporaryTestRoot("CoordinatesSingle")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sec = TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, 3, 1)])
        await transport.setPage([makeItem(id: 1, latitude: 35.697, longitude: 139.681)],
                                start: start(sec))
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0))
        let emissions = await collectAll(stream)
        XCTAssertEqual(emissions.last?.coordinates,
                       [PhotoCoordinate(latitude: 35.697, longitude: 139.681)])
    }

    func testCancellationStopsFurtherPageRequests() async throws {
        let root = temporaryTestRoot("Cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sections = (1...4).map { index in
            TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, index, 1)])
        }
        await transport.setBlocked(true)
        let snapshot = TimelineSnapshot(sections: sections)
        let repo = try await makeRepository(transport: transport, root: root, snapshot: snapshot)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .library(.personal), snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...3))
        let consumer = Task {
            for await _ in stream {}
        }
        let started = await waitUntil { await transport.recordedItemCalls() > 0 }
        XCTAssertTrue(started)
        let admitted = await transport.recordedItemCalls()
        consumer.cancel()
        _ = await consumer.value
        await transport.releaseBlocked()
        try? await Task.sleep(for: .milliseconds(150))
        let calls = await transport.recordedItemCalls()
        XCTAssertEqual(calls, admitted)
        XCTAssertLessThanOrEqual(calls, 2)
    }
}

actor InfoResolverMockTransport: PhotosTransport {
    private var snapshot = TimelineSnapshot(sections: [])
    func setSnapshot(_ value: TimelineSnapshot) { snapshot = value }
    private var pages: [Int64: [PhotoItem]] = [:]
    private var failures: Set<Int64> = []
    private var itemCalls = 0
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setPage(_ items: [PhotoItem], start: Int64) { pages[start] = items }
    func setFailure(start: Int64) { failures.insert(start) }
    func setBlocked(_ value: Bool) { blocked = value }
    func recordedItemCalls() -> Int { itemCalls }

    func releaseBlocked() {
        blocked = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func login(credentials: SynologyCredentials) async throws {}

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(snapshot, initial: initial)
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        itemCalls += 1
        if blocked {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failures.contains(where: { $0 >= request.oldestDay.startTime && $0 <= request.newestDay.endTime }) { throw TestFailure("Mock page failure") }
        let values = try pages.keys.sorted(by: >).filter { $0 >= request.oldestDay.startTime && $0 <= request.newestDay.endTime }.flatMap { start in
            try pages[start, default: []].map { try fixtureItem($0, on: CaptureDay(time: start)) }
        }
        return CollectionBatchResult(items: Array(values.dropFirst(request.offset).prefix(request.limit)), profile: fields)
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {
        throw TestFailure("Unexpected favorite write")
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        throw TestFailure("Unexpected thumbnail request")
    }

    func fullImage(_ resource: FullImageResource, etag: String?,
                   lastModified: String?) async throws -> FullImageResponse {
        throw TestFailure("Unexpected original-image request")
    }
}
