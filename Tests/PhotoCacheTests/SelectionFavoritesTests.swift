import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class SelectionFavoritesTests: XCTestCase {

    private func makeItem(id: Int64, time: Int64 = 1712102400,
                          isFavorite: Bool = false, filename: String? = nil) -> PhotoItem {
        let favoriteField = isFavorite ? "true" : "false"
        let filename = filename ?? "IMG_\(id).jpg"
        let json = """
        {"id":\(id),"filename":"\(filename)","time":\(time),"type":"photo","additional":{"thumbnail":{"unit_id":\(id),"cache_key":"key_\(id)","sm":"ready","m":"ready","xl":"ready"},"resolution":{"width":1000,"height":1000},"orientation":1,"favorite":\(favoriteField)}}
        """
        return try! JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func makeRepository(
        transport: SelectionFavoritesMockTransport,
        root: URL
    ) throws -> CachedPhotosRepository {
        let creds = SynologyCredentials(username: "alice", password: "pw", otpSecret: "unused")
        return try CachedPhotosRepository(credentials: creds, budget: 100_000_000, cacheRoot: root, transport: transport)
    }

    private func pageKey(for section: TimelineSection) throws -> String {
        let namespace = CacheKey.namespace(server: SynologyClient.defaultBaseURL, account: "alice")
        return try XCTUnwrap(CacheKey.page(scope: .space(.personal), namespace: namespace, section: section, collection: .personalLibrary))
    }

    private func seedPage(_ items: [PhotoItem], section: TimelineSection,
                          repository: CachedPhotosRepository) async throws {
        try await seedMetadataPage(items, section: section, repository: repository)
    }

    private func cachedPage(_ section: TimelineSection,
                            repository: CachedPhotosRepository) async throws -> [PhotoItem] {
        return try await repository.store.metadataPage(try DayPageAddress(section: section, collection: .personalLibrary), namespace: repository.metadataNamespace, currentRun: repository.runID)?.completeItems ?? []
    }

    // MARK: - Target Calculation Tests

    func testTargetCalculationForEmptySelectionReturnsNil() async throws {
        let root = temporaryTestRoot("EmptySelection")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let section = TimelineSection(offset: 0, limit: 10, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 10)])
        let snapshot = TimelineSnapshot(sections: [section])
        let resolver = SelectionFavoriteResolver(repository: repo)

        let action = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(),
            knownItemIDsByOrdinal: [:]
        )
        XCTAssertNil(action)
    }

    func testTargetCalculationForMixedInputFavoritesTheNonFavorites() async throws {
        let root = temporaryTestRoot("MixedSelection")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        // 4 favorites (IDs 1..4), 2 non-favorites (IDs 5, 6)
        var items: [PhotoItem] = []
        for id in 1...4 { items.append(makeItem(id: Int64(id), isFavorite: true)) }
        for id in 5...6 { items.append(makeItem(id: Int64(id), isFavorite: false)) }
        await transport.setPage(items, offset: 0)

        let section = TimelineSection(offset: 0, limit: 6, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 6)])
        let snapshot = TimelineSnapshot(sections: [section])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        let resolved = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...5),
            knownItemIDsByOrdinal: [:]
        )
        let action = try XCTUnwrap(resolved)

        XCTAssertTrue(action.targetFavorite)
        XCTAssertEqual(action.affectedIDs.sorted(), [5, 6])
    }

    func testTargetCalculationForEntirelyFavoriteSelectionUnfavoritesAll() async throws {
        let root = temporaryTestRoot("AllFavorites")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let items = (1...6).map { makeItem(id: Int64($0), isFavorite: true) }
        await transport.setPage(items, offset: 0)

        let section = TimelineSection(offset: 0, limit: 6, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 6)])
        let snapshot = TimelineSnapshot(sections: [section])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        let resolved = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...5),
            knownItemIDsByOrdinal: [:]
        )
        let action = try XCTUnwrap(resolved)

        XCTAssertFalse(action.targetFavorite)
        XCTAssertEqual(action.affectedIDs.sorted(), [1, 2, 3, 4, 5, 6])
    }

    func testTargetCalculationForEntirelyUnfavoriteSelectionFavoritesAll() async throws {
        let root = temporaryTestRoot("AllUnfavorites")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let items = (1...6).map { makeItem(id: Int64($0), isFavorite: false) }
        await transport.setPage(items, offset: 0)

        let section = TimelineSection(offset: 0, limit: 6, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 6)])
        let snapshot = TimelineSnapshot(sections: [section])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        let resolved = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...5),
            knownItemIDsByOrdinal: [:]
        )
        let action = try XCTUnwrap(resolved)

        XCTAssertTrue(action.targetFavorite)
        XCTAssertEqual(action.affectedIDs.sorted(), [1, 2, 3, 4, 5, 6])
    }

    func testTargetCalculationFor96FavoritesAnd4NonFavoritesFavoritesThe4() async throws {
        let root = temporaryTestRoot("96and4")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        var items: [PhotoItem] = []
        for id in 1...96 { items.append(makeItem(id: Int64(id), isFavorite: true)) }
        for id in 97...100 { items.append(makeItem(id: Int64(id), isFavorite: false)) }
        await transport.setPage(items, offset: 0)

        let section = TimelineSection(offset: 0, limit: 100, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 100)])
        let snapshot = TimelineSnapshot(sections: [section])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        let resolved = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...99),
            knownItemIDsByOrdinal: [:]
        )
        let action = try XCTUnwrap(resolved)

        XCTAssertTrue(action.targetFavorite)
        XCTAssertEqual(action.affectedIDs.sorted(), [97, 98, 99, 100])
    }

    // MARK: - Bounded Resolution Tests

    func testSelectionsSpanningSplitDayAndSplitPageSectionsResolveCorrectly() async throws {
        let root = temporaryTestRoot("SplitSections")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()

        let sec0 = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 2, itemCount: 2)])
        let sec1 = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])
        await transport.setPage([makeItem(id: 1, isFavorite: true), makeItem(id: 2, isFavorite: true)], offset: 0)
        await transport.setPage([makeItem(id: 3), makeItem(id: 4)], offset: 2)

        let snapshot = TimelineSnapshot(sections: [sec0, sec1])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        // Select ordinals 0 (id 1), 2 (id 3), 3 (id 4)
        var selected = IndexSet()
        selected.insert(0); selected.insert(2); selected.insert(3)
        let resolved = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: selected,
            knownItemIDsByOrdinal: [:]
        )
        let action = try XCTUnwrap(resolved)

        XCTAssertTrue(action.targetFavorite)
        XCTAssertEqual(action.affectedIDs.sorted(), [3, 4])
        XCTAssertEqual(action.sectionsByID[3], sec1)
        XCTAssertEqual(action.sectionsByID[4], sec1)
    }

    func testMetadataResolutionStaysBoundedAndPerformsNoImageRequests() async throws {
        let root = temporaryTestRoot("NoImageRequests")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        await transport.setPage([makeItem(id: 1), makeItem(id: 2)], offset: 0)
        let sec = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        _ = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integersIn: 0...1),
            knownItemIDsByOrdinal: [:]
        )

        let counts = await transport.recordedCounts()
        XCTAssertEqual(counts.thumbnails, 0)
        XCTAssertEqual(counts.fullImages, 0)
    }

    func testChangedFingerprintAbortsResolution() async throws {
        let root = temporaryTestRoot("FingerprintAbort")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        await transport.setPage([makeItem(id: 1)], offset: 0)
        let sec = TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])
        let snapshot = TimelineSnapshot(sections: [sec])
        let repo = try makeRepository(transport: transport, root: root)

        // Seed repository with a DIFFERENT snapshot
        let changedSec = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])
        let changedSnapshot = TimelineSnapshot(sections: [changedSec])
        await transport.setTimeline(changedSnapshot, for: .personalLibrary)
        for await _ in await repo.timeline(collection: .personalLibrary) {}

        let resolver = SelectionFavoriteResolver(repository: repo)
        let action = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot, // older snapshot with different fingerprint
            selectedOrdinals: IndexSet(integer: 0),
            knownItemIDsByOrdinal: [:]
        )
        XCTAssertNil(action)
    }

    func testChangedKnownItemIdentityAbortsResolution() async throws {
        let root = temporaryTestRoot("IdentityAbort")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        await transport.setPage([makeItem(id: 100)], offset: 0)
        let sec = TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let resolver = SelectionFavoriteResolver(repository: repo)
        // Known ID was 999, but page verifies with ID 100 -> abort!
        let action = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0),
            knownItemIDsByOrdinal: [0: 999]
        )
        XCTAssertNil(action)
    }

    func testCapturedFingerprintMismatchAbortsBeforeResolvingPages() async throws {
        let root = temporaryTestRoot("CapturedFingerprintAbort")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        await transport.setPage([makeItem(id: 1)], offset: 0)
        let section = TimelineSection(
            offset: 0,
            limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)]
        )
        let snapshot = TimelineSnapshot(sections: [section])
        await transport.setTimeline(snapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)

        let staleSection = TimelineSection(
            offset: 0,
            limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)]
        )
        let resolver = SelectionFavoriteResolver(repository: repo)
        let action = await resolver.resolve(
            collection: .personalLibrary,
            snapshot: snapshot,
            selectedOrdinals: IndexSet(integer: 0),
            knownItemIDsByOrdinal: [:],
            expectedTimelineFingerprint: LibraryIndex(
                snapshot: TimelineSnapshot(sections: [staleSection])
            ).fingerprint
        )

        XCTAssertNil(action)
        let itemCallCount = await transport.itemCallCount
        XCTAssertEqual(itemCallCount, 0)
    }

    // MARK: - Batch Mutation & Transport Tests

    func testBatchRejectsPreparedActionAfterTimelineFingerprintChanges() async throws {
        let root = temporaryTestRoot("PreparedFingerprintAbort")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let currentSection = TimelineSection(
            offset: 0,
            limit: 2,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)]
        )
        let currentSnapshot = TimelineSnapshot(sections: [currentSection])
        await transport.setTimeline(currentSnapshot, for: .personalLibrary)
        let repo = try makeRepository(transport: transport, root: root)
        for await _ in await repo.timeline(collection: .personalLibrary) {}

        let staleSection = TimelineSection(
            offset: 0,
            limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)]
        )
        let action = SelectionFavoriteAction(
            affectedIDs: [1],
            targetFavorite: true,
            sectionsByID: [1: currentSection],
            collection: .personalLibrary,
            expectedTimelineFingerprint: LibraryIndex(
                snapshot: TimelineSnapshot(sections: [staleSection])
            ).fingerprint
        )

        do {
            try await repo.setFavoritesBatch(action: action)
            XCTFail("Expected a stale-selection failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The collection changed before the favorite update. Try again."
            )
        }
        let favoriteCalls = await transport.setFavoriteCalls
        XCTAssertTrue(favoriteCalls.isEmpty)
    }

    func testOrdinarySelectionProducesOneTransportCallContainingEveryAffectedID() async throws {
        let root = temporaryTestRoot("OneTransportCall")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 10, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 10)])
        let action = SelectionFavoriteAction(
            affectedIDs: [1, 2, 3, 4],
            targetFavorite: true,
            sectionsByID: Dictionary(uniqueKeysWithValues: (1...4).map { (Int64($0), sec) }),
            collection: .personalLibrary
        )

        try await repo.setFavoritesBatch(action: action)
        let calls = await transport.setFavoriteCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].itemIDs, [1, 2, 3, 4])
        XCTAssertEqual(calls[0].favorite, true)
    }

    func testVeryLargeSelectionUsesDeterministicChunksWithOneTargetValue() async throws {
        let root = temporaryTestRoot("ChunkedTransport")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 250, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 250)])
        let ids = (1...250).map { Int64($0) }
        let action = SelectionFavoriteAction(
            affectedIDs: ids,
            targetFavorite: false,
            sectionsByID: Dictionary(uniqueKeysWithValues: ids.map { ($0, sec) }),
            collection: .personalLibrary
        )

        try await repo.setFavoritesBatch(action: action)
        let calls = await transport.setFavoriteCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].itemIDs.count, 100)
        XCTAssertEqual(calls[1].itemIDs.count, 100)
        XCTAssertEqual(calls[2].itemIDs.count, 50)
        XCTAssertTrue(calls.allSatisfy { $0.favorite == false })
    }

    func testPendingIDConflictsAreRejectedAtomicallyBeforeAnyOptimisticUpdate() async throws {
        let root = temporaryTestRoot("PendingConflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        await transport.setFavoriteBlocked(true)
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 10, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 10)])

        // Launch an in-flight favorite on ID 42
        let task1 = Task {
            try await repo.setFavorite(itemID: 42, in: sec, to: true)
        }
        let blocked = await waitUntil { await transport.setFavoriteCalls.count == 1 }
        XCTAssertTrue(blocked)

        // Attempt a batch containing ID 42 along with IDs 1 and 2
        let conflictingAction = SelectionFavoriteAction(
            affectedIDs: [1, 42, 2],
            targetFavorite: true,
            sectionsByID: [1: sec, 42: sec, 2: sec],
            collection: .personalLibrary
        )

        do {
            try await repo.setFavoritesBatch(action: conflictingAction)
            XCTFail("Expected conflict error")
        } catch {}

        // Release the first write
        await transport.releaseFavorite()
        try await task1.value

        // Verify IDs 1 and 2 were never modified or called
        let calls = await transport.setFavoriteCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].itemIDs, [42])
    }

    func testInFlightPageFetchMergesOverOptimisticCachedPatchWithoutLosingFavorite() async throws {
        let root = temporaryTestRoot("PageFavoriteCAS")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let section = TimelineSection(
            offset: 0,
            limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)]
        )
        let old = makeItem(id: 1, isFavorite: false, filename: "OLD.jpg")
        let refreshed = makeItem(id: 1, isFavorite: false, filename: "NEW.jpg")
        await transport.setTimeline(TimelineSnapshot(sections: [section]), for: .personalLibrary)
        await transport.setPage([refreshed], offset: 0)
        await transport.setItemsBlocked(true)
        let repository = try makeRepository(transport: transport, root: root)
        for await _ in await repository.timeline(collection: .personalLibrary) {}
        try await seedPage([old], section: section, repository: repository)

        let pageTask = Task {
            for await _ in await repository.page(section, collection: .personalLibrary,
                                                  allowNetwork: true) {}
        }
        await transport.waitUntilItemRequested()
        let action = SelectionFavoriteAction(
            affectedIDs: [old.id],
            targetFavorite: true,
            sectionsByID: [old.id: section],
            collection: .personalLibrary,
            itemsByID: [old.id: old]
        )
        try await repository.setFavoritesBatch(action: action)
        await transport.releaseItems()
        await pageTask.value

        let stored = try await cachedPage(section, repository: repository)
        XCTAssertEqual(stored.first?.filename, "NEW.jpg",
                       "The authoritative page should win for ordinary metadata")
        XCTAssertEqual(stored.first?.isFavorite, true,
                       "A response admitted before the confirmed write must not overwrite it")
    }

    func testBatchObserversUpdateCanonicalRowsAcrossRetainedDays() async throws {
        let root = temporaryTestRoot("PageWindowBatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let sec0 = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 2, itemCount: 2)])
        let sec1 = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])
        await transport.setPage([makeItem(id: 1, isFavorite: false), makeItem(id: 2, isFavorite: false)], offset: 0)
        await transport.setPage([makeItem(id: 3, isFavorite: false), makeItem(id: 4, isFavorite: false)], offset: 2)
        let snapshot = TimelineSnapshot(sections: [sec0, sec1])
        await transport.setTimeline(snapshot, for: .personalLibrary)

        let repo = try makeRepository(transport: transport, root: root)
        let window = LibraryPageWindow(repository: repo, collection: .personalLibrary, maximumPages: 4)

        var stream = await window.events().makeAsyncIterator()
        await window.update(index: LibraryIndex(snapshot: snapshot), allowNetwork: true, visible: [0, 1], prefetch: [])

        // Drain initial page arrivals
        _ = await stream.next() // page 0
        _ = await stream.next() // page 1

        // Mutate IDs 1 and 3 across both pages
        let action = SelectionFavoriteAction(
            affectedIDs: [1, 3],
            targetFavorite: true,
            sectionsByID: [1: sec0, 3: sec1],
            collection: .personalLibrary
        )
        try await repo.setFavoritesBatch(action: action)

        // Verify each page receives updated items
        let pageUpdate1 = await stream.next()
        let pageUpdate2 = await stream.next()

        if case .page(let page, _) = pageUpdate1 {
            if page.sectionIndex == 0 {
                XCTAssertEqual(page.items.first(where: { $0.id == 1 })?.isFavorite, true)
            } else {
                XCTAssertEqual(page.items.first(where: { $0.id == 3 })?.isFavorite, true)
            }
        }
        if case .page(let page, _) = pageUpdate2 {
            if page.sectionIndex == 0 {
                XCTAssertEqual(page.items.first(where: { $0.id == 1 })?.isFavorite, true)
            } else {
                XCTAssertEqual(page.items.first(where: { $0.id == 3 })?.isFavorite, true)
            }
        }
        await window.cancelAll()
    }

    func testBatchMutationPatchesCachedPersonalLibraryPage() async throws {
        let root = temporaryTestRoot("PatchCachedPage")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])
        try await seedPage([makeItem(id: 1, isFavorite: false), makeItem(id: 2, isFavorite: true)],
                           section: sec, repository: repo)

        let action = SelectionFavoriteAction(
            affectedIDs: [1],
            targetFavorite: true,
            sectionsByID: [1: sec],
            collection: .personalLibrary
        )
        try await repo.setFavoritesBatch(action: action)

        let page = try await cachedPage(sec, repository: repo)
        XCTAssertEqual(page.first(where: { $0.id == 1 })?.isFavorite, true)
        XCTAssertEqual(page.first(where: { $0.id == 2 })?.isFavorite, true)
    }

    func testPartialFailureRollsBackOnlyFailedEntriesWithinCachedPage() async throws {
        let root = temporaryTestRoot("PartialPageRollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        // 250 items = 3 chunks (100, 100, 50). Fail chunk 1, so IDs 101...250 roll back.
        await transport.setFailOnChunkIndex(1)
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 250, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 250)])
        // A single page holds one item from the completed chunk (ID 1) and one from the failed chunk (ID 150).
        try await seedPage((1...250).map { makeItem(id: Int64($0)) },
                           section: sec, repository: repo)

        let ids = (1...250).map { Int64($0) }
        let action = SelectionFavoriteAction(
            affectedIDs: ids,
            targetFavorite: true,
            sectionsByID: Dictionary(uniqueKeysWithValues: ids.map { ($0, sec) }),
            collection: .personalLibrary
        )

        do {
            try await repo.setFavoritesBatch(action: action)
            XCTFail("Expected partial failure")
        } catch is BatchFavoriteError {}

        let page = try await cachedPage(sec, repository: repo)
        // The completed chunk's entry keeps the target value; only the failed entry reverts.
        XCTAssertEqual(page.first(where: { $0.id == 1 })?.isFavorite, true)
        XCTAssertEqual(page.first(where: { $0.id == 150 })?.isFavorite, false)
    }

    func testFullFailureRollsBackAllAffectedStatuses() async throws {
        let root = temporaryTestRoot("FullFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        await transport.setFailAllWrites(true)
        let repo = try makeRepository(transport: transport, root: root)

        let sec = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 2)])
        let action = SelectionFavoriteAction(
            affectedIDs: [10, 20],
            targetFavorite: true,
            sectionsByID: [10: sec, 20: sec],
            collection: .personalLibrary
        )

        var changes = await repo.favoriteChanges().makeAsyncIterator()
        do {
            try await repo.setFavoritesBatch(action: action)
            XCTFail("Expected failure")
        } catch {}

        // Expect optimistic change, then rollback change
        let optChange = await changes.next()
        XCTAssertEqual(optChange?.values[10], true)
        XCTAssertEqual(optChange?.values[20], true)

        let rollbackChange = await changes.next()
        XCTAssertEqual(rollbackChange?.values[10], false)
        XCTAssertEqual(rollbackChange?.values[20], false)

        let refreshed = await waitUntil {
            await transport.timelineCallCount(for: .favorites) == 1
        }
        XCTAssertTrue(refreshed)
    }

    func testPartialChunkFailurePreservesCompletedChunksAndRollsBackRemainder() async throws {
        let root = temporaryTestRoot("PartialChunkFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SelectionFavoritesMockTransport()
        // 250 items = 3 chunks (100, 100, 50). Fail chunk 1 (0-indexed).
        await transport.setFailOnChunkIndex(1)
        let sec = TimelineSection(offset: 0, limit: 250, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 250)])
        let snapshot = TimelineSnapshot(sections: [sec])
        await transport.setTimeline(snapshot, for: .favorites)
        let repo = try makeRepository(transport: transport, root: root)

        let ids = (1...250).map { Int64($0) }
        let action = SelectionFavoriteAction(
            affectedIDs: ids,
            targetFavorite: true,
            sectionsByID: Dictionary(uniqueKeysWithValues: ids.map { ($0, sec) }),
            collection: .personalLibrary
        )

        var changes = await repo.favoriteChanges().makeAsyncIterator()
        do {
            try await repo.setFavoritesBatch(action: action)
            XCTFail("Expected partial failure")
        } catch let error as BatchFavoriteError {
            XCTAssertEqual(error.outcome.successfulCount, 100)
            XCTAssertEqual(error.outcome.failedCount, 150)
        }

        let optChange = await changes.next()
        XCTAssertEqual(optChange?.values.count, 250)

        // Rollback change contains ONLY the 150 failed/unsubmitted items
        let rollbackChange = await changes.next()
        XCTAssertEqual(rollbackChange?.values.count, 150)
        XCTAssertEqual(rollbackChange?.values[101], false)
        XCTAssertEqual(rollbackChange?.values[250], false)
        XCTAssertNil(rollbackChange?.values[1]) // chunk 0 is preserved!
    }
}

// MARK: - Test Transport Mock

actor SelectionFavoritesMockTransport: PhotosTransport {
    private var pages: [Int: [PhotoItem]] = [:]
    private var timelineSnapshots: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    private(set) var setFavoriteCalls: [(itemIDs: [Int64], favorite: Bool)] = []
    private var thumbnailCount = 0
    private var fullImageCount = 0
    private(set) var itemCallCount = 0
    private var timelineCallCounts: [PhotoCollectionDescriptor: Int] = [:]
    private var favoriteBlocked = false
    private var favoriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var failAllWrites = false
    private var failOnChunkIndex: Int?
    private var itemsBlocked = false
    private var itemStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var itemWaiters: [CheckedContinuation<Void, Never>] = []

    func setPage(_ items: [PhotoItem], offset: Int) { pages[offset] = items }
    func setTimeline(_ snapshot: TimelineSnapshot, for collection: PhotoCollectionDescriptor) {
        timelineSnapshots[collection] = snapshot
    }
    func setFavoriteBlocked(_ blocked: Bool) { favoriteBlocked = blocked }
    func setFailAllWrites(_ fail: Bool) { failAllWrites = fail }
    func setFailOnChunkIndex(_ index: Int?) { failOnChunkIndex = index }
    func setItemsBlocked(_ blocked: Bool) { itemsBlocked = blocked }
    func waitUntilItemRequested() async {
        if itemCallCount > 0 { return }
        await withCheckedContinuation { itemStartWaiters.append($0) }
    }
    func releaseItems() {
        itemsBlocked = false
        let waiters = itemWaiters
        itemWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func recordedCounts() -> (thumbnails: Int, fullImages: Int) {
        (thumbnailCount, fullImageCount)
    }

    func timelineCallCount(for collection: PhotoCollectionDescriptor) -> Int {
        timelineCallCounts[collection, default: 0]
    }

    func releaseFavorite() {
        favoriteBlocked = false
        for waiter in favoriteWaiters { waiter.resume() }
        favoriteWaiters.removeAll()
    }

    func login(credentials: SynologyCredentials) async throws {}

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        timelineCallCounts[collection, default: 0] += 1
        if let snapshot = timelineSnapshots[collection] { return try fixtureDayCatalog(snapshot, initial: initial) }
        return try CollectionDayCatalog(days: (1...3).map { try CollectionDayCount(day: CaptureDay(year: 2024, month: 4, day: $0), count: pages[0]?.count ?? 0) }, completeness: initial ? .partial : .complete)
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        itemCallCount += 1
        for waiter in itemStartWaiters { waiter.resume() }
        itemStartWaiters.removeAll()
        if itemsBlocked {
            await withCheckedContinuation { itemWaiters.append($0) }
        }
        if let snapshot = timelineSnapshots[request.collection] {
            let days = try fixtureDayCatalog(snapshot, initial: false).days
            let keys = pages.keys.sorted()
            var rows: [PhotoItem] = []
            for (index, day) in days.enumerated() where day.day <= request.newestDay && day.day >= request.oldestDay {
                guard index < keys.count else { continue }
                rows += try (pages[keys[index]] ?? []).map { try fixtureItem($0, on: day.day) }
            }
            return CollectionBatchResult(items: rows, profile: fields)
        }
        return try fixtureBatch(pages[section.offset] ?? [], request: request, fields: fields)
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        let chunkIndex = setFavoriteCalls.count
        setFavoriteCalls.append((itemIDs, favorite))
        if favoriteBlocked {
            await withCheckedContinuation { favoriteWaiters.append($0) }
        }
        if failAllWrites || failOnChunkIndex == chunkIndex {
            throw TestFailure("Mock transport setFavorite failed")
        }
        for key in pages.keys { pages[key] = pages[key]?.map { itemIDs.contains($0.id) ? $0.withFavorite(favorite) : $0 } }
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        thumbnailCount += 1
        return ThumbnailResponse(data: Data([1, 2, 3]), etag: "etag", lastModified: "now")
    }

    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> FullImageResponse {
        fullImageCount += 1
        return FullImageResponse(data: Data([4, 5, 6]), etag: "etag", lastModified: "now")
    }
}
