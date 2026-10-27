import Foundation
import SQLite3
import XCTest
import SynologyAPI
@testable import PhotoCache

final class MetadataCacheResetTests: XCTestCase, @unchecked Sendable {
    private let namespace = MetadataNamespace(account: "reset-account")
    private func open(_ root: URL) async throws -> DiskCache {
        let store = try DiskCache(root: root, budget: 10_000_000)
        try await store.initializeMetadataStore()
        return store
    }
    private func catalog() throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: [.init(day: CaptureDay(year: 2024, month: 1, day: 1), count: 1)], completeness: .complete)
    }
    func testMetadataClearRemovesNormalizedCoverageAndPreservesEveryMediaKindAndHTTPMarkers() async throws {
        let root = temporaryTestRoot("normalized-reset"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await open(root)
        let admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(catalog(), key: .init(namespace: namespace, collection: .personalLibrary), validatedRun: "run", admission: admission)
        try await store.storeMetadataAlbumSummaries([.init(id: 1, name: "fixture", itemCount: 1)], namespace: namespace, currentRun: "run", admission: admission)
        try await store.applyMetadataChanges(namespace: namespace, cursor: .init(diffVersion: 1, versionTime: 1), replacements: [], deletedIDs: [], affectedDays: [], invalidateAll: true, currentRun: "run", admission: admission)
        for kind in [CacheKind.thumbnail, .previewThumbnail, .fullImage, .videoSegment] {
            try await store.put("media-\(kind.rawValue)", kind: kind, data: Data([1, 2, 3]), validatedRun: "media-run", etag: "fixture-etag", lastModified: "fixture-modified")
        }
        let wholeGeneration = await store.currentGeneration()
        _ = try await store.clearMetadata()
        let catalog = try await store.metadataCatalog(.init(namespace: namespace, collection: .personalLibrary))
        let albums = try await store.metadataAlbumSummaries(namespace)
        let state = try await store.metadataState(namespace)
        XCTAssertNil(catalog); XCTAssertNil(albums); XCTAssertNil(state.cursor); XCTAssertFalse(state.inventoryComplete)
        let currentWhole = await store.currentGeneration()
        XCTAssertEqual(currentWhole, wholeGeneration)
        for kind in [CacheKind.thumbnail, .previewThumbnail, .fullImage, .videoSegment] {
            let entry = try await store.get("media-\(kind.rawValue)")
            XCTAssertEqual(entry?.data, Data([1, 2, 3])); XCTAssertEqual(entry?.etag, "fixture-etag")
            XCTAssertEqual(entry?.lastModified, "fixture-modified"); XCTAssertEqual(entry?.validatedRun, "media-run")
        }
    }
    func testOldAdmissionCannotWriteNormalizedRowsAfterMetadataOrFullClear() async throws {
        for full in [false, true] {
            let root = temporaryTestRoot("normalized-late-write"); defer { try? FileManager.default.removeItem(at: root) }
            let store = try await open(root)
            let old = try await store.metadataAdmission(namespace)
            if full { try await store.clear() } else { _ = try await store.clearMetadata() }
            do {
                try await store.storeMetadataCatalog(catalog(), key: .init(namespace: namespace, collection: .personalLibrary), validatedRun: "late", admission: old)
                XCTFail("Pre-reset metadata writer was admitted")
            } catch { }
            let value = try await store.metadataCatalog(.init(namespace: namespace, collection: .personalLibrary))
            XCTAssertNil(value)
        }
    }
    func testIncompatibleNormalizedFormatDiscardsMetadataAndPreservesUnchangedMediaFormat() async throws {
        let root = temporaryTestRoot("normalized-format"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await open(root)
        try await store.storeMetadataCatalog(catalog(), key: .init(namespace: namespace, collection: .personalLibrary), validatedRun: "old", admission: store.metadataAdmission(namespace))
        try await store.put("photo", kind: .thumbnail, data: Data([7, 8]), validatedRun: "media", etag: "validator")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE metadata_format SET version=999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        let reopened = try await open(root)
        let value = try await reopened.metadataCatalog(.init(namespace: namespace, collection: .personalLibrary))
        let image = try await reopened.get("photo")
        XCTAssertNil(value); XCTAssertEqual(image?.data, Data([7, 8])); XCTAssertEqual(image?.etag, "validator")
    }
    func testDayGenerationRejectsABAReplacementEvenWhenCatalogCountsReturnToOldValues() async throws {
        let root = temporaryTestRoot("normalized-aba"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await open(root)
        let key = CollectionKey(namespace: namespace, collection: .personalLibrary)
        let old = try catalog()
        let admission = try await store.metadataAdmission(namespace)
        try await store.storeMetadataCatalog(old, key: key, validatedRun: "run", admission: admission)
        let address = try DayPageAddress(collection: .personalLibrary, day: old.days[0].day, offset: 0)
        let read = try DayPageRead(address: address, dayCount: 1, membershipGeneration: 1)
        try await store.storeMetadataCatalog(.init(days: [.init(day: address.day, count: 2)], completeness: .complete), key: key, validatedRun: "run", admission: admission)
        try await store.storeMetadataCatalog(old, key: key, validatedRun: "run", admission: admission)
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":1,"time":1704067200,"type":"photo"}"#.utf8))
        do {
            try await store.storeMetadataPage(read, items: [item], profile: .fullPage, namespace: namespace, currentRun: "run", admission: admission)
            XCTFail("A stale day membership writer passed an ABA count change")
        } catch { }
        let page = try await store.metadataPage(address, namespace: namespace, currentRun: "run")
        XCTAssertNil(page)
    }
}
