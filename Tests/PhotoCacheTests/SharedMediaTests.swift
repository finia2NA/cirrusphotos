import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor SharedMediaTransport: PhotosTransport {
    var favorites: [PhotoSpace: Bool] = [:]
    var orientations: [PhotoSpace: Int] = [:]
    var originalScopes: [PhotoContentScope] = []
    var writes: [PhotoSpace] = []
    func photo(_ space: PhotoSpace) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"filename":"fixture.jpg","time":1704067200,"type":"photo","additional":{"thumbnail":{"unit_id":91,"cache_key":"same-revision","sm":"ready","m":"ready","xl":"ready"},"orientation":\(orientations[space] ?? 1),"orientation_original":1,"favorite":\(favorites[space] ?? false)}}
        """.utf8))
    }
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(sections: [TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1)])], completeness: .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        CollectionBatchResult(items: [try photo(request.collection.space)], profile: fields)
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { [try photo(space)] }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        ThumbnailResponse(data: Data(space.rawValue.utf8), etag: nil, lastModified: nil)
    }
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> FullImageResponse {
        originalScopes.append(resource.scope)
        return FullImageResponse(data: Data(resource.scope.cacheComponent.utf8), etag: nil, lastModified: nil)
    }
    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws { writes.append(space); favorites[space] = favorite }
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection, space: PhotoSpace) async throws { writes.append(space); orientations[space] = 6 }
}

final class SharedMediaTests: XCTestCase, @unchecked Sendable {
    func testSharedViewerAndOriginalCacheRetainSpaceWithCollidingUnitIDs() async throws {
        let root = temporaryTestRoot("shared-media")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedMediaTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        var snapshot: TimelineSnapshot?
        for await event in await repository.timeline(collection: .sharedLibrary) {
            if case .value(let value, true) = event { snapshot = value }
        }
        let timeline = try XCTUnwrap(snapshot)
        let photo = try await transport.photo(.shared)
        let session = PhotoViewerSession(repository: repository, collection: .sharedLibrary,
            index: LibraryIndex(snapshot: timeline), seed: .init(sectionIndex: 0, pageOffset: 0, item: photo, page: [photo], pageVerified: true), allowNetwork: true)
        var received: PhotoViewerState?
        for await state in await session.states() {
            if state.fullImageData != nil { received = state; break }
        }
        XCTAssertEqual(received?.contentScope, .space(.shared))
        XCTAssertEqual(received?.fullImageData, Data("shared".utf8))
        await session.close()
        let personal = try XCTUnwrap(photo.fullImageResource(in: .space(.personal)))
        var personalData: Data?
        for await event in await repository.fullImage(personal) {
            if case .value(let data, _) = event { personalData = data }
        }
        XCTAssertEqual(personalData, Data("personal".utf8))
        let scopes = await transport.originalScopes
        XCTAssertTrue(scopes.contains(.space(.shared)))
        XCTAssertTrue(scopes.contains(.space(.personal)))
    }

    func testSharedMutationsPatchOnlySharedCanonicalMetadataAndEvents() async throws {
        let root = temporaryTestRoot("shared-mutations")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SharedMediaTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        let photo = try await transport.photo(.shared)
        let section = TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1)])
        try await seedMetadataPage([photo], section: section, repository: repository, collection: .personalLibrary)
        try await seedMetadataPage([photo], section: section, repository: repository, collection: .sharedLibrary)
        let timeline = try CollectionDayPager.snapshot(catalog: CollectionDayCatalog(sections: [section], completeness: .complete))
        let sharedViewer = PhotoViewerSession(repository: repository, collection: .sharedLibrary, index: LibraryIndex(snapshot: timeline),
            seed: .init(sectionIndex: 0, pageOffset: 0, item: photo, page: [photo], pageVerified: true), allowNetwork: false)
        let personalViewer = PhotoViewerSession(repository: repository, index: LibraryIndex(snapshot: timeline),
            seed: .init(sectionIndex: 0, pageOffset: 0, item: photo, page: [photo], pageVerified: true), allowNetwork: false)
        _ = await sharedViewer.state()
        _ = await personalViewer.state()
        // Allow stream registration before publishing the mutations.
        try await Task.sleep(for: .milliseconds(10))
        try await repository.setFavorite(itemID: photo.id, item: photo, in: section, collection: .sharedLibrary, to: true)
        try await repository.rotate(.init(itemIDs: [photo.id], sectionsByID: [photo.id: section], collection: .sharedLibrary, itemsByID: [photo.id: photo]), direction: .clockwise)
        for _ in 0..<100 {
            let state = await sharedViewer.state()
            if state.item?.additional?.orientation == 6 && state.item?.isFavorite == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sharedState = await sharedViewer.state()
        let personalState = await personalViewer.state()
        XCTAssertEqual(sharedState.item?.additional?.orientation, 6)
        XCTAssertEqual(sharedState.item?.isFavorite, true)
        XCTAssertEqual(personalState.item?.additional?.orientation, 1)
        XCTAssertEqual(personalState.item?.isFavorite, false)
        await sharedViewer.close()
        await personalViewer.close()
        let store = await repository.store
        let sharedNamespace = await repository.metadataNamespace(for: .sharedLibrary)
        let personalNamespace = await repository.metadataNamespace(for: .personalLibrary)
        let shared = try await store.metadataDetails(sharedNamespace, ids: [photo.id], currentRun: repository.runID)[photo.id]?.item
        let personal = try await store.metadataDetails(personalNamespace, ids: [photo.id], currentRun: repository.runID)[photo.id]?.item
        XCTAssertEqual(shared?.additional?.orientation, 6)
        XCTAssertEqual(personal?.additional?.orientation, 1)
        XCTAssertEqual(personal?.isFavorite, false)
        let writes = await transport.writes
        XCTAssertEqual(writes, [.shared, .shared])
        let stream = await repository.favoriteChanges(space: .shared)
        var iterator = stream.makeAsyncIterator()
        let change = await iterator.next()
        XCTAssertEqual(change?.values[1], true)
        XCTAssertEqual(change?.sourceCollection.space, .shared)
    }
}
