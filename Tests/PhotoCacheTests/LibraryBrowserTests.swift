import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor FakeTransport: PhotosTransport {
    var loginBlocked = false
    var itemBlocked = false
    var pageItems: [PhotoItem] = []
    var loginCalls = 0
    var itemCalls = 0
    private var loginWaiters: [CheckedContinuation<Void, Never>] = []
    private var itemWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func configure(loginBlocked: Bool = false, itemBlocked: Bool = false, items: [PhotoItem] = []) {
        self.loginBlocked = loginBlocked
        self.itemBlocked = itemBlocked
        pageItems = items
    }
    func login(credentials: SynologyCredentials) async throws {
        loginCalls += 1
        if loginBlocked { await withCheckedContinuation { loginWaiters.append($0) } }
        try Task.checkCancellation()
    }
    func timeline(initial: Bool) async throws -> TimelineSnapshot { TimelineSnapshot(sections: []) }
    func items(in section: TimelineSection) async throws -> [PhotoItem] {
        itemCalls += 1
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
        if itemBlocked { await withCheckedContinuation { itemWaiters.append($0) } }
        try Task.checkCancellation()
        return pageItems
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        ThumbnailResponse(data: Data([1]), etag: nil, lastModified: nil)
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

final class LibraryBrowserTests: XCTestCase {
    private let server = URL(string: "https://example.invalid")!
    private let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")

    private func section(_ day: Int, offset: Int = 0, limit: Int = 2, count: Int = 2) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
                        list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: count)])
    }
    private func item(_ id: Int) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":1711929600,\"type\":\"photo\"}".utf8))
    }
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SynoBrowserTest-\(UUID().uuidString)")
    }
    private func repository(root: URL, transport: FakeTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server, cacheRoot: root, transport: transport)
    }
    private func seed(_ items: [PhotoItem], section: TimelineSection, repository: CachedPhotosRepository) async throws {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: section))
        try await repository.store.put(key, kind: .page, data: JSONEncoder().encode(items), validatedRun: nil)
    }
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

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
}
