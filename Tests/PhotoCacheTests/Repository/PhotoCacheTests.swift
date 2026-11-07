import Foundation
import XCTest
import SynologyAPI
import SQLite3
@testable import PhotoCache

final class PhotoCacheTests: XCTestCase {
    func testDevelopmentCacheRootUsesProjectDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("CirrusCacheLocationTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("project", isDirectory: true)
        let bundle = project.appendingPathComponent(".build/Cirrus Photos.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("Package.swift"))
        let unrelated = temporary.appendingPathComponent("unrelated", isDirectory: true)

        let root = CacheLocation.developmentRoot(fileManager: .default, currentDirectory: unrelated, bundleURL: bundle)
        XCTAssertEqual(root.lastPathComponent, ".cache")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, project.standardizedFileURL)

        // The default root follows the build mode: the checkout for development builds,
        // Application Support for distribution builds.
        let defaultRoot = CacheLocation.defaultRoot(currentDirectory: unrelated, bundleURL: bundle)
        #if CIRRUS_DISTRIBUTION
        XCTAssertEqual(defaultRoot, CacheLocation.applicationSupportRoot(fileManager: .default))
        #else
        XCTAssertEqual(defaultRoot, root)
        #endif
    }

    func testDistributionCacheRootUsesApplicationSupport() throws {
        let root = CacheLocation.applicationSupportRoot(fileManager: .default)
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertEqual(root.lastPathComponent, "io.github.finia2na.cirrusphotos")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, applicationSupport.standardizedFileURL)
    }

    func testIncompatibleCacheSchemaDiscardsIndexedAndImageData() async throws {
        let root = temporaryTestRoot("SynoOldCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([1]).write(to: images.appendingPathComponent("old.img"))
        try Data([9]).write(to: root.appendingPathComponent("keep.txt"))
        let index = root.appendingPathComponent("index.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(index.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE entries (key TEXT PRIMARY KEY, kind INTEGER)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let cache = try DiskCache(root: root, budget: 100)
        let old = try await cache.get("old")
        XCTAssertNil(old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent("old.img").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("keep.txt")), Data([9]))
        try await cache.put("new", kind: .thumbnail, data: Data([2]), validatedRun: nil)
        let new = try await cache.get("new")
        XCTAssertEqual(new?.data, Data([2]))
    }

    func testCurrentSchemaReopensWithoutDiscardingCache() async throws {
        let root = temporaryTestRoot("SynoCurrentCache")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let cache = try DiskCache(root: root, budget: 100)
            try await cache.put("image", kind: .thumbnail, data: Data([4, 5]), validatedRun: "run")
        }
        let reopened = try DiskCache(root: root, budget: 100)
        let image = try await reopened.get("image")
        XCTAssertEqual(image?.data, Data([4, 5]))
    }

    func testUnreadableIndexRecreatesCache() async throws {
        let root = temporaryTestRoot("SynoCorruptCache")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: root.appendingPathComponent("index.sqlite"))
        let cache = try DiskCache(root: root, budget: 100)
        try await cache.put("new", kind: .thumbnail, data: Data([6]), validatedRun: nil)
        let new = try await cache.get("new")
        XCTAssertEqual(new?.data, Data([6]))
    }

    func testFutureCacheSchemaIsNotInterpretedAsCurrent() async throws {
        let root = temporaryTestRoot("SynoFutureCache")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let cache = try DiskCache(root: root, budget: 100)
            try await cache.put("old", kind: .thumbnail, data: Data([1]), validatedRun: nil)
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let cache = try DiskCache(root: root, budget: 100)
        let old = try await cache.get("old")
        XCTAssertNil(old)
    }

    func testKeysAreSemanticAndIsolated() throws {
        let server = URL(string: "https://example.invalid:5001")!
        let alice = CacheKey.namespace(server: server, account: "alice")
        let bob = CacheKey.namespace(server: server, account: "bob")
        XCTAssertNotEqual(alice, bob)
        let section = TimelineSection(offset: 0, limit: 250,
            list: [TimelineDay(year: 2024, month: 3, day: 1, itemCount: 501)])
        let changed = TimelineSection(offset: 250, limit: 250, list: section.list)
        XCTAssertNotEqual(CacheKey.page(scope: .space(.personal), namespace: alice, section: section, collection: .library(.personal)),
                          CacheKey.page(scope: .space(.personal), namespace: alice, section: changed, collection: .library(.personal)))
        XCTAssertNotEqual(CacheKey.page(scope: .space(.personal), namespace: alice, section: section, collection: .library(.personal)), CacheKey.page(scope: .space(.personal), namespace: bob, section: section, collection: .library(.personal)))
        let original = FullImageResource(scope: .space(.personal), unitID: 42, cacheKey: "revision-1", filename: "one.jpg")
        let renamed = FullImageResource(scope: .space(.personal), unitID: 42, cacheKey: "revision-1", filename: "renamed.jpg")
        let revised = FullImageResource(scope: .space(.personal), unitID: 42, cacheKey: "revision-2", filename: "one.jpg")
        XCTAssertEqual(CacheKey.fullImage(namespace: alice, resource: original),
                       CacheKey.fullImage(namespace: alice, resource: renamed))
        XCTAssertNotEqual(CacheKey.fullImage(namespace: alice, resource: original),
                          CacheKey.fullImage(namespace: alice, resource: revised))
        XCTAssertNotEqual(CacheKey.fullImage(namespace: alice, resource: original),
                          CacheKey.fullImage(namespace: bob, resource: original))
    }

    func testTimelineDescriptorRoundTrip() throws {
        let original = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 110, list: [TimelineDay(year: 2024, month: 3, day: 1, itemCount: 220)]),
            TimelineSection(offset: 110, limit: 110, list: [TimelineDay(year: 2024, month: 3, day: 1, itemCount: 220)])
        ])
        let restored = try JSONDecoder().decode(TimelineSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.sections, original.sections)
        XCTAssertEqual(restored.timeline.days.count, 1)
        XCTAssertEqual(restored.timeline.days[0].section, 0)
    }

    func testLogarithmicBudgetEndpointsAndMidpoint() {
        XCTAssertEqual(CacheBudget.bytes(at: 0), 200_000_000)
        XCTAssertEqual(CacheBudget.bytes(at: 1), 100_000_000_000)
        XCTAssertEqual(CacheBudget.fraction(for: CacheBudget.bytes(at: 0.5)), 0.5, accuracy: 0.00001)
    }

    /// Budgets with a reserve rely on the in-memory usage estimate between full scans;
    /// media writes must still trigger eviction once the estimate exceeds the limit.
    func testReserveBudgetEvictsWhenEstimatedUsageExceedsLimit() async throws {
        let root = temporaryTestRoot("SynoEstimatedUsageTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 200_000_000)
        let block = 95_000_000
        try await cache.put("first", kind: .thumbnail, data: Data(repeating: 1, count: block), validatedRun: nil)
        try await cache.put("second", kind: .thumbnail, data: Data(repeating: 2, count: block), validatedRun: nil)
        let first = try await cache.get("first")
        let second = try await cache.get("second")
        let usage = try await cache.usage()
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(usage, Int64(block))
    }

    /// The running estimate between full scans must equal a fresh scan after new writes,
    /// replacements, removals and evictions.
    func testMediaUsageEstimateTracksFreshScan() async throws {
        let root = temporaryTestRoot("SynoUsageEstimateTracking")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 200_000_000)
        func assertEstimateMatches(_ step: String) async throws {
            let estimate = await cache.estimatedUsage
            let fresh = try await cache.usage()
            XCTAssertEqual(estimate, fresh, step)
        }
        try await cache.put("a", kind: .thumbnail, data: Data(repeating: 1, count: 1_000), validatedRun: nil)
        try await cache.put("b", kind: .fullImage, data: Data(repeating: 2, count: 20_000), validatedRun: nil)
        try await cache.put("c", kind: .videoSegment, data: Data(repeating: 3, count: 300), validatedRun: nil)
        try await assertEstimateMatches("after writes")
        try await cache.put("b", kind: .fullImage, data: Data(repeating: 4, count: 5_000), validatedRun: nil)
        try await assertEstimateMatches("after replacement")
        try await cache.remove("a")
        try await assertEstimateMatches("after removal")
        try await cache.setBudget(4_000)
        try await assertEstimateMatches("after budget reduction")
        let usage = try await cache.usage()
        XCTAssertLessThanOrEqual(usage, 4_000)
    }

    func testThumbnailEvictionUsesReadRecency() async throws {
        let root = temporaryTestRoot("ThumbnailLRU")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 8)
        try await cache.put("one", kind: .thumbnail, data: Data(repeating: 1, count: 4), validatedRun: nil)
        try await cache.put("two", kind: .thumbnail, data: Data(repeating: 2, count: 4), validatedRun: nil)
        _ = try await cache.get("one")
        try await cache.put("three", kind: .thumbnail, data: Data(repeating: 3, count: 4), validatedRun: nil)
        let evicted = try await cache.get("two")
        let retained = try await cache.get("one")
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)
    }

    func testFullImagesEvictBeforeThumbnails() async throws {
        let root = temporaryTestRoot("SynoFullImageEvictionTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12)
        try await cache.put("timeline", kind: .thumbnail, data: Data(repeating: 1, count: 4), validatedRun: "run")
        try await cache.put("thumbnail", kind: .thumbnail, data: Data(repeating: 2, count: 4), validatedRun: "run")
        try await cache.put("original", kind: .fullImage, data: Data(repeating: 3, count: 4), validatedRun: "run")
        try await cache.put("page", kind: .thumbnail, data: Data(repeating: 4, count: 4), validatedRun: "run")
        let original = try await cache.get("original")
        let thumbnail = try await cache.get("thumbnail")
        let page = try await cache.get("page")
        let timeline = try await cache.get("timeline")
        XCTAssertNil(original)
        XCTAssertNotNil(thumbnail)
        XCTAssertNotNil(page)
        XCTAssertNotNil(timeline)
    }

    func testOversizedFullImageSelfEvictsWithoutPurgingThumbnails() async throws {
        let root = temporaryTestRoot("SynoOversizedFullImageTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12)
        try await cache.put("timeline", kind: .thumbnail, data: Data(repeating: 1, count: 4), validatedRun: "run")
        try await cache.put("thumbnail", kind: .thumbnail, data: Data(repeating: 2, count: 4), validatedRun: "run")
        try await cache.put("oversized", kind: .fullImage, data: Data(repeating: 3, count: 20), validatedRun: "run")
        let oversized = try await cache.get("oversized")
        let thumbnail = try await cache.get("thumbnail")
        let timeline = try await cache.get("timeline")
        XCTAssertNil(oversized)
        XCTAssertNotNil(thumbnail)
        XCTAssertNotNil(timeline)
    }

    func testCorruptImageIsDiscarded() async throws {
        let root = temporaryTestRoot("SynoCacheCorruptTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 100)
        try await cache.put("thumb", kind: .thumbnail, data: Data([1, 2, 3]), validatedRun: "old")
        try Data([4, 5, 6]).write(to: root.appendingPathComponent("images/thumb.img"))
        let entry = try await cache.get("thumb")
        let usage = try await cache.usage()
        XCTAssertNil(entry)
        XCTAssertEqual(usage, 0)
    }

    func testClearRejectsLateWrite() async throws {
        let root = temporaryTestRoot("SynoCacheClearTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 100)
        let generation = await cache.currentGeneration()
        try await cache.clear()
        try await cache.put("late", kind: .thumbnail, data: Data([1]), validatedRun: "run",
                            expectedGeneration: generation)
        let usage = try await cache.usage()
        XCTAssertEqual(usage, 0)
    }

    func testLiveSectionAndWarmCacheWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SYNOLOGY_TEST=1 to test Cirrus.")
        }
        let root = temporaryTestRoot("SynoLiveCacheTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try CredentialStore.load()
        let first = try CachedPhotosRepository(credentials: credentials, cacheRoot: root)
        var full: TimelineSnapshot?
        var timelineValues = 0
        for await event in await first.timeline(collection: .library(.personal)) {
            if case .value = event { timelineValues += 1 }
            if case .value(let snapshot, let verified) = event, verified { full = snapshot }
            if case .failure(let message) = event { XCTFail("Timeline: \(message) after \(timelineValues) values") }
        }
        let timeline = try XCTUnwrap(full)
        XCTAssertGreaterThan(timeline.sections.count, 207)
        var page: [PhotoItem] = []
        for await event in await first.page(timeline.sections[207], collection: .library(.personal)) {
            if case .value(let items, let verified) = event, verified { let items = items.completeItems ?? []; page = items }
            if case .failure(let error) = event { XCTFail(error.localizedDescription) }
        }
        XCTAssertEqual(page.count, timeline.sections[207].limit)
        let imageInfo = try XCTUnwrap(page.compactMap { $0.additional?.thumbnail }.first(where: { $0.isReady(.sm) }))
        var imageBytes = 0
        for await event in await first.thumbnail(imageInfo, size: .sm, allowNetwork: true, collection: .library(.personal)) {
            if case .value(let data, let verified) = event, verified { imageBytes = data.count }
            if case .failure(let error) = event { XCTFail(error.localizedDescription) }
        }
        XCTAssertGreaterThan(imageBytes, 0)
        let second = try CachedPhotosRepository(credentials: credentials, cacheRoot: root)
        var firstWasCached = false
        var laterWasValidated = false
        for await event in await second.timeline(collection: .library(.personal)) {
            if case .value(_, let verified) = event, !firstWasCached { firstWasCached = !verified }
            if case .value(_, let verified) = event, verified { laterWasValidated = true }
            if case .failure(let error) = event { XCTFail(error.localizedDescription) }
        }
        XCTAssertTrue(firstWasCached)
        XCTAssertTrue(laterWasValidated)
    }
}
