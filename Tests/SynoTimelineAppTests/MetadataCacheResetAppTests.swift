import Foundation
import XCTest
import PhotoCache
import SynologyAPI
@testable import SynoTimelineApp

private actor MetadataResetAppTransport: TestPhotosTransport {
    let snapshot: TimelineSnapshot

    init(snapshot: TimelineSnapshot) { self.snapshot = snapshot }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(snapshot, initial: initial)
    }
}

@MainActor
final class MetadataCacheResetAppTests: XCTestCase {
    func testSuccessfulResetClearsSessionCollectionsAndPublishesOneUIRevision() async throws {
        let root = temporaryTestRoot("SynoMetadataResetAppTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(
                offset: 0,
                limit: 1,
                list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 1)]
            )
        ])
        let repository = try CachedPhotosRepository(
            credentials: SynologyCredentials(username: "test", password: "unused"),
            baseURL: URL(string: "https://reset.example.invalid")!,
            cacheRoot: root,
            transport: MetadataResetAppTransport(snapshot: snapshot)
        )
        let model = LibraryModel(repository: repository)
        await model.load()
        let filter = PhotoCollectionDescriptor.mapFilter(UUID(), space: .personal)
        model.registerSessionCollection(filter, snapshot: snapshot)

        await model.clearMetadataCache()
        let handled = await waitUntil {
            model.metadataInvalidationRevision > 0 && model.snapshot(for: filter) == nil
        }

        XCTAssertTrue(handled)
        XCTAssertFalse(model.cacheResetInProgress)
        XCTAssertNil(model.cacheResetError)
    }
}
