import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor SharedTimelineTransport: PhotosTransport {
    var offline = false
    var diffCalls = 0
    var catalogs: [PhotoCollectionDescriptor] = []
    var pages: [PhotoCollectionDescriptor] = []
    var thumbnailSpaces: [PhotoSpace] = []
    func setOffline() { offline = true }
    func diffVersion() async throws -> DiffCursor {
        diffCalls += 1
        throw SynologyAPIError.api(103)
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        catalogs.append(collection)
        if offline { throw SynologyAPIError.transport("offline") }
        return try CollectionDayCatalog(sections: [section], completeness: .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        pages.append(request.collection)
        if offline { throw SynologyAPIError.transport("offline") }
        let name = request.collection == .library(.shared) ? "shared.jpg" : "personal.jpg"
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":1704067200,\"filename\":\"\(name)\",\"type\":\"photo\"}".utf8))
        return CollectionBatchResult(items: [item], profile: fields)
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        thumbnailSpaces.append(space)
        return ThumbnailResponse(data: Data(space.rawValue.utf8), etag: nil, lastModified: nil)
    }
    var section: TimelineSection {
        TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1)])
    }
}

final class SharedTimelineTests: XCTestCase, @unchecked Sendable {
    func testSharedTimelineAvoidsPersonalDiffAndRetainsCachedPagesOffline() async throws {
        let root = temporaryTestRoot("shared-timeline")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedTimelineTransport()
        let credentials = SynologyCredentials(username: "test", password: "unused")
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        var snapshot: TimelineSnapshot?
        for await event in await repository.timeline(collection: .library(.shared)) {
            if case .value(let value, let verified) = event, verified { snapshot = value }
        }
        let section = try XCTUnwrap(snapshot?.sections.first)
        var shared: PhotoPageSnapshot?
        for await event in await repository.page(section, collection: .library(.shared)) {
            if case .value(let page, let verified) = event, verified { shared = page }
        }
        XCTAssertEqual(shared?.slots.first?.item?.filename, "shared.jpg")
        let diffCalls = await transport.diffCalls
        XCTAssertEqual(diffCalls, 0)
        // Same item ID, day and account must not resolve to a Shared Space row.
        let personalNamespace = await repository.metadataNamespace(for: .library(.personal))
        let sharedNamespace = await repository.metadataNamespace(for: .library(.shared))
        XCTAssertNotEqual(personalNamespace, sharedNamespace)
        let details = try await repository.store.metadataDetails(personalNamespace, ids: [1], currentRun: repository.runID)
        XCTAssertTrue(details.isEmpty)
        // Cached filter discovery and derived reads retain the source namespace.
        let controller = LibraryFilterController(repository: repository, snapshot: try XCTUnwrap(snapshot), sourceCollection: .library(.shared))
        await controller.indexCachedPages()
        let registration = await controller.apply(LibraryFilter(extensions: ["jpg"]))
        XCTAssertEqual(registration.referencesBySection.flatMap { $0 }.map(\.itemID), [1])
        _ = try await repository.registerLibraryFilter(registration)
        let filterSection = try XCTUnwrap(registration.snapshot.sections.first)
        var filteredName: String?
        for await event in await repository.page(filterSection, collection: registration.descriptor, allowNetwork: false) {
            if case .value(let page, _) = event { filteredName = page.slots.first?.item?.filename }
        }
        XCTAssertEqual(filteredName, "shared.jpg")
        let derivedNamespace = await repository.metadataNamespace(for: registration.descriptor)
        XCTAssertEqual(derivedNamespace, sharedNamespace)
        let source = await repository.mediaCollection(for: registration.descriptor)
        XCTAssertEqual(source, .library(.shared))
        let filteredObservation = await repository.observeMetadataChanges(collection: registration.descriptor)
        let pageObservation = await repository.observeCollectionPages(collection: .library(.shared), sections: [section])
        await repository.publishMetadataInvalidation()
        await repository.publishDerivedPageChanges(ids: [1], space: .personal)
        let filterInvalidation = await repository.takeMetadataChanges(filteredObservation.id)
        let pageInvalidation = await repository.takeCollectionPageChanges(pageObservation.id)
        XCTAssertNil(filterInvalidation)
        XCTAssertTrue(pageInvalidation.isEmpty)
        await controller.shutdown()

        let observation = await repository.observeMetadataChanges(collection: .library(.shared))
        await repository.publishMetadataInvalidation()
        let invalidation = await repository.takeMetadataChanges(observation.id)
        XCTAssertNil(invalidation)

        await transport.setOffline()
        let reopened = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: transport)
        var cachedTimeline = false
        var failed = false
        for await event in await reopened.timeline(collection: .library(.shared)) {
            switch event {
            case .value(_, let verified): cachedTimeline = !verified
            case .failure: failed = true
            }
        }
        XCTAssertTrue(cachedTimeline)
        XCTAssertTrue(failed)
        var cachedName: String?
        for await event in await reopened.page(section, collection: .library(.shared), allowNetwork: false) {
            if case .value(let page, let verified) = event {
                cachedName = page.slots.first?.item?.filename
                XCTAssertFalse(verified)
            }
        }
        XCTAssertEqual(cachedName, "shared.jpg")
    }

    func testThumbnailIdentityAndRequestUseExplicitSpace() async throws {
        let root = temporaryTestRoot("shared-thumbnails")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedTimelineTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "unused"), cacheRoot: root, transport: transport)
        let thumbnail = ThumbnailInfo(unitID: 1, cacheKey: "same")
        var values: [Data] = []
        for collection in [PhotoCollectionDescriptor.library(.personal), .library(.shared)] {
            for await event in await repository.thumbnail(thumbnail, size: .sm, allowNetwork: true, collection: collection) {
                if case .value(let data, _) = event { values.append(data) }
            }
        }
        XCTAssertEqual(values, [Data(PhotoSpace.personal.rawValue.utf8), Data(PhotoSpace.shared.rawValue.utf8)])
        let spaces = await transport.thumbnailSpaces
        XCTAssertEqual(spaces, [.personal, .shared])
    }
}
