import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class SelectionInfoResolverTests: XCTestCase {

    private func makeItem(id: Int64, time: Int64 = 1712102400, type: String = "photo",
                          filesize: Int64? = nil) -> PhotoItem {
        let size = filesize.map { ",\"filesize\":\($0)" } ?? ""
        let json = """
        {"id":\(id),"filename":"IMG_\(id).jpg","time":\(time),"type":"\(type)"\(size),"additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key_\(id)","sm":"ready","m":"ready","xl":"ready"},"resolution":{"width":1000,"height":1000}}}
        """
        return try! JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func makeRepository(transport: InfoResolverMockTransport, root: URL) throws -> CachedPhotosRepository {
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
        let namespace = CacheKey.namespace(server: SynologyClient.defaultBaseURL, account: "alice")
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: section))
        try await repository.store.put(key, kind: .page, data: JSONEncoder().encode(items),
                                       validatedRun: nil)
    }

    private func collectAll(_ stream: AsyncStream<SelectionInfo>) async -> [SelectionInfo] {
        var results: [SelectionInfo] = []
        for await info in stream { results.append(info) }
        return results
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
        let repo = try makeRepository(transport: transport, root: root)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
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
        let repo = try makeRepository(transport: transport, root: root)
        try await seedPage([item], section: sec, repository: repo)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
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
        let repo = try makeRepository(transport: transport, root: root)
        try await seedPage([makeItem(id: 1)], section: sec, repository: repo)

        let emissions = await collectAll(SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
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
        let repo = try makeRepository(transport: transport, root: root)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
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
        let repo = try makeRepository(transport: transport, root: root)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
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
        let repo = try makeRepository(transport: transport, root: root)
        try await seedPage([item], section: sec, repository: repo)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
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

    func testCancellationStopsFurtherPageRequests() async throws {
        let root = temporaryTestRoot("Cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InfoResolverMockTransport()
        let sections = (1...4).map { index in
            TimelineSection(offset: 0, limit: 1, list: [day(2024, 4, index, 1)])
        }
        await transport.setBlocked(true)
        let snapshot = TimelineSnapshot(sections: sections)
        let repo = try makeRepository(transport: transport, root: root)

        let stream = SelectionInfoResolver(repository: repo).resolve(
            collection: .personalLibrary, snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...3))
        let consumer = Task {
            for await _ in stream {}
        }
        let started = await waitUntil { await transport.recordedItemCalls() == 2 }
        XCTAssertTrue(started)
        consumer.cancel()
        _ = await consumer.value
        await transport.releaseBlocked()
        try? await Task.sleep(for: .milliseconds(150))
        let calls = await transport.recordedItemCalls()
        XCTAssertEqual(calls, 2)
    }
}

actor InfoResolverMockTransport: PhotosTransport {
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

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        TimelineSnapshot(sections: [])
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        itemCalls += 1
        if blocked {
            await withCheckedContinuation { waiters.append($0) }
        }
        if let bounds = section.dateBounds, failures.contains(bounds.start) {
            throw TestFailure("Mock page failure")
        }
        return section.dateBounds.flatMap { pages[$0.start] } ?? []
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        throw TestFailure("Unexpected favorite write")
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        throw TestFailure("Unexpected thumbnail request")
    }

    func fullImage(_ resource: FullImageResource, etag: String?,
                   lastModified: String?) async throws -> FullImageResponse {
        throw TestFailure("Unexpected original-image request")
    }
}
