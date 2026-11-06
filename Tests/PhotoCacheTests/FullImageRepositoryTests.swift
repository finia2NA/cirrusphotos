import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor FullImageTransport: TestPhotosTransport {
    var shouldFail = false
    var shouldBlock = false
    var responseData = Data([1, 2, 3])
    var responseETag: String? = "revision"
    var returnNotModified = false
    private(set) var calls: [Int64] = []
    private(set) var validators: [(String?, String?)] = []
    private(set) var cancelled: Set<Int64> = []
    private var released: Set<Int64> = []
    private var callWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]

    func configure(fail: Bool = false, block: Bool = false, data: Data = Data([1, 2, 3]),
                   etag: String? = "revision", notModified: Bool = false) {
        shouldFail = fail
        shouldBlock = block
        responseData = data
        responseETag = etag
        returnNotModified = notModified
    }

    var progressSteps: [TransferProgress] = []

    func setProgressSteps(_ steps: [TransferProgress]) { progressSteps = steps }
    func release(_ unitID: Int64) { released.insert(unitID) }
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?,
                   progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> MediaResponse {
        for step in progressSteps { progress(step) }
        return try await fullImage(resource, etag: etag, lastModified: lastModified)
    }
    func waitUntilCalled(_ unitID: Int64) async {
        if calls.contains(unitID) { return }
        await withCheckedContinuation { callWaiters[unitID, default: []].append($0) }
    }
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> MediaResponse {
        calls.append(resource.unitID)
        for waiter in callWaiters.removeValue(forKey: resource.unitID) ?? [] { waiter.resume() }
        validators.append((etag, lastModified))
        if shouldFail { throw TestFailure("Original image unavailable") }
        do {
            while shouldBlock && !released.contains(resource.unitID) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch is CancellationError {
            cancelled.insert(resource.unitID)
            throw CancellationError()
        }
        if returnNotModified {
            return MediaResponse(data: nil, etag: responseETag, lastModified: nil)
        }
        return MediaResponse(data: responseData, etag: responseETag, lastModified: nil)
    }
}

final class FullImageRepositoryTests: XCTestCase {
    private let credentials = SynologyCredentials(username: "full-image", password: "unused")
    private let server = URL(string: "https://full-image.example.invalid")!

    private func root() -> URL { temporaryTestRoot("SynoFullImageTest") }

    private func repository(root: URL, transport: FullImageTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    private func resource(_ id: Int64) -> FullImageResource {
        FullImageResource(scope: .space(.personal), unitID: id, cacheKey: "revision-\(id)", filename: "\(id).jpg")
    }

    private func consume(_ repository: CachedPhotosRepository, _ resource: FullImageResource,
                         priority: RequestPriority = .visible) -> Task<[ResourceEvent<Data>], Never> {
        Task {
            var events: [ResourceEvent<Data>] = []
            for await event in await repository.fullImage(resource, priority: priority) { events.append(event) }
            return events
        }
    }

    func testProgressStreamFollowsTransferStartedByAnotherSubscriber() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = FullImageTransport()
        await transport.configure(block: true)
        await transport.setProgressSteps([TransferProgress(completedBytes: 40, totalBytes: 100),
                                          TransferProgress(completedBytes: 60, totalBytes: 100)])
        let repository = try repository(root: cacheRoot, transport: transport)
        let image = resource(30)
        let loading = consume(repository, image)
        await transport.waitUntilCalled(30)

        // A subscriber that arrives mid-transfer receives its progress, replayed or live.
        var iterator = await repository.fullImageProgress(image).makeAsyncIterator()
        var latest = await iterator.next()
        for _ in 0..<100 where latest?.completedBytes != 60 {
            latest = await iterator.next()
        }
        XCTAssertEqual(latest, TransferProgress(completedBytes: 60, totalBytes: 100))

        await transport.release(30)
        let events = await loading.value
        XCTAssertEqual(events.count, 1)
    }

    func testCachedFirstValidationOncePerRunAndOfflineFallback() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let image = resource(10)
        let firstTransport = FullImageTransport()
        await firstTransport.configure(data: Data([9, 8, 7]), etag: "etag-10")
        let firstRepository = try repository(root: cacheRoot, transport: firstTransport)

        let firstEvents = await consume(firstRepository, image).value
        guard case .value(let downloaded, true) = firstEvents.last else {
            return XCTFail("Expected a verified downloaded original")
        }
        XCTAssertEqual(downloaded, Data([9, 8, 7]))
        _ = await consume(firstRepository, image).value
        let firstCalls = await firstTransport.calls
        XCTAssertEqual(firstCalls, [10], "A validated resource should not be checked twice in one run")

        let validatingTransport = FullImageTransport()
        await validatingTransport.configure(data: Data(), etag: "etag-10", notModified: true)
        let validatingRepository = try repository(root: cacheRoot, transport: validatingTransport)
        let validationEvents = await consume(validatingRepository, image).value
        XCTAssertEqual(validationEvents.count, 2)
        if case .value(let cached, false) = validationEvents[0] { XCTAssertEqual(cached, Data([9, 8, 7])) }
        else { XCTFail("Cached bytes did not arrive before validation") }
        if case .value(let reused, true) = validationEvents[1] { XCTAssertEqual(reused, Data([9, 8, 7])) }
        else { XCTFail("Conditional validation did not reuse cached bytes") }
        let validator = await validatingTransport.validators.first?.0
        XCTAssertEqual(validator, "etag-10")

        let offlineTransport = FullImageTransport()
        await offlineTransport.configure(fail: true)
        let offlineRepository = try repository(root: cacheRoot, transport: offlineTransport)
        let offlineEvents = await consume(offlineRepository, image).value
        XCTAssertEqual(offlineEvents.count, 2)
        if case .value(let cached, false) = offlineEvents[0] { XCTAssertEqual(cached, Data([9, 8, 7])) }
        else { XCTFail("Offline access did not yield the cached original first") }
        if case .failure = offlineEvents[1] {} else { XCTFail("Expected the offline validation failure") }
    }

    func testCachedAPIErrorBodyIsDiscardedAndRefetched() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let image = resource(30)
        let poison = Data(#"{"error":{"code":119},"success":false}"#.utf8)
        let seedTransport = FullImageTransport()
        await seedTransport.configure(data: poison)
        _ = await consume(try repository(root: cacheRoot, transport: seedTransport), image).value

        let offline = try repository(root: cacheRoot, transport: FullImageTransport())
        var offlineEvents: [ResourceEvent<Data>] = []
        for await event in await offline.fullImage(image, allowNetwork: false) { offlineEvents.append(event) }
        XCTAssertTrue(offlineEvents.isEmpty, "An error body must not be served as the cached original")

        let transport = FullImageTransport()
        await transport.configure(data: Data([4, 5, 6]), etag: "fresh")
        let events = await consume(try repository(root: cacheRoot, transport: transport), image).value
        XCTAssertEqual(events.count, 1)
        if case .value(let bytes, true) = events[0] { XCTAssertEqual(bytes, Data([4, 5, 6])) }
        else { XCTFail("Expected a verified download") }
        let validator = await transport.validators.first?.0
        XCTAssertNil(validator, "A discarded entry's validators must not be reused")
    }

    func testMetadataResetLetsAdmittedOriginalFinishAfterLastSubscriberLeaves() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let image = resource(15)
        let transport = FullImageTransport()
        await transport.configure(block: true, data: Data([8, 6, 7, 5, 3, 0, 9]))
        let repository = try repository(root: cacheRoot, transport: transport)

        let first = consume(repository, image)
        await transport.waitUntilCalled(image.unitID)
        try await repository.clearMetadataCache()
        first.cancel()

        await transport.release(image.unitID)
        let secondEvents = await consume(repository, image).value
        guard case .value(let bytes, true) = secondEvents.last else {
            return XCTFail("The admitted original did not survive metadata-only invalidation")
        }
        XCTAssertEqual(bytes, Data([8, 6, 7, 5, 3, 0, 9]))
        let calls = await transport.calls
        XCTAssertEqual(calls, [15], "The surviving transfer should be joined or reused, not restarted")
        let cancelled = await transport.cancelled
        XCTAssertFalse(cancelled.contains(15))
    }

    func testCoalescingSpeculativeLimitPromotionAndCancellation() async throws {
        let cacheRoot = root(); defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = FullImageTransport()
        await transport.configure(block: true)
        let repository = try repository(root: cacheRoot, transport: transport)
        let a = resource(1), b = resource(2), c = resource(3)

        let aTask = consume(repository, a, priority: .prefetch)
        let aStarted = await waitUntil { await transport.calls == [1] }
        XCTAssertTrue(aStarted)
        let bTask = consume(repository, b, priority: .prefetch)
        try? await Task.sleep(for: .milliseconds(30))
        let callsWithQueuedB = await transport.calls
        XCTAssertEqual(callsWithQueuedB, [1], "Only one speculative transfer may run")

        let cPrefetch = consume(repository, c, priority: .prefetch)
        try? await Task.sleep(for: .milliseconds(20))
        let cCurrent = consume(repository, c, priority: .visible)
        await repository.promoteFullImage(c)
        let cStarted = await waitUntil { await transport.calls.contains(3) }
        XCTAssertTrue(cStarted)
        let callsWithCurrent = await transport.calls
        XCTAssertEqual(callsWithCurrent.filter { $0 == 3 }.count, 1, "Current and prefetch subscribers should coalesce")

        await transport.release(3)
        _ = await cPrefetch.value
        _ = await cCurrent.value
        try? await Task.sleep(for: .milliseconds(20))
        let callsBeforeARelease = await transport.calls
        XCTAssertEqual(callsBeforeARelease, [1, 3], "A second speculative transfer stays queued while one is active")
        await transport.release(1)
        _ = await aTask.value
        let bStarted = await waitUntil { await transport.calls == [1, 3, 2] }
        XCTAssertTrue(bStarted)
        await transport.release(2)
        _ = await bTask.value

        let obsolete = resource(4)
        let obsoleteTask = consume(repository, obsolete)
        let obsoleteStarted = await waitUntil { await transport.calls.last == 4 }
        XCTAssertTrue(obsoleteStarted)
        obsoleteTask.cancel()
        _ = await obsoleteTask.value
        let obsoleteCancelled = await waitUntil { await transport.cancelled.contains(4) }
        XCTAssertTrue(obsoleteCancelled,
                      "Dropping the last current-image subscriber should cancel its transfer")
    }

    func testGateRetainsPromotionBeforeAcquireAndClearsCancelledPendingID() async throws {
        let gate = FullImageGate(total: 2, speculative: 1, queue: 4)
        let speculative = UUID()
        try await gate.acquire(priority: .prefetch, id: speculative)

        let promoted = UUID()
        await gate.promote(promoted)
        let pendingBeforeAcquire = await gate.pendingPromotionCount()
        XCTAssertEqual(pendingBeforeAcquire, 1)
        let promotedTask = Task { try await gate.acquire(priority: .prefetch, id: promoted) }
        let promotedStarted = await waitUntil {
            await gate.activePriority(promoted) == .visible
        }
        XCTAssertTrue(promotedStarted,
                      "An early promotion should use the slot reserved for the current image")
        try await promotedTask.value
        let pendingAfterAcquire = await gate.pendingPromotionCount()
        XCTAssertEqual(pendingAfterAcquire, 0)
        await gate.promote(promoted)
        let pendingAfterRepeatedPromotion = await gate.pendingPromotionCount()
        XCTAssertEqual(pendingAfterRepeatedPromotion, 0)

        let cancelled = UUID()
        await gate.promote(cancelled)
        let pendingBeforeCancellation = await gate.pendingPromotionCount()
        XCTAssertEqual(pendingBeforeCancellation, 1)
        let cancelledTask = Task { try await gate.acquire(priority: .prefetch, id: cancelled) }
        cancelledTask.cancel()
        do {
            try await cancelledTask.value
            XCTFail("Cancelled admission unexpectedly started")
        } catch is CancellationError {}
        let pendingCleared = await waitUntil { await gate.pendingPromotionCount() == 0 }
        XCTAssertTrue(pendingCleared)

        let releasedBeforeAcquire = UUID()
        await gate.promote(releasedBeforeAcquire)
        await gate.release(releasedBeforeAcquire)
        let releasedPendingCount = await gate.pendingPromotionCount()
        XCTAssertEqual(releasedPendingCount, 0,
                       "Releasing a job before admission should discard its pending promotion")

        await gate.release(promoted)
        await gate.release(speculative)
    }
}
