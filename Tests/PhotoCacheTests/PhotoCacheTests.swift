import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class PhotoCacheTests: XCTestCase {
    func testDefaultCacheRootUsesProjectDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynoCacheLocationTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("project", isDirectory: true)
        let bundle = project.appendingPathComponent(".build/Cirrus Timeline.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("Package.swift"))

        let root = CacheLocation.defaultRoot(
            currentDirectory: temporary.appendingPathComponent("unrelated", isDirectory: true),
            bundleURL: bundle
        )
        XCTAssertEqual(root.lastPathComponent, ".cache")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, project.standardizedFileURL)
    }

    func testLegacyCacheMigrationMovesNamespaceDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynoCacheMigrationTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let legacy = temporary.appendingPathComponent("legacy/namespace", isDirectory: true)
        let destination = temporary.appendingPathComponent("project/.cache/namespace", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: legacy.appendingPathComponent("index.sqlite"))

        CacheLocation.migrateDirectory(from: legacy, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("index.sqlite").path
        ))
    }

    func testKeysAreSemanticAndIsolated() throws {
        let server = URL(string: "https://example.invalid:5001")!
        let alice = CacheKey.namespace(server: server, account: "alice")
        let bob = CacheKey.namespace(server: server, account: "bob")
        XCTAssertNotEqual(alice, bob)
        let section = TimelineSection(offset: 113, limit: 111,
            list: [TimelineDay(year: 2024, month: 3, day: 1, itemCount: 224)])
        let changed = TimelineSection(offset: 114, limit: 111, list: section.list)
        XCTAssertNotEqual(CacheKey.page(namespace: alice, section: section),
                          CacheKey.page(namespace: alice, section: changed))
        XCTAssertNotEqual(CacheKey.timeline(namespace: alice), CacheKey.timeline(namespace: bob))
        let original = FullImageResource(unitID: 42, cacheKey: "revision-1", filename: "one.jpg")
        let renamed = FullImageResource(unitID: 42, cacheKey: "revision-1", filename: "renamed.jpg")
        let revised = FullImageResource(unitID: 42, cacheKey: "revision-2", filename: "one.jpg")
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

    func testPriorityEvictsOldThumbnailsBeforePinnedTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoCacheTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12, protectedTimelineKey: "timeline")
        try await cache.put("timeline", kind: .timeline, data: Data(repeating: 1, count: 5), validatedRun: "run")
        try await cache.put("old", kind: .thumbnail, data: Data(repeating: 2, count: 7), validatedRun: nil)
        try await cache.put("new", kind: .thumbnail, data: Data(repeating: 3, count: 7), validatedRun: nil)
        let old = try await cache.get("old")
        let new = try await cache.get("new")
        let timeline = try await cache.get("timeline")
        let usage = try await cache.usage()
        XCTAssertNil(old)
        XCTAssertNotNil(new)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(usage, 12)
    }

    func testFullImagesEvictBeforeThumbnails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynoFullImageEvictionTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12, protectedTimelineKey: "timeline")
        try await cache.put("timeline", kind: .timeline, data: Data(repeating: 1, count: 4), validatedRun: "run")
        try await cache.put("thumbnail", kind: .thumbnail, data: Data(repeating: 2, count: 4), validatedRun: "run")
        try await cache.put("original", kind: .fullImage, data: Data(repeating: 3, count: 4), validatedRun: "run")
        try await cache.put("page", kind: .page, data: Data(repeating: 4, count: 4), validatedRun: "run")
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynoOversizedFullImageTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 12, protectedTimelineKey: "timeline")
        try await cache.put("timeline", kind: .timeline, data: Data(repeating: 1, count: 4), validatedRun: "run")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoCacheCorruptTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 100, protectedTimelineKey: "timeline")
        try await cache.put("thumb", kind: .thumbnail, data: Data([1, 2, 3]), validatedRun: "old")
        try Data([4, 5, 6]).write(to: root.appendingPathComponent("images/thumb.img"))
        let entry = try await cache.get("thumb")
        let usage = try await cache.usage()
        XCTAssertNil(entry)
        XCTAssertEqual(usage, 0)
    }

    func testClearRejectsLateWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoCacheClearTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try DiskCache(root: root, budget: 100, protectedTimelineKey: "timeline")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SynoLiveCacheTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try CredentialStore.load()
        let first = try CachedPhotosRepository(credentials: credentials, cacheRoot: root)
        var full: TimelineSnapshot?
        var timelineValues = 0
        for await event in await first.timeline() {
            if case .value = event { timelineValues += 1 }
            if case .value(let snapshot, let verified) = event, verified { full = snapshot }
            if case .failure(let message) = event { XCTFail("Timeline: \(message) after \(timelineValues) values") }
        }
        let timeline = try XCTUnwrap(full)
        XCTAssertGreaterThan(timeline.sections.count, 207)
        var page: [PhotoItem] = []
        for await event in await first.page(timeline.sections[207]) {
            if case .value(let items, let verified) = event, verified { page = items }
            if case .failure(let message) = event { XCTFail(message) }
        }
        XCTAssertEqual(page.count, timeline.sections[207].limit)
        let imageInfo = try XCTUnwrap(page.compactMap { $0.additional?.thumbnail }.first(where: { $0.isReady(.sm) }))
        var imageBytes = 0
        for await event in await first.thumbnail(imageInfo, size: .sm, allowNetwork: true) {
            if case .value(let data, let verified) = event, verified { imageBytes = data.count }
            if case .failure(let message) = event { XCTFail(message) }
        }
        XCTAssertGreaterThan(imageBytes, 0)
        let second = try CachedPhotosRepository(credentials: credentials, cacheRoot: root)
        var firstWasCached = false
        var laterWasValidated = false
        for await event in await second.timeline() {
            if case .value(_, let verified) = event, !firstWasCached { firstWasCached = !verified }
            if case .value(_, let verified) = event, verified { laterWasValidated = true }
            if case .failure(let message) = event { XCTFail(message) }
        }
        XCTAssertTrue(firstWasCached)
        XCTAssertTrue(laterWasValidated)
    }
}
