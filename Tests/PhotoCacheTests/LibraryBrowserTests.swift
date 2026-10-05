import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

fileprivate actor FakeTransport: PhotosTransport {
    var loginBlocked = false
    var itemBlocked = false
    var loginFailure: String?
    var timelineFailure: String?
    var itemFailure: String?
    var timelineSnapshot = TimelineSnapshot(sections: [])
    var pageItems: [PhotoItem] = []
    var loginCalls = 0
    var itemCalls = 0
    var collectionTimelineCalls: [(PhotoCollectionDescriptor, Bool)] = []
    var collectionItemCalls: [PhotoCollectionDescriptor] = []
    var favoriteRequests: [(Int64, Bool)] = []
    var favoriteWrites: [(Int64, Bool)] = []
    var favoriteBlocked = false
    var favoriteReleased = false
    var favoriteFailure = false
    private var loginWaiters: [CheckedContinuation<Void, Never>] = []
    private var itemWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func configure(loginBlocked: Bool = false, itemBlocked: Bool = false, items: [PhotoItem] = [],
                   loginFailure: String? = nil, timelineFailure: String? = nil, itemFailure: String? = nil,
                   timelineSnapshot: TimelineSnapshot = TimelineSnapshot(sections: [])) {
        self.loginBlocked = loginBlocked
        self.itemBlocked = itemBlocked
        pageItems = items
        self.loginFailure = loginFailure
        self.timelineFailure = timelineFailure
        self.itemFailure = itemFailure
        self.timelineSnapshot = timelineSnapshot
    }
    func login(credentials: SynologyCredentials) async throws {
        loginCalls += 1
        if loginBlocked { await withCheckedContinuation { loginWaiters.append($0) } }
        try Task.checkCancellation()
        if let loginFailure { throw TestFailure(loginFailure) }
    }
    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        collectionTimelineCalls.append((collection, initial))
        if let timelineFailure { throw TestFailure(timelineFailure) }
        return timelineSnapshot
    }
    private func loadItems(in section: TimelineSection) async throws -> [PhotoItem] {
        itemCalls += 1
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
        if itemBlocked { await withCheckedContinuation { itemWaiters.append($0) } }
        try Task.checkCancellation()
        if let itemFailure { throw TestFailure(itemFailure) }
        return pageItems
    }
    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        collectionItemCalls.append(collection)
        return try await loadItems(in: section)
    }
    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        favoriteRequests.append(contentsOf: itemIDs.map { ($0, favorite) })
        while favoriteBlocked, !favoriteReleased {
            try await Task.sleep(for: .milliseconds(2))
        }
        if favoriteFailure { throw TestFailure("Favorite write failed") }
        favoriteWrites.append(contentsOf: itemIDs.map { ($0, favorite) })
    }
    func blockFavoriteWrite() { favoriteBlocked = true; favoriteReleased = false }
    func releaseFavoriteWrite(failing: Bool = false) {
        favoriteFailure = failing
        favoriteReleased = true
    }
    func waitForItemStart() async {
        if itemCalls > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseItems() {
        itemBlocked = false
        for waiter in itemWaiters { waiter.resume() }
        itemWaiters.removeAll()
    }
    func releaseLogin() {
        loginBlocked = false
        for waiter in loginWaiters { waiter.resume() }
        loginWaiters.removeAll()
    }
}

class LibraryBrowserTestCase: XCTestCase {
    fileprivate let server = URL(string: "https://example.invalid")!
    fileprivate let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")

    fileprivate func section(_ day: Int, offset: Int = 0, limit: Int = 2, count: Int = 2) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
                        list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: count)])
    }
    fileprivate func item(_ id: Int) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":1711929600,\"type\":\"photo\"}".utf8))
    }
    fileprivate func root() -> URL { temporaryTestRoot("SynoBrowserTest") }
    fileprivate func repository(root: URL, transport: FakeTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server, cacheRoot: root, transport: transport)
    }
    fileprivate func seed(_ items: [PhotoItem], section: TimelineSection, repository: CachedPhotosRepository) async throws {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: section))
        try await repository.store.put(key, kind: .page, data: JSONEncoder().encode(items), validatedRun: nil)
    }
    fileprivate func seedTimeline(_ snapshot: TimelineSnapshot, repository: CachedPhotosRepository) async throws {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        try await repository.store.put(CacheKey.timeline(namespace: namespace), kind: .timeline,
                                       data: JSONEncoder().encode(snapshot), validatedRun: nil)
    }
}

final class LibraryIndexAndCacheIdentityTests: LibraryBrowserTestCase {
    func testIndexMapsSplitAndMixedDaysWithOffset() {
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 4, list: [
                TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3),
                TimelineDay(year: 2024, month: 4, day: 2, itemCount: 3)]),
            TimelineSection(offset: 4, limit: 2, list: [
                TimelineDay(year: 2024, month: 4, day: 3, itemCount: 3),
                TimelineDay(year: 2024, month: 4, day: 2, itemCount: 3)]),
            section(1, offset: 0, limit: 2, count: 2)
        ])
        let index = LibraryIndex(snapshot: snapshot)
        XCTAssertEqual(index.dayIDs, ["2024-04-03", "2024-04-02", "2024-04-01"])
        XCTAssertEqual(index.slices(inSection: 0).map(\.pageRange), [0..<3, 3..<4])
        XCTAssertEqual(index.slices(forDay: "2024-04-02").map(\.dayRange), [0..<1, 1..<3])
        XCTAssertEqual(index.sectionIndices(forDay: "2024-04-02"), [0, 1])
        XCTAssertEqual(index.fingerprint, LibraryIndex(snapshot: snapshot).fingerprint)
        XCTAssertNotEqual(index.fingerprint, LibraryIndex(snapshot: TimelineSnapshot(sections: [section(1)])).fingerprint)
    }

    func testCollectionMetadataCacheKeysAreIsolated() {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let descriptor = section(3)
        XCTAssertEqual(PhotoCollectionDescriptor.personalLibrary.rawValue, "personal",
                       "Collection refactoring must preserve the existing Personal Library cache keys")
        XCTAssertNotEqual(CacheKey.timeline(namespace: namespace, collection: .personalLibrary),
                          CacheKey.timeline(namespace: namespace, collection: .favorites))
        XCTAssertNotEqual(CacheKey.page(namespace: namespace, section: descriptor, collection: .personalLibrary),
                          CacheKey.page(namespace: namespace, section: descriptor, collection: .favorites))
    }
}

final class FavoriteRepositoryTests: LibraryBrowserTestCase {
    func testTransientViewerPageAppliesFavoriteChangesMadeDuringFetch() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let descriptor = section(1, limit: 1, count: 1)
        let photo = try item(7)
        await transport.configure(itemBlocked: true, items: [photo])
        let repository = try repository(root: root, transport: transport)
        let read = Task {
            try await repository.transientPage(descriptor, collection: .favorites,
                                               priority: .visible)
        }
        await transport.waitForItemStart()

        try await repository.setFavorite(itemID: photo.id, item: photo, in: descriptor,
                                         collection: .favorites, to: true)
        await transport.releaseItems()

        let items = try await read.value
        XCTAssertEqual(items.first?.isFavorite, true,
                       "A reconstructed viewer page must use overrides after its network wait")
    }

    func testFavoritesRoutesTimelineAndPageThroughFilteredCollection() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let descriptor = section(3, limit: 1, count: 1)
        await transport.configure(items: [try item(1)],
                                  timelineSnapshot: TimelineSnapshot(sections: [descriptor]))
        let repository = try repository(root: root, transport: transport)

        for await _ in await repository.timeline(collection: .favorites) {}
        for await _ in await repository.page(descriptor, collection: .favorites) {}

        let timelineCalls = await transport.collectionTimelineCalls
        XCTAssertEqual(timelineCalls.count, 1)
        XCTAssertEqual(timelineCalls.first?.0, .favorites)
        XCTAssertEqual(timelineCalls.first?.1, false,
                       "Favorites must use full Timeline.get, never get_init_timeline")
        let itemCalls = await transport.collectionItemCalls
        XCTAssertEqual(itemCalls, [.favorites])
    }

    func testFavoriteMutationRefreshesAuthoritativeTimelineAfterWrite() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let descriptor = section(1, limit: 1, count: 1)
        let photo = try item(7).withFavorite(true)
        await transport.configure(items: [photo],
                                  timelineSnapshot: TimelineSnapshot(sections: [descriptor]))
        let repository = try repository(root: root, transport: transport)
        for await _ in await repository.timeline(collection: .favorites) {}
        for await _ in await repository.page(descriptor, collection: .favorites) {}
        var refreshes = await repository.timelineRefreshes(collection: .favorites).makeAsyncIterator()
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: []))

        try await repository.setFavorite(itemID: photo.id, item: photo, in: descriptor,
                                         collection: .favorites, to: false)
        guard case .value(let updated, let verified) = await refreshes.next() else {
            return XCTFail("Missing authoritative Favorites refresh")
        }
        XCTAssertTrue(updated.sections.isEmpty)
        XCTAssertTrue(verified)
        let favoriteTimelineCallCount = await transport.collectionTimelineCalls.filter { $0.0 == .favorites }.count
        XCTAssertEqual(favoriteTimelineCallCount, 2)
        let finalItemCallCount = await transport.collectionItemCalls.count
        XCTAssertEqual(finalItemCallCount, 1)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let store = await repository.store
        let cachedTimeline = try await store.get(
            CacheKey.timeline(namespace: namespace, collection: .favorites))
        let timelineEntry = try XCTUnwrap(cachedTimeline)
        XCTAssertTrue(try JSONDecoder().decode(TimelineSnapshot.self, from: timelineEntry.data).sections.isEmpty)
        let oldPageKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor,
                                                     collection: .favorites))
        let oldPage = try await repository.store.get(oldPageKey)
        XCTAssertNotNil(oldPage, "The last cached page stays visible until new geometry demands replacement")
    }

    func testFavoriteAdditionWaitsForWriteThenUsesServerOrdering() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let sourceSection = section(1, limit: 1, count: 1)
        let existingFavoritesSection = section(1, limit: 2, count: 2)
        let photo = try item(8)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [existingFavoritesSection]))
        let repository = try repository(root: root, transport: transport)
        for await _ in await repository.timeline(collection: .favorites) {}
        await transport.blockFavoriteWrite()
        var refreshes = await repository.timelineRefreshes(collection: .favorites).makeAsyncIterator()

        let mutation = Task {
            try await repository.setFavorite(itemID: photo.id, item: photo, in: sourceSection,
                                             collection: .personalLibrary, to: true)
        }
        let requestStarted = await waitUntil { await transport.favoriteRequests.count == 1 }
        XCTAssertTrue(requestStarted)
        let timelineCalls = await transport.collectionTimelineCalls.filter { $0.0 == .favorites }.count
        XCTAssertEqual(timelineCalls, 1)

        let authoritative = section(1, limit: 3, count: 3)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [authoritative]))
        await transport.releaseFavoriteWrite()
        try await mutation.value
        guard case .value(let refreshed, let verified) = await refreshes.next() else {
            return XCTFail("Missing authoritative Favorites addition")
        }
        XCTAssertTrue(verified)
        XCTAssertEqual(refreshed.sections, [authoritative])
        let finalTimelineCalls = await transport.collectionTimelineCalls.filter { $0.0 == .favorites }.count
        XCTAssertEqual(finalTimelineCalls, 2)
    }

    func testConsecutiveFavoriteWritesCoalesceAuthoritativeRefresh() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let descriptor = section(1, limit: 2, count: 2)
        let repository = try repository(root: root, transport: transport)
        var refreshes = await repository.timelineRefreshes(collection: .favorites).makeAsyncIterator()

        async let first: Void = repository.setFavorite(itemID: 81, in: descriptor, to: true)
        async let second: Void = repository.setFavorite(itemID: 82, in: descriptor, to: true)
        _ = try await (first, second)
        guard case .value = await refreshes.next() else {
            return XCTFail("Missing coalesced authoritative refresh")
        }

        let favoriteWriteCount = await transport.favoriteWrites.count
        XCTAssertEqual(favoriteWriteCount, 2)
        let timelineCalls = await transport.collectionTimelineCalls.filter { $0.0 == .favorites }.count
        XCTAssertEqual(timelineCalls, 1)
    }

    func testFailedFavoriteMutationRollsBackStatusWithoutChangingMembership() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let descriptor = section(1, limit: 1, count: 1)
        let photo = try item(9).withFavorite(true)
        await transport.configure(items: [photo],
                                  timelineSnapshot: TimelineSnapshot(sections: [descriptor]))
        await transport.blockFavoriteWrite()
        let repository = try repository(root: root, transport: transport)
        for await _ in await repository.timeline(collection: .favorites) {}
        for await _ in await repository.page(descriptor, collection: .favorites) {}
        var favoriteChanges = await repository.favoriteChanges().makeAsyncIterator()

        let mutation = Task {
            try await repository.setFavorite(itemID: photo.id, item: photo, in: descriptor,
                                             collection: .favorites, to: false)
        }
        let requestStarted = await waitUntil { await transport.favoriteRequests.count == 1 }
        XCTAssertTrue(requestStarted)
        let optimisticChange = await favoriteChanges.next()
        XCTAssertEqual(optimisticChange?.values[photo.id], false)

        await transport.releaseFavoriteWrite(failing: true)
        do {
            try await mutation.value
            XCTFail("Expected the favorite write to fail")
        } catch {}
        let rollbackChange = await favoriteChanges.next()
        XCTAssertEqual(rollbackChange?.values[photo.id], true)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let pageKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor,
                                                  collection: .favorites))
        let store = await repository.store
        let cachedPage = try await store.get(pageKey)
        let pageEntry = try XCTUnwrap(cachedPage)
        let restoredItems = try JSONDecoder().decode([PhotoItem].self, from: pageEntry.data)
        XCTAssertEqual(restoredItems.map(\.id), [photo.id])
        XCTAssertTrue(restoredItems[0].isFavorite)
        let timelineCalls = await transport.collectionTimelineCalls.filter { $0.0 == .favorites }.count
        XCTAssertEqual(timelineCalls, 1)
    }

    func testFavoriteMutationRejectsAnOlderInFlightFavoritesPage() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport()
        let descriptor = section(3, limit: 1, count: 1)
        let photo = try item(8).withFavorite(true)
        await transport.configure(itemBlocked: true, items: [photo],
                                  timelineSnapshot: TimelineSnapshot(sections: [descriptor]))
        let repository = try repository(root: root, transport: transport)
        let staleRequest = Task { () -> [[Int64]] in
            var values: [[Int64]] = []
            for await event in await repository.page(descriptor, collection: .favorites) {
                if case .value(let items, _) = event { values.append(items.map(\.id)) }
            }
            return values
        }
        await transport.waitForItemStart()

        try await repository.setFavorite(itemID: photo.id, in: descriptor, to: false)
        await transport.configure(itemBlocked: true, items: [],
                                  timelineSnapshot: TimelineSnapshot(sections: []))
        await transport.releaseItems()

        let staleValues = await staleRequest.value
        XCTAssertEqual(staleValues, [],
                       "A response from the prior Favorites generation must not be published")
        for await event in await repository.page(descriptor, collection: .favorites) {
            if case .value(let items, true) = event { XCTAssertTrue(items.isEmpty) }
        }
        let itemCalls = await transport.collectionItemCalls.count
        XCTAssertEqual(itemCalls, 2)
    }
}

final class RepositoryPageAndAuthenticationTests: LibraryBrowserTestCase {
    func testCachedPageArrivesWhileLoginIsBlockedAndOfflineReadFinishes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        await fake.configure(loginBlocked: true)
        let repository = try repository(root: root, transport: fake)
        let descriptor = section(2)
        try await seed([try item(1)], section: descriptor, repository: repository)

        var offline = await repository.page(descriptor, allowNetwork: false).makeAsyncIterator()
        if case .value(let items, let verified) = await offline.next() {
            XCTAssertEqual(items.map(\.id), [1]); XCTAssertFalse(verified)
        } else { XCTFail("Missing offline cache") }
        let offlineEnd = await offline.next()
        XCTAssertNil(offlineEnd)
        let loginCalls = await fake.loginCalls
        XCTAssertEqual(loginCalls, 0)

        let stream = await repository.page(descriptor)
        var iterator = stream.makeAsyncIterator()
        if case .value(let items, let verified) = await iterator.next() {
            XCTAssertEqual(items.map(\.id), [1]); XCTAssertFalse(verified)
        } else { XCTFail("Cache waited for login") }
        let itemCalls = await fake.itemCalls
        XCTAssertEqual(itemCalls, 0)
        let loginStarted = await waitUntil { await fake.loginCalls == 1 }
        XCTAssertTrue(loginStarted)
        // Finish the blocked operation so the stream and shared login do not outlive the test.
        await fake.releaseLogin()
        _ = await iterator.next()
    }

    func testEqualCountNetworkPageReplacesCachedItems() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        await fake.configure(items: [try item(7), try item(8)])
        let repository = try repository(root: root, transport: fake)
        let descriptor = section(2)
        try await seed([try item(1), try item(2)], section: descriptor, repository: repository)
        var iterator = await repository.page(descriptor).makeAsyncIterator()
        if case .value(let cached, false) = await iterator.next() { XCTAssertEqual(cached.map(\.id), [1, 2]) }
        else { XCTFail("Missing old page") }
        if case .value(let current, true) = await iterator.next() { XCTAssertEqual(current.map(\.id), [7, 8]) }
        else { XCTFail("Equal-count replacement was skipped") }
        let end = await iterator.next()
        XCTAssertNil(end)
        let calls = await fake.itemCalls
        XCTAssertEqual(calls, 1)
    }

    func testOneCancelledSubscriberDoesNotCancelSharedPage() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        await fake.configure(itemBlocked: true, items: [try item(9)])
        let repository = try repository(root: root, transport: fake)
        let descriptor = section(2)
        let first = await repository.page(descriptor)
        let second = await repository.page(descriptor)
        let firstTask = Task { for await _ in first {} }
        let secondTask = Task { () -> [Int64] in
            for await event in second {
                if case .value(let items, true) = event { return items.map(\.id) }
            }
            return []
        }
        let itemStarted = await waitUntil { await fake.itemCalls == 1 }
        XCTAssertTrue(itemStarted)
        firstTask.cancel()
        await fake.releaseItems()
        let result = await secondTask.value
        XCTAssertEqual(result, [9])
        let calls = await fake.itemCalls
        XCTAssertEqual(calls, 1)
    }

    func testAuthenticationSurvivesSequentialDemandsAndOneCancelledJob() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        await fake.configure(loginBlocked: true, items: [try item(5)])
        let repository = try repository(root: root, transport: fake)
        let first = await repository.page(section(1))
        let second = await repository.page(section(2))
        let firstTask = Task { for await _ in first {} }
        let secondTask = Task { () -> [Int64] in
            for await event in second {
                if case .value(let items, true) = event { return items.map(\.id) }
            }
            return []
        }
        let loginStarted = await waitUntil { await fake.loginCalls == 1 }
        XCTAssertTrue(loginStarted)
        firstTask.cancel()
        await fake.releaseLogin()
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, [5])
        var third = await repository.page(section(3)).makeAsyncIterator()
        if case .value(let items, true) = await third.next() { XCTAssertEqual(items.map(\.id), [5]) }
        else { XCTFail("Later demand did not load") }
        let loginCalls = await fake.loginCalls
        XCTAssertEqual(loginCalls, 1)
    }

    func testClearDuringTransferKeepsLiveResultButNotLateCacheWrite() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        await fake.configure(itemBlocked: true, items: [try item(42)])
        let repository = try repository(root: root, transport: fake)
        let descriptor = section(2)
        let result = Task { () -> [Int64] in
            for await event in await repository.page(descriptor) {
                if case .value(let items, true) = event { return items.map(\.id) }
            }
            return []
        }
        let started = await waitUntil { await fake.itemCalls == 1 }
        XCTAssertTrue(started)
        try await repository.clearCache()
        await fake.releaseItems()
        let live = await result.value
        XCTAssertEqual(live, [42])
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptor))
        let cached = try await repository.store.get(key)
        XCTAssertNil(cached)
    }

    func testWindowRetainsOnlyConfiguredPages() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        let repository = try repository(root: root, transport: fake)
        let sections = [section(3), section(2), section(1)]
        for (offset, descriptor) in sections.enumerated() {
            try await seed([try item(offset + 1)], section: descriptor, repository: repository)
        }
        let window = LibraryPageWindow(repository: repository, maximumPages: 2)
        let snapshot = TimelineSnapshot(sections: sections)
        let index = LibraryIndex(snapshot: snapshot)
        await window.update(index: index, allowNetwork: false, visible: [0], prefetch: [1, 2])
        // The first two pages must load before the demand shifts.
        let firstLoaded = await waitUntil { await window.retainedPages().count == 2 }
        XCTAssertTrue(firstLoaded)
        let firstPages = await window.retainedPages().map(\.sectionIndex)
        XCTAssertEqual(firstPages, [0, 1])
        await window.update(index: index, allowNetwork: false, visible: [2], prefetch: [1])
        let secondLoaded = await waitUntil { await window.retainedPages().map(\.sectionIndex) == [1, 2] }
        XCTAssertTrue(secondLoaded)
        let finalPages = await window.retainedPages().map(\.sectionIndex)
        XCTAssertEqual(finalPages, [1, 2])
        await window.update(index: index, allowNetwork: false, visible: [0, 1], prefetch: [2])
        let filled = await waitUntil { await window.retainedPages().map(\.sectionIndex) == [0, 1] }
        XCTAssertTrue(filled)
        let retainedCount = await window.retainedPages().count
        XCTAssertEqual(retainedCount, 2)
        let calls = await fake.itemCalls
        XCTAssertEqual(calls, 0)
        await window.cancelAll()
    }

    func testWindowRetryReopensFailedPageWithoutDroppingCachedPage() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        await fake.configure(itemFailure: "Page unavailable")
        let repository = try repository(root: root, transport: fake)
        let descriptor = section(2)
        try await seed([try item(8)], section: descriptor, repository: repository)
        let window = LibraryPageWindow(repository: repository)
        let index = LibraryIndex(snapshot: TimelineSnapshot(sections: [descriptor]))
        var events = await window.events().makeAsyncIterator()
        await window.update(index: index, allowNetwork: true, visible: [0], prefetch: [])
        var sawFailure = false
        while let event = await events.next() {
            if case .failure(0, _) = event { sawFailure = true; break }
        }
        XCTAssertTrue(sawFailure)
        let before = await window.retainedPages()
        XCTAssertEqual(before.first?.items.map(\.id), [8])
        XCTAssertEqual(before.first?.verified, false)

        await fake.configure(items: [try item(9)])
        await window.update(index: index, allowNetwork: true, visible: [0], prefetch: [], retryRevision: 1)
        let replaced = await waitUntil {
            let pages = await window.retainedPages()
            return pages.first?.verified == true && pages.first?.items.map(\.id) == [9]
        }
        XCTAssertTrue(replaced)
        let calls = await fake.itemCalls
        XCTAssertEqual(calls, 2)
        await window.cancelAll()
    }

    func testCancelledGateWaiterReleasesQueueSlot() async throws {
        let gate = NetworkGate(metadata: 1, thumbnails: 1, metadataQueue: 1, thumbnailQueue: 1)
        try await gate.acquire(.metadata, priority: .visible, id: UUID())
        let pending = Task { try await gate.acquire(.metadata, priority: .prefetch, id: UUID()) }
        let queued = await waitUntil { await gate.queuedCount(.metadata) == 1 }
        XCTAssertTrue(queued)
        pending.cancel()
        do { try await pending.value; XCTFail("Cancelled waiter entered") }
        catch is CancellationError { }
        let emptied = await waitUntil { await gate.queuedCount(.metadata) == 0 }
        XCTAssertTrue(emptied)
        let replacement = Task { try await gate.acquire(.metadata, priority: .visible, id: UUID()) }
        await gate.release(.metadata)
        try await replacement.value
        await gate.release(.metadata)
    }

    func testAuthenticationStatusReplaysAndCachedTimelineSurvivesFailedLoginUntilRetry() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        let snapshot = TimelineSnapshot(sections: [section(2)])
        await fake.configure(loginBlocked: true, loginFailure: "Invalid sign in", timelineSnapshot: snapshot)
        let repository = try repository(root: root, transport: fake)
        try await seedTimeline(snapshot, repository: repository)
        try await seed([try item(12)], section: snapshot.sections[0], repository: repository)

        var firstStatus = await repository.authentication().makeAsyncIterator()
        let initialStatus = await firstStatus.next()
        XCTAssertEqual(initialStatus, .notStarted)
        var timeline = await repository.timeline().makeAsyncIterator()
        if case .value(let cached, false) = await timeline.next() {
            XCTAssertEqual(cached.sections, snapshot.sections)
        } else { XCTFail("Cached full index did not arrive before login") }
        let loginStarted = await waitUntil { await fake.loginCalls == 1 }
        XCTAssertTrue(loginStarted)
        let loggingIn = await firstStatus.next()
        XCTAssertEqual(loggingIn, .loggingIn)
        var page = await repository.page(snapshot.sections[0], allowNetwork: false).makeAsyncIterator()
        if case .value(let items, false) = await page.next() { XCTAssertEqual(items.map(\.id), [12]) }
        else { XCTFail("Cached page unavailable during login") }

        await fake.releaseLogin()
        if case .failure = await timeline.next() {} else { XCTFail("Expected login failure") }
        let failed = await firstStatus.next()
        if case .failed(let message) = failed { XCTAssertEqual(message, "Invalid sign in") }
        else { XCTFail("Expected failed status") }
        var replay = await repository.authentication().makeAsyncIterator()
        let replayed = await replay.next()
        XCTAssertEqual(replayed, failed)

        for _ in 0..<3 {
            for await _ in await repository.page(snapshot.sections[0]) {}
        }
        let failedAttemptCalls = await fake.loginCalls
        XCTAssertEqual(failedAttemptCalls, 1)

        await fake.configure(loginBlocked: true, timelineSnapshot: snapshot)
        await repository.retryAuthentication()
        let resetStatus = await firstStatus.next()
        XCTAssertEqual(resetStatus, .notStarted)
        let retry = Task { () -> TimelineSnapshot? in
            for await event in await repository.timeline() {
                if case .value(let current, true) = event { return current }
            }
            return nil
        }
        let retryStarted = await waitUntil { await fake.loginCalls == 2 }
        XCTAssertTrue(retryStarted)
        let secondLoggingIn = await firstStatus.next()
        XCTAssertEqual(secondLoggingIn, .loggingIn)
        await fake.releaseLogin()
        let current = await retry.value
        XCTAssertEqual(current?.sections, snapshot.sections)
        let connected = await firstStatus.next()
        XCTAssertEqual(connected, .signedIn)
        let retryCalls = await fake.loginCalls
        XCTAssertEqual(retryCalls, 2)
        var signedInStream = await repository.authentication().makeAsyncIterator()
        let signedIn = await signedInStream.next()
        XCTAssertEqual(signedIn, .signedIn)
    }

    func testMetadataFailureDoesNotBecomeLoginFailureOrDiscardSession() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeTransport()
        let snapshot = TimelineSnapshot(sections: [section(2)])
        await fake.configure(timelineFailure: "Timeline unavailable", timelineSnapshot: snapshot)
        let repository = try repository(root: root, transport: fake)
        try await seedTimeline(snapshot, repository: repository)
        var timeline = await repository.timeline().makeAsyncIterator()
        if case .value(_, false) = await timeline.next() {} else { XCTFail("Missing cached timeline") }
        if case .failure(let message) = await timeline.next() {
            XCTAssertTrue(message.contains("Timeline unavailable"))
        } else { XCTFail("Expected metadata failure") }
        var status = await repository.authentication().makeAsyncIterator()
        let authenticated = await status.next()
        XCTAssertEqual(authenticated, .signedIn)
        await fake.configure(items: [try item(21)])
        for await event in await repository.page(snapshot.sections[0]) {
            if case .value(let items, true) = event { XCTAssertEqual(items.map(\.id), [21]) }
        }
        let loginCalls = await fake.loginCalls
        XCTAssertEqual(loginCalls, 1)
    }
}
