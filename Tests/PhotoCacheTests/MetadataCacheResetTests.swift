import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor MetadataResetTransport: PhotosTransport {}

final class MetadataCacheResetTests: XCTestCase {
    private let server = URL(string: "https://example.invalid")!
    private let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")

    private func root() -> URL { temporaryTestRoot("SynoMetadataResetTest") }

    private func repository(root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(
            credentials: credentials,
            baseURL: server,
            budget: 50_000_000,
            cacheRoot: root,
            transport: MetadataResetTransport()
        )
    }

    func testMetadataClearRemovesEveryMetadataKindAndPreservesImageBytesAndMarkers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root: root)
        let metadataKeys: [(String, CacheKind)] = [
            ("timeline", .timeline), ("page", .page), ("albums", .albumList),
            ("locations", .locationIndex),
        ]
        for (key, kind) in metadataKeys {
            try await repository.store.put(key, kind: kind, data: Data(key.utf8), validatedRun: "metadata-run")
        }
        let images: [(String, CacheKind, Data)] = [
            ("thumbnail", .thumbnail, Data([1, 2, 3])),
            ("preview", .previewThumbnail, Data([4, 5, 6])),
            ("original", .fullImage, Data([7, 8, 9])),
        ]
        for (key, kind, data) in images {
            try await repository.store.put(key, kind: kind, data: data, validatedRun: "image-run",
                                           etag: "etag-\(key)")
        }
        let wholeBefore = await repository.store.currentGeneration()
        let metadataBefore = await repository.store.currentMetadataGeneration()

        var resets = await repository.metadataCacheResets().makeAsyncIterator()
        let initialRevision = await resets.next()
        XCTAssertEqual(initialRevision, 0)
        try await repository.clearMetadataCache()
        let nextRevision = await resets.next()
        let revision = try XCTUnwrap(nextRevision)
        XCTAssertGreaterThan(revision, 0)

        let wholeAfter = await repository.store.currentGeneration()
        let metadataAfter = await repository.store.currentMetadataGeneration()
        XCTAssertEqual(wholeAfter, wholeBefore)
        XCTAssertGreaterThan(metadataAfter, metadataBefore)
        for (key, _) in metadataKeys {
            let entry = try await repository.store.get(key)
            XCTAssertNil(entry, "Metadata row \(key) survived metadata-only clear")
        }
        for (key, _, data) in images {
            let loaded = try await repository.store.get(key)
            let entry = try XCTUnwrap(loaded)
            XCTAssertEqual(entry.data, data)
            XCTAssertEqual(entry.validatedRun, "image-run")
            XCTAssertEqual(entry.etag, "etag-\(key)")
        }
    }

    func testOldMetadataGenerationCannotWriteAfterClear() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root: root)
        let whole = await repository.store.currentGeneration()
        let metadata = await repository.store.currentMetadataGeneration()

        try await repository.clearMetadataCache()
        let result = try await repository.store.putMetadata(
            "late",
            kind: .page,
            data: Data([1]),
            validatedRun: nil,
            expectedGeneration: whole,
            expectedMetadataGeneration: metadata,
            replacing: .absent
        )
        XCTAssertEqual(result, .generationChanged)
        let late = try await repository.store.get("late")
        XCTAssertNil(late)
    }

    func testConditionalCommitRejectsStaleSameRowWriter() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root: root)
        try await repository.store.put("page", kind: .page, data: Data([1]), validatedRun: "one")
        let firstLoaded = try await repository.store.get("page")
        let first = try XCTUnwrap(firstLoaded)
        let whole = await repository.store.currentGeneration()
        let metadata = await repository.store.currentMetadataGeneration()

        let newer = try await repository.store.putMetadata(
            "page", kind: .page, data: Data([2]), validatedRun: "two",
            expectedGeneration: whole, expectedMetadataGeneration: metadata,
            replacing: .revision(first.revision)
        )
        guard case .stored = newer else { return XCTFail("Newer writer was not stored") }
        let stale = try await repository.store.putMetadata(
            "page", kind: .page, data: Data([3]), validatedRun: "stale",
            expectedGeneration: whole, expectedMetadataGeneration: metadata,
            replacing: .revision(first.revision)
        )
        XCTAssertEqual(stale, .superseded)
        let retainedLoaded = try await repository.store.get("page")
        let retained = try XCTUnwrap(retainedLoaded)
        XCTAssertEqual(retained.data, Data([2]))
        XCTAssertEqual(retained.validatedRun, "two")
    }

    func testConditionalCommitRejectsABAReplacementWithIdenticalBytes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root: root)
        try await repository.store.put("page", kind: .page, data: Data([1]), validatedRun: "first")
        let firstLoaded = try await repository.store.get("page")
        let first = try XCTUnwrap(firstLoaded)
        let whole = await repository.store.currentGeneration()
        let metadata = await repository.store.currentMetadataGeneration()

        let secondResult = try await repository.store.putMetadata(
            "page", kind: .page, data: Data([2]), validatedRun: "second",
            expectedGeneration: whole, expectedMetadataGeneration: metadata,
            replacing: .revision(first.revision)
        )
        guard case .stored(let secondRevision) = secondResult else {
            return XCTFail("Second row version was not stored")
        }
        let restored = try await repository.store.putMetadata(
            "page", kind: .page, data: Data([1]), validatedRun: "restored",
            expectedGeneration: whole, expectedMetadataGeneration: metadata,
            replacing: .revision(secondRevision)
        )
        guard case .stored = restored else { return XCTFail("Restored bytes were not stored") }

        let stale = try await repository.store.putMetadata(
            "page", kind: .page, data: Data([3]), validatedRun: "stale",
            expectedGeneration: whole, expectedMetadataGeneration: metadata,
            replacing: .revision(first.revision)
        )
        XCTAssertEqual(stale, .superseded,
                       "A content digest cannot serve as a same-row revision because it misses ABA writes")
        let retainedLoaded = try await repository.store.get("page")
        let retained = try XCTUnwrap(retainedLoaded)
        XCTAssertEqual(retained.data, Data([1]))
        XCTAssertEqual(retained.validatedRun, "restored")
    }

    func testMetadataResetInvalidatesRegisteredMapFilters() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root: root)
        let section = TimelineSection(
            offset: 0,
            limit: 1,
            list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1)]
        )
        let descriptor = PhotoCollectionDescriptor.mapFilter(UUID())
        try await repository.registerMapFilter(
            descriptor,
            source: .personalLibrary,
            snapshot: TimelineSnapshot(sections: [section]),
            itemIDsBySection: [[1]]
        )
        let registered = await repository.latestTimelineSnapshot(collection: descriptor)
        XCTAssertNotNil(registered)

        try await repository.clearMetadataCache()
        let cleared = await repository.latestTimelineSnapshot(collection: descriptor)
        XCTAssertNil(cleared)
        var failure: String?
        for await event in await repository.page(section, collection: descriptor, allowNetwork: false) {
            if case .failure(let message) = event { failure = message }
        }
        XCTAssertNotNil(failure)
    }
}
