import Foundation
import XCTest
import PhotoCache
import SynologyAPI
@testable import SynoTimelineApp

private actor LazyCollectionTransport: PhotosTransport {
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: [CollectionDayCount(day: CaptureDay(year: 2024, month: 1, day: 1), count: 1)], completeness: .complete)
    }
}

@MainActor
final class LazyCollectionLoadingTests: XCTestCase {
    func testPersonSubjectAndTagTimelinesStartOnDemand() async throws {
        let root = temporaryTestRoot("LazyCollectionLoading")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: SynologyCredentials(username: "test", password: "unused"), cacheRoot: root, transport: LazyCollectionTransport())
        let model = LibraryModel(repository: repository)
        let collections: [PhotoCollectionDescriptor] = [.person(1), .subject(2), .tag(3)]
        collections.forEach { model.ensureCollectionLoaded($0) }
        let loaded = await waitUntil { collections.allSatisfy { model.timelineVerified(for: $0) } }
        XCTAssertTrue(loaded)
    }
}
