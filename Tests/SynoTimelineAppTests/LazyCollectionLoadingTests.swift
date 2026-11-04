import Foundation
import XCTest
import PhotoCache
import SynologyAPI
@testable import SynoTimelineApp

private actor LazyCollectionTransport: TestPhotosTransport {
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: [CollectionDayCount(day: CaptureDay(year: 2024, month: 1, day: 1), count: 1)], completeness: .complete)
    }
}

@MainActor
final class LazyCollectionLoadingTests: XCTestCase {
    func testContextualAlbumActionsRemainAvailableWithoutAnInferredSpace() {
        let model = LibraryModel(repository: nil)
        XCTAssertNil(PhotoCollectionDescriptor.album(7).space)
        XCTAssertTrue(model.capabilities(for: .album(7)).allowsPersonalActions)
        XCTAssertTrue(model.capabilities(for: .library(.personal)).allowsPersonalActions)
        XCTAssertFalse(model.capabilities(for: .library(.shared)).allowsPersonalActions)
        XCTAssertFalse(model.capabilities(for: .incomingAlbum(ownerID: 2, albumID: 7)).allowsPersonalActions)
        XCTAssertFalse(model.capabilities(for: .libraryFilter(UUID(), scope: .space(.personal))).allowsPersonalActions)
        XCTAssertTrue(model.capabilities(for: .library(.shared)).allowsAlbumMembership)
        XCTAssertTrue(model.capabilities(for: .favorites(.shared)).allowsAlbumMembership)
        XCTAssertTrue(model.capabilities(for: .album(7)).allowsAlbumMembership)
        XCTAssertFalse(model.capabilities(for: .incomingAlbum(ownerID: 2, albumID: 7)).allowsAlbumMembership)
        XCTAssertFalse(model.capabilities(for: .libraryFilter(UUID(), scope: .space(.shared))).allowsAlbumMembership)
    }

    func testPersonSubjectAndTagTimelinesStartOnDemand() async throws {
        let root = temporaryTestRoot("LazyCollectionLoading")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: SynologyCredentials(username: "test", password: "unused"), cacheRoot: root, transport: LazyCollectionTransport())
        let model = LibraryModel(repository: repository)
        let collections: [PhotoCollectionDescriptor] = [.person(1, space: .personal), .subject(2, space: .personal), .tag(3, space: .personal)]
        collections.forEach { model.ensureCollectionLoaded($0) }
        let loaded = await waitUntil { collections.allSatisfy { model.timelineVerified(for: $0) } }
        XCTAssertTrue(loaded)
    }
}
