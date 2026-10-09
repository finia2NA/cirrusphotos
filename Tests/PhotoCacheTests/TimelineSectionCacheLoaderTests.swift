import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class TimelineSectionCacheLoaderTests: XCTestCase {
    private let server = URL(string: "https://bulk-pages.example.invalid")!
    private let credentials = SynologyCredentials(username: "bulk-pages", password: "unused", otpSecret: "unused")

    private func repository(root: URL, transport: BulkPageTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    private func sections(_ count: Int) -> [TimelineSection] {
        (0..<count).map { index in
            TimelineSection(offset: index, limit: 1,
                            list: [.init(year: 2025, month: 1, day: 20 - index, itemCount: 1)])
        }
    }

    private func item(_ id: Int64) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":\(id),\"filename\":\"\(id).JPG\",\"time\":1737331200,\"type\":\"photo\"}".utf8
        ))
    }

    private func waitForFinish(_ loader: TimelineSectionCacheLoader) async -> TimelineSectionCacheLoadProgress? {
        let finished = await waitUntil {
            let value = await loader.progress()
            return value.state == .finished
        }
        return finished ? await loader.progress() : nil
    }

    func testFavoritesUsesFavoritesForEveryPageAndCompletesVerified() async throws {
        let root = temporaryTestRoot("BulkFavorites"); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: sections(3))
        let transport = BulkPageTransport(item: try item(1))
        let loader = TimelineSectionCacheLoader(repository: try repository(root: root, transport: transport),
                                                collection: .favorites, snapshot: snapshot,
                                                collectionLabel: "Favorites")
        await loader.loadAll()
        let finalProgress = await waitForFinish(loader)
        let progress = try XCTUnwrap(finalProgress)
        XCTAssertEqual(progress.verified, 3)
        let collections = await transport.collections()
        XCTAssertEqual(collections, [.favorites, .favorites, .favorites])
    }

    func testAlbumUsesExactDescriptorForSplitDaySections() async throws {
        let root = temporaryTestRoot("BulkAlbum"); defer { try? FileManager.default.removeItem(at: root) }
        let entries = (0..<1_001).map { DayTimelineEntry(id: Int64($0), time: 1_735_689_600) }
        let snapshot = DayGroupedTimelineBuilder.build(entries: entries).snapshot
        XCTAssertEqual(snapshot.sections.count, 2)
        let transport = BulkPageTransport(item: try item(1))
        let loader = TimelineSectionCacheLoader(repository: try repository(root: root, transport: transport),
                                                collection: .album(54), snapshot: snapshot,
                                                collectionLabel: "Trip")
        await loader.loadAll()
        let progress = await waitForFinish(loader)
        let collections = await transport.collections()
        let offsets = await transport.offsets()
        XCTAssertNotNil(progress)
        XCTAssertEqual(collections, [.album(54), .album(54)])
        XCTAssertEqual(Set(offsets), Set(snapshot.sections.map(\.offset)))
    }

    func testAdmitsAtMostTwoReadsAndCancellationStopsLaterSections() async throws {
        let root = temporaryTestRoot("BulkConcurrency"); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: sections(6))
        let transport = BulkPageTransport(item: try item(1), delay: .seconds(1))
        let loader = TimelineSectionCacheLoader(repository: try repository(root: root, transport: transport),
                                                collection: .favorites, snapshot: snapshot,
                                                collectionLabel: "Favorites")
        await loader.loadAll()
        let admitted = await waitUntil { await transport.callCount() == 2 }
        let maximum = await transport.maximumConcurrent()
        XCTAssertTrue(admitted)
        XCTAssertLessThanOrEqual(maximum, 2)
        await loader.cancel()
        try await Task.sleep(for: .milliseconds(50))
        let calls = await transport.callCount()
        let state = await loader.progress().state
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(state, .cancelled)
    }

    func testDefaultBypassesStalePageAndUseCachedPagesReusesCurrentRunValue() async throws {
        let root = temporaryTestRoot("BulkPolicy"); defer { try? FileManager.default.removeItem(at: root) }
        let section = sections(1)[0]
        let snapshot = TimelineSnapshot(sections: [section])
        let transport = BulkPageTransport(item: try item(2))
        let repository = try repository(root: root, transport: transport)
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: section,
                                              collection: .favorites))
        try await repository.store.put(key, kind: .page,
                                       data: JSONEncoder().encode([try item(1)]),
                                       validatedRun: "old-run")

        let first = TimelineSectionCacheLoader(repository: repository, collection: .favorites,
                                               snapshot: snapshot, collectionLabel: "Favorites")
        await first.loadAll()
        let firstProgress = await waitForFinish(first)
        XCTAssertNotNil(firstProgress)
        let store = await repository.store
        let storedEntry = try await store.get(key)
        let stored = try XCTUnwrap(storedEntry)
        XCTAssertEqual(try JSONDecoder().decode([PhotoItem].self, from: stored.data).map(\.id), [2])
        let firstCalls = await transport.callCount()
        XCTAssertEqual(firstCalls, 1)

        let second = TimelineSectionCacheLoader(repository: repository, collection: .favorites,
                                                snapshot: snapshot, collectionLabel: "Favorites")
        await second.loadAll(useCachedPages: true)
        let secondProgress = await waitForFinish(second)
        let secondCalls = await transport.callCount()
        XCTAssertNotNil(secondProgress)
        XCTAssertEqual(secondCalls, 1, "a current-run verified page must not be requested again")
    }

    func testRetryReadsOnlyFailuresWithOriginalCachePolicy() async throws {
        let root = temporaryTestRoot("BulkRetry"); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: sections(3))
        let transport = BulkPageTransport(item: try item(1))
        let repository = try repository(root: root, transport: transport)
        for await _ in await repository.page(snapshot.sections[1], collection: .album(9)) {}
        await transport.failNext(offset: 1)
        let loader = TimelineSectionCacheLoader(repository: repository,
                                                collection: .album(9), snapshot: snapshot,
                                                collectionLabel: "Album 9")
        await loader.loadAll(useCachedPages: false)
        let failed = await waitUntil { await loader.progress().failed == 1 }
        let firstCounts = [await transport.count(offset: 0), await transport.count(offset: 1),
                           await transport.count(offset: 2)]
        XCTAssertTrue(failed)
        XCTAssertEqual(firstCounts, [1, 2, 1])
        await loader.retryFailed()
        let progress = await waitForFinish(loader)
        let retryCounts = [await transport.count(offset: 0), await transport.count(offset: 1),
                           await transport.count(offset: 2)]
        XCTAssertNotNil(progress)
        XCTAssertEqual(retryCounts, [1, 3, 1],
                       "retry must preserve cache bypass instead of accepting the primed current-run page")
    }

    func testIdenticalSectionsRetainCollectionScopedCacheEntries() async throws {
        let root = temporaryTestRoot("BulkIsolation"); defer { try? FileManager.default.removeItem(at: root) }
        let section = sections(1)[0]
        let snapshot = TimelineSnapshot(sections: [section])
        let transport = BulkPageTransport(item: try item(7))
        let repository = try repository(root: root, transport: transport)
        let collections: [PhotoCollectionDescriptor] = [.personalLibrary, .favorites, .album(54), .album(55)]
        for collection in collections {
            let loader = TimelineSectionCacheLoader(repository: repository, collection: collection,
                                                    snapshot: snapshot, collectionLabel: collection.rawValue)
            await loader.loadAll()
            let progress = await waitForFinish(loader)
            XCTAssertNotNil(progress)
        }
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        for collection in collections {
            let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: section,
                                                  collection: collection))
            let store = await repository.store
            let entry = try await store.get(key)
            XCTAssertNotNil(entry)
        }
    }
}

private actor BulkPageTransport: PhotosTransport {
    let item: PhotoItem
    let delay: Duration
    private var failOnceOffsets: Set<Int>
    private var requests: [(Int, PhotoCollectionDescriptor)] = []
    private var active = 0
    private var maximumActive = 0

    init(item: PhotoItem, delay: Duration = .zero, failOnceOffsets: Set<Int> = []) {
        self.item = item
        self.delay = delay
        self.failOnceOffsets = failOnceOffsets
    }

    func items(in section: TimelineSection,
               collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        requests.append((section.offset, collection))
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        if failOnceOffsets.remove(section.offset) != nil { throw TestFailure("planned failure") }
        return [item]
    }

    func collections() -> [PhotoCollectionDescriptor] { requests.map(\.1) }
    func offsets() -> [Int] { requests.map(\.0) }
    func callCount() -> Int { requests.count }
    func count(offset: Int) -> Int { requests.count { $0.0 == offset } }
    func maximumConcurrent() -> Int { maximumActive }
    func failNext(offset: Int) { failOnceOffsets.insert(offset) }
}
