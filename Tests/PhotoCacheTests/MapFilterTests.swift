import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor MapFilterFakeTransport: PhotosTransport {
    var timelineSnapshot = TimelineSnapshot(sections: [])
    var pageItemsBySection: [TimelineSection: [PhotoItem]] = [:]
    var pageRequests: [TimelineSection] = []
    var favoriteWrites: [(Int64, Bool)] = []
    var pageFailure: String?
    var blocksPageRequests = false
    var blockedPageContinuations: [CheckedContinuation<Void, Never>] = []
    var blocksTimelineRequests = false
    var blockedTimelineContinuations: [CheckedContinuation<Void, Never>] = []

    func configure(timelineSnapshot: TimelineSnapshot = TimelineSnapshot(sections: []),
                   pageItemsBySection: [TimelineSection: [PhotoItem]] = [:],
                   pageFailure: String? = nil,
                   blocksPageRequests: Bool = false,
                   blocksTimelineRequests: Bool = false) {
        self.timelineSnapshot = timelineSnapshot
        self.pageItemsBySection = pageItemsBySection
        self.pageFailure = pageFailure
        self.blocksPageRequests = blocksPageRequests
        self.blocksTimelineRequests = blocksTimelineRequests
    }

    func login(credentials: SynologyCredentials) async throws {}

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        if blocksTimelineRequests {
            await withCheckedContinuation { continuation in
                blockedTimelineContinuations.append(continuation)
            }
        }
        return timelineSnapshot
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        pageRequests.append(section)
        if blocksPageRequests {
            await withCheckedContinuation { continuation in
                blockedPageContinuations.append(continuation)
            }
        }
        if let pageFailure { throw TestFailure(pageFailure) }
        return pageItemsBySection[section] ?? []
    }

    func releasePageRequests() {
        blocksPageRequests = false
        let continuations = blockedPageContinuations
        blockedPageContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func releaseTimelineRequests() {
        blocksTimelineRequests = false
        let continuations = blockedTimelineContinuations
        blockedTimelineContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        favoriteWrites.append(contentsOf: itemIDs.map { ($0, favorite) })
    }
}

private actor MapFilterEventProbe {
    private var firstIDs: [Int64]?

    func record(_ ids: [Int64]) -> Bool {
        guard firstIDs == nil else { return false }
        firstIDs = ids
        return true
    }

    func value() -> [Int64]? { firstIDs }
}

final class MapFilterTests: XCTestCase {
    private let server = URL(string: "https://example.invalid")!
    private let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")
    private let day = Int64(1_704_067_200)

    private func root() -> URL { temporaryTestRoot("SynoMapFilterTest") }

    private func makeRepository(root: URL, transport: MapFilterFakeTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server,
                                   cacheRoot: root, transport: transport)
    }

    private func item(_ id: Int64, dayOffset: Int = 0) throws -> PhotoItem {
        let time = day + Int64(dayOffset) * 86_400 + id
        let json = """
        {"id":\(id),"time":\(time),"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"\(id)_rev"}}}
        """
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func day(_ day: Int, count: Int) -> TimelineDay {
        TimelineDay(year: 2024, month: 1, day: day, itemCount: count)
    }

    private func section(day dayNumber: Int, offset: Int = 0, limit: Int, count: Int? = nil) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
                        list: [day(dayNumber, count: count ?? limit)])
    }

    private func seedPersonalPage(_ items: [PhotoItem], section: TimelineSection,
                                  validatedRun: String?,
                                  repository: CachedPhotosRepository) async throws {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: section,
                                              collection: .personalLibrary))
        try await repository.store.put(key, kind: .page, data: JSONEncoder().encode(items),
                                       validatedRun: validatedRun)
    }

    private func pageValueEvents(_ repository: CachedPhotosRepository, section: TimelineSection,
                                 collection: PhotoCollectionDescriptor,
                                 allowNetwork: Bool) async
        -> (values: [(items: [PhotoItem], verified: Bool)], failure: String?) {
        var values: [(items: [PhotoItem], verified: Bool)] = []
        var failure: String?
        for await event in await repository.page(section, collection: collection,
                                                 allowNetwork: allowNetwork) {
            switch event {
            case .value(let items, let verified): values.append((items, verified))
            case .failure(let message): failure = message
            }
        }
        return (values, failure)
    }

    func testRegistrationValidation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(root: root, transport: MapFilterFakeTransport())
        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let snapshot = TimelineSnapshot(sections: [section(day: 1, limit: 1)])
        do {
            try await repository.registerMapFilter(.personalLibrary, source: .personalLibrary,
                                                   snapshot: snapshot, itemIDsBySection: [[1]])
            XCTFail("A non-map descriptor must be rejected")
        } catch {}
        do {
            try await repository.registerMapFilter(descriptor, source: .favorites,
                                                   snapshot: snapshot, itemIDsBySection: [[1]])
            XCTFail("A non-personal source must be rejected")
        } catch {}
        do {
            try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                                   snapshot: snapshot, itemIDsBySection: [])
            XCTFail("A mismatched section count must be rejected")
        } catch {}
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: snapshot, itemIDsBySection: [[1]])
        let registered = await repository.latestTimelineSnapshot(collection: descriptor)
        XCTAssertEqual(registered?.sections, snapshot.sections)
    }

    func testFilteredPageFetchesOnlyTheDaysPersonalSectionsAndFiltersToIDs() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 3)
        let otherDaySection = section(day: 2, limit: 1)
        let items = [try item(3), try item(1), try item(2)]
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection,
                                                                                otherDaySection]),
                                  pageItemsBySection: [personalSection: items,
                                                       otherDaySection: [try item(9, dayOffset: 1)]])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 2)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[3, 1]])

        let result = await pageValueEvents(repository, section: descriptorSection,
                                           collection: descriptor, allowNetwork: true)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.values.last?.items.map(\.id), [3, 1])
        XCTAssertEqual(result.values.last?.verified, true)
        let requests = await transport.pageRequests
        XCTAssertEqual(requests, [personalSection],
                       "A filtered page must demand only the complete personal sections for its day")
    }

    func testFilteredPageReusesValidatedPersonalPageWithoutPageRequest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 3)
        let items = [try item(3), try item(1), try item(2)]
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: items])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}
        let validation = await repository.validationRun(for: .personalLibrary)
        try await seedPersonalPage(items, section: personalSection,
                                   validatedRun: validation, repository: repository)

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 2)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[3, 1]])

        let result = await pageValueEvents(repository, section: descriptorSection,
                                           collection: descriptor, allowNetwork: true)
        XCTAssertEqual(result.values.last?.items.map(\.id), [3, 1])
        XCTAssertEqual(result.values.last?.verified, true)
        let requests = await transport.pageRequests
        XCTAssertTrue(requests.isEmpty,
                      "A personal page validated during this run must satisfy the filter without network")
    }

    func testFilteredPageServesStaleCachedPageOffline() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 2)
        let items = [try item(1), try item(2)]
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: items])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}
        try await seedPersonalPage(items, section: personalSection,
                                   validatedRun: nil, repository: repository)

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 2)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1, 2]])

        let result = await pageValueEvents(repository, section: descriptorSection,
                                           collection: descriptor, allowNetwork: false)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.values.last?.items.map(\.id), [1, 2])
        XCTAssertEqual(result.values.last?.verified, false)
        let requests = await transport.pageRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCachedFilterPassPublishesEveryCoveringSectionBeforeBlockedValidation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let first = TimelineSection(offset: 0, limit: 1, list: [day(1, count: 2)])
        let second = TimelineSection(offset: 1, limit: 1, list: [day(1, count: 2)])
        let firstItem = try item(1)
        let secondItem = try item(2)
        await transport.configure(
            timelineSnapshot: TimelineSnapshot(sections: [first, second]),
            pageItemsBySection: [first: [firstItem], second: [secondItem]],
            blocksPageRequests: true
        )
        let repository = try makeRepository(root: root, transport: transport)
        // Load geometry before beginning the blocked page validation.
        for await _ in await repository.timeline() {}
        try await seedPersonalPage([firstItem], section: first, validatedRun: nil, repository: repository)
        try await seedPersonalPage([secondItem], section: second, validatedRun: nil, repository: repository)

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let filtered = TimelineSection(offset: 0, limit: 2, list: [day(1, count: 2)])
        try await repository.registerMapFilter(
            descriptor,
            source: .personalLibrary,
            snapshot: TimelineSnapshot(sections: [filtered]),
            itemIDsBySection: [[1, 2]]
        )

        let cachedValue = expectation(description: "cached filtered value")
        let probe = MapFilterEventProbe()
        let task = Task {
            for await event in await repository.page(filtered, collection: descriptor, allowNetwork: true) {
                if case .value(let items, let verified) = event, !verified,
                   await probe.record(items.map(\.id)) {
                    cachedValue.fulfill()
                }
            }
        }
        await fulfillment(of: [cachedValue], timeout: 1)
        let firstIDs = await probe.value()
        XCTAssertEqual(firstIDs, [1, 2], "The cache-only pass must not stop behind the first network stream")
        await transport.releasePageRequests()
        await task.value
    }

    func testCachedFilterValueArrivesWhileTimelineValidationIsBlocked() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let personalSection = section(day: 1, limit: 1)
        let photo = try item(1)
        let snapshot = TimelineSnapshot(sections: [personalSection])

        let seedingTransport = MapFilterFakeTransport()
        await seedingTransport.configure(timelineSnapshot: snapshot,
                                         pageItemsBySection: [personalSection: [photo]])
        let seedingRepository = try makeRepository(root: root, transport: seedingTransport)
        for await _ in await seedingRepository.timeline() {}
        try await seedPersonalPage([photo], section: personalSection,
                                   validatedRun: nil, repository: seedingRepository)

        let blockedTransport = MapFilterFakeTransport()
        await blockedTransport.configure(timelineSnapshot: snapshot,
                                         pageItemsBySection: [personalSection: [photo]],
                                         blocksTimelineRequests: true)
        let repository = try makeRepository(root: root, transport: blockedTransport)
        let cachedTimeline = expectation(description: "cached timeline")
        let timelineTask = Task {
            for await event in await repository.timeline() {
                if case .value(_, false) = event { cachedTimeline.fulfill() }
            }
        }
        await fulfillment(of: [cachedTimeline], timeout: 1)

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        try await repository.registerMapFilter(
            descriptor,
            source: .personalLibrary,
            snapshot: snapshot,
            itemIDsBySection: [[photo.id]]
        )
        let cachedFilter = expectation(description: "cached filter")
        let filterTask = Task {
            for await event in await repository.page(personalSection, collection: descriptor,
                                                     allowNetwork: true) {
                if case .value(let items, false) = event, items.map(\.id) == [photo.id] {
                    cachedFilter.fulfill()
                }
            }
        }
        await fulfillment(of: [cachedFilter], timeout: 1)

        await blockedTransport.releaseTimelineRequests()
        await timelineTask.value
        await filterTask.value
    }

    func testFilteredPageFansOutAcrossSplitDaySections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let first = TimelineSection(offset: 0, limit: 2, list: [day(1, count: 3)])
        let second = TimelineSection(offset: 2, limit: 1, list: [day(1, count: 3)])
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [first, second]),
                                  pageItemsBySection: [first: [try item(1), try item(3)],
                                                       second: [try item(2)]])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = TimelineSection(offset: 0, limit: 3, list: [day(1, count: 3)])
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1, 2, 3]])

        let result = await pageValueEvents(repository, section: descriptorSection,
                                           collection: descriptor, allowNetwork: true)
        XCTAssertEqual(result.values.last?.items.map(\.id), [1, 2, 3])
        XCTAssertEqual(result.values.last?.verified, true)
        let requests = await transport.pageRequests
        XCTAssertEqual(requests, [first, second])
    }

    func testFilteredPageMissingRegisteredIDIsNotVerifiedOrSessionCached() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 2)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: [try item(1)]])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 2)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1, 2]])

        let first = await pageValueEvents(repository, section: descriptorSection,
                                          collection: descriptor, allowNetwork: true)
        XCTAssertEqual(first.values.last?.items.map(\.id), [1])
        XCTAssertEqual(first.values.last?.verified, false)

        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let personalKey = try XCTUnwrap(CacheKey.page(namespace: namespace,
                                                      section: personalSection,
                                                      collection: .personalLibrary))
        try await repository.store.remove(personalKey)
        let requestsBeforeRetry = await transport.pageRequests.count
        let retry = await pageValueEvents(repository, section: descriptorSection,
                                          collection: descriptor, allowNetwork: true)
        XCTAssertEqual(retry.values.last?.verified, false)
        let requestsAfterRetry = await transport.pageRequests.count
        XCTAssertGreaterThan(requestsAfterRetry, requestsBeforeRetry,
                             "An incomplete result must not become a verified session-cache hit")
    }

    func testFilteredPageSessionCacheServesRepeatedRequests() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 1)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: [try item(1)]])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 1)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1]])
        _ = await pageValueEvents(repository, section: descriptorSection,
                                  collection: descriptor, allowNetwork: true)
        let before = await transport.pageRequests.count
        let repeated = await pageValueEvents(repository, section: descriptorSection,
                                             collection: descriptor, allowNetwork: true)
        XCTAssertEqual(repeated.values.last?.items.map(\.id), [1])
        let after = await transport.pageRequests.count
        XCTAssertEqual(after, before)
    }

    func testFilteredPageSessionCacheEvictsBeyondCap() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        var sections: [TimelineSection] = []
        var pages: [TimelineSection: [PhotoItem]] = [:]
        for index in 1...13 {
            let sec = section(day: index, limit: 1)
            sections.append(sec)
            pages[sec] = [try item(Int64(index), dayOffset: index - 1)]
        }
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: sections),
                                  pageItemsBySection: pages)
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: sections),
                                               itemIDsBySection: (1...13).map { [Int64($0)] })
        for sec in sections {
            _ = await pageValueEvents(repository, section: sec, collection: descriptor,
                                      allowNetwork: true)
        }
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        for sec in sections {
            let key = try XCTUnwrap(CacheKey.page(namespace: namespace, section: sec,
                                                  collection: .personalLibrary))
            try await repository.store.remove(key)
        }
        let oldest = await pageValueEvents(repository, section: sections[0], collection: descriptor,
                                           allowNetwork: false)
        XCTAssertTrue(oldest.values.isEmpty, "The oldest session page must be evicted")
        let newest = await pageValueEvents(repository, section: sections[12], collection: descriptor,
                                           allowNetwork: false)
        XCTAssertEqual(newest.values.last?.items.map(\.id), [13])
    }

    func testFilteredPageFailureIsReported() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 1)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: [try item(1)]],
                                  pageFailure: "Network unavailable")
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 1)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1]])
        let result = await pageValueEvents(repository, section: descriptorSection,
                                           collection: descriptor, allowNetwork: true)
        XCTAssertNotNil(result.failure)
        XCTAssertTrue(result.values.isEmpty)
    }

    func testFavoritesOverridesAreApplied() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 1)
        let photo = try item(1)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: [photo]])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 1)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1]])
        try await repository.setFavorite(itemID: 1, item: photo, in: personalSection,
                                         collection: .personalLibrary, to: true)

        let result = await pageValueEvents(repository, section: descriptorSection,
                                           collection: descriptor, allowNetwork: true)
        XCTAssertEqual(result.values.last?.items.first?.isFavorite, true)
    }

    func testUnregisterClearsStateAndUnknownFilterFails() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = MapFilterFakeTransport()
        let personalSection = section(day: 1, limit: 1)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [personalSection]),
                                  pageItemsBySection: [personalSection: [try item(1)]])
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let descriptorSection = section(day: 1, limit: 1)
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[1]])
        _ = await pageValueEvents(repository, section: descriptorSection,
                                  collection: descriptor, allowNetwork: true)
        await repository.unregisterMapFilter(descriptor)
        let snapshot = await repository.latestTimelineSnapshot(collection: descriptor)
        XCTAssertNil(snapshot)

        let after = await pageValueEvents(repository, section: descriptorSection,
                                          collection: descriptor, allowNetwork: true)
        XCTAssertNotNil(after.failure)
        XCTAssertTrue(after.values.isEmpty)

        let unknown = await pageValueEvents(repository, section: descriptorSection,
                                            collection: .mapFilter(UUID()), allowNetwork: true)
        XCTAssertNotNil(unknown.failure)
    }

    func testLocationReplacementPublishesTypedFilterInvalidation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(root: root, transport: MapFilterFakeTransport())
        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        let filteredSection = section(day: 1, limit: 1)
        try await repository.registerMapFilter(
            descriptor,
            source: .personalLibrary,
            snapshot: TimelineSnapshot(sections: [filteredSection]),
            itemIDsBySection: [[1]]
        )
        var invalidations = await repository.mapFilterInvalidations().makeAsyncIterator()

        await repository.invalidateMapFiltersForLocationChange()

        let invalidated = await invalidations.next()
        let snapshot = await repository.latestTimelineSnapshot(collection: descriptor)
        XCTAssertEqual(invalidated, descriptor)
        XCTAssertNil(snapshot)
    }

    func testBatchFavoriteOnFilterPatchesPersonalPagesByDay() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let transport = MapFilterFakeTransport()
        let descriptorSection = section(day: 1, limit: 1)
        await transport.configure(timelineSnapshot: TimelineSnapshot(sections: [descriptorSection]))
        let repository = try makeRepository(root: root, transport: transport)
        for await _ in await repository.timeline() {}
        let photo = try item(9)
        let personalKey = try XCTUnwrap(CacheKey.page(namespace: namespace, section: descriptorSection,
                                                      collection: .personalLibrary))
        try await repository.store.put(personalKey, kind: .page,
                                       data: JSONEncoder().encode([photo]), validatedRun: nil)

        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        try await repository.registerMapFilter(descriptor, source: .personalLibrary,
                                               snapshot: TimelineSnapshot(sections: [descriptorSection]),
                                               itemIDsBySection: [[photo.id]])
        let action = SelectionFavoriteAction(affectedIDs: [photo.id], targetFavorite: true,
                                             sectionsByID: [photo.id: descriptorSection],
                                             collection: descriptor,
                                             itemsByID: [photo.id: photo])
        try await repository.setFavoritesBatch(action: action)

        let cached = try await repository.store.get(personalKey)
        let personalItems = try JSONDecoder().decode([PhotoItem].self,
                                                     from: try XCTUnwrap(cached).data)
        XCTAssertTrue(personalItems[0].isFavorite)
        let writes = await transport.favoriteWrites
        XCTAssertEqual(writes.map(\.0), [photo.id])
    }
}
