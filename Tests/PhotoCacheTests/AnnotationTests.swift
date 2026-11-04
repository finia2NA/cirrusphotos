import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private struct AnnotationFailure: Error {}

private actor AnnotationTransport: TestPhotosTransport {
    var ratings: [PhotoSpace: Int] = [:]
    var tags: [PhotoSpace: [PhotoTag]] = [:]
    var calls: [String] = []
    var failTagWrites = false

    func setFailTagWrites(_ value: Bool) { failTagWrites = value }

    func photo(_ space: PhotoSpace) throws -> PhotoItem {
        let tagJSON = (tags[space] ?? []).map { #"{"id":\#($0.id),"name":"\#($0.name)"}"# }.joined(separator: ",")
        return try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"filename":"fixture.jpg","time":1704067200,"type":"photo","additional":{"thumbnail":{"unit_id":91,"cache_key":"k","sm":"ready","m":"ready","xl":"ready"},"favorite":true,"rating":\(ratings[space] ?? 0),"tag":[\(tagJSON)]}}
        """.utf8))
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { [try photo(space)] }
    func setRating(itemIDs: [Int64], rating: Int, space: PhotoSpace) async throws {
        calls.append("rating:\(space.rawValue):\(rating)")
        ratings[space] = rating
    }
    func createTag(name: String, space: PhotoSpace) async throws -> PhotoTag {
        calls.append("create:\(space.rawValue):\(name)")
        return PhotoTag(id: 41, name: name)
    }
    func addTags(_ tagIDs: [Int64], toItems itemIDs: [Int64], space: PhotoSpace) async throws {
        calls.append("add:\(space.rawValue):\(tagIDs)")
        // The server applies the write even when the response is lost.
        tags[space, default: []].append(contentsOf: tagIDs.map { PhotoTag(id: $0, name: "t\($0)") })
        if failTagWrites { throw AnnotationFailure() }
    }
    func removeTags(_ tagIDs: [Int64], fromItems itemIDs: [Int64], space: PhotoSpace) async throws {
        calls.append("remove:\(space.rawValue):\(tagIDs)")
        tags[space]?.removeAll { tagIDs.contains($0.id) }
    }
}

final class AnnotationTests: XCTestCase, @unchecked Sendable {
    private let section = TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1)])

    private func makeRepository(_ transport: AnnotationTransport) throws -> (CachedPhotosRepository, URL) {
        let root = temporaryTestRoot("annotations")
        let repository = try CachedPhotosRepository(credentials: .init(username: "fixture", password: "unused"), cacheRoot: root, transport: transport)
        return (repository, root)
    }

    private func action(_ photo: PhotoItem, space: PhotoSpace) -> SelectionAnnotationAction {
        SelectionAnnotationAction(itemIDs: [photo.id], collection: .library(space), itemsByID: [photo.id: photo])
    }

    private func storedItem(_ repository: CachedPhotosRepository, _ space: PhotoSpace) async throws -> PhotoItem? {
        let namespace = await repository.metadataNamespace(for: .library(space))
        return try await repository.store.metadataDetails(namespace, ids: [1], currentRun: repository.runID)[1]?.item
    }

    func testRatingPatchesOnlyTheItemsSpaceAndReachesOpenViewers() async throws {
        let transport = AnnotationTransport()
        let (repository, root) = try makeRepository(transport)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try await transport.photo(.shared)
        try await seedMetadataPage([photo], section: section, repository: repository, collection: .library(.personal))
        try await seedMetadataPage([photo], section: section, repository: repository, collection: .library(.shared))
        let timeline = try CollectionDayPager.snapshot(catalog: CollectionDayCatalog(sections: [section], completeness: .complete))
        func viewer(_ space: PhotoSpace) -> PhotoViewerSession {
            PhotoViewerSession(repository: repository, collection: .library(space), index: LibraryIndex(snapshot: timeline),
                               seed: .init(sectionIndex: 0, pageOffset: 0, item: photo, page: [photo], pageVerified: true), allowNetwork: false)
        }
        let shared = viewer(.shared), personal = viewer(.personal)
        _ = await shared.state(); _ = await personal.state()
        try await Task.sleep(for: .milliseconds(10))

        try await repository.annotate(action(photo, space: .shared), edit: .rating(4))

        for _ in 0..<100 {
            if await shared.state().item?.rating == 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sharedState = await shared.state()
        let personalState = await personal.state()
        XCTAssertEqual(sharedState.item?.rating, 4)
        XCTAssertTrue(sharedState.item?.isFavorite == true, "a rating edit must not disturb other fields")
        XCTAssertEqual(personalState.item?.rating, 0)
        let storedShared = try await storedItem(repository, .shared)
        let storedPersonal = try await storedItem(repository, .personal)
        XCTAssertEqual(storedShared?.rating, 4)
        XCTAssertEqual(storedPersonal?.rating, 0)
        let calls = await transport.calls
        XCTAssertEqual(calls, ["rating:shared:4"])
        await shared.close(); await personal.close()
    }

    func testNewTagIsCreatedInTheItemsSpaceThenAddedAndCached() async throws {
        let transport = AnnotationTransport()
        let (repository, root) = try makeRepository(transport)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try await transport.photo(.personal)
        try await seedMetadataPage([photo], section: section, repository: repository, collection: .library(.personal))

        try await repository.addNewTag(named: "  Holiday ", to: action(photo, space: .personal))

        let calls = await transport.calls
        XCTAssertEqual(calls, ["create:personal:Holiday", "add:personal:[41]"])
        let stored = try await storedItem(repository, .personal)
        XCTAssertEqual(stored?.tags.map(\.id), [41])
    }

    func testRemovingTagUpdatesCachedTags() async throws {
        let transport = AnnotationTransport()
        let (repository, root) = try makeRepository(transport)
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = PhotoTag(id: 41, name: "t41")
        try await repository.annotate(action(try await transport.photo(.personal), space: .personal), edit: .addTags([tag]))
        let tagged = try await transport.photo(.personal)
        try await seedMetadataPage([tagged], section: section, repository: repository, collection: .library(.personal))
        XCTAssertEqual(action(tagged, space: .personal).presentTags, [tag])

        try await repository.annotate(action(tagged, space: .personal), edit: .removeTags([tag]))

        let stored = try await storedItem(repository, .personal)
        XCTAssertEqual(stored?.tags, [])
    }

    func testFailedWriteIsReadBackSoCacheReflectsWhatTheServerApplied() async throws {
        let transport = AnnotationTransport()
        await transport.setFailTagWrites(true)
        let (repository, root) = try makeRepository(transport)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try await transport.photo(.personal)
        try await seedMetadataPage([photo], section: section, repository: repository, collection: .library(.personal))

        do {
            try await repository.annotate(action(photo, space: .personal), edit: .addTags([PhotoTag(id: 7, name: "t7")]))
            XCTFail("The write failure must be reported")
        } catch is AnnotationFailure {}

        let stored = try await storedItem(repository, .personal)
        XCTAssertEqual(stored?.tags.map(\.id), [7])
    }

    func testInvalidInputIsRejectedBeforeAnyRequest() async throws {
        let transport = AnnotationTransport()
        let (repository, root) = try makeRepository(transport)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try await transport.photo(.personal)
        do {
            try await repository.annotate(action(photo, space: .personal), edit: .rating(6))
            XCTFail("Six stars is invalid")
        } catch RepositoryError.invalidInput {}
        do {
            try await repository.addNewTag(named: "   ", to: action(photo, space: .personal))
            XCTFail("An empty tag name is invalid")
        } catch RepositoryError.invalidInput {}
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCommonRatingAndPresentTagsSummarizeTheSelection() throws {
        func item(_ id: Int, rating: Int, tags: String) throws -> PhotoItem {
            try JSONDecoder().decode(PhotoItem.self, from: Data(
                #"{"id":\#(id),"time":1,"type":"photo","additional":{"rating":\#(rating),"tag":[\#(tags)]}}"#.utf8))
        }
        let a = try item(1, rating: 3, tags: #"{"id":2,"name":"Beta"},{"id":1,"name":"alpha"}"#)
        let b = try item(2, rating: 3, tags: #"{"id":2,"name":"Beta"}"#)
        let c = try item(3, rating: 5, tags: "")
        let same = SelectionAnnotationAction(itemIDs: [1, 2], collection: .library(.personal), itemsByID: [1: a, 2: b])
        XCTAssertEqual(same.commonRating, 3)
        XCTAssertEqual(same.presentTags.map(\.name), ["alpha", "Beta"])
        let mixed = SelectionAnnotationAction(itemIDs: [1, 3], collection: .library(.personal), itemsByID: [1: a, 3: c])
        XCTAssertNil(mixed.commonRating)
    }
}
