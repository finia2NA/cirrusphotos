import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class AlbumContainmentTests: XCTestCase {
    private let credentials = SynologyCredentials(username: "containment-test", password: "unused")
    private let section = TimelineSection(offset: 0, limit: 3, list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 3)])

    private func item(_ id: Int64, filename: String = "photo.jpg") throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":\#(id),"time":1704110400,"type":"photo","filename":"\#(filename)"}"#.utf8))
    }

    private func selection(_ ids: [Int64], known: [Int64]? = nil) -> PhotoSelectionSnapshot {
        let timeline = TimelineSnapshot(sections: [section])
        let known = known ?? ids
        return PhotoSelectionSnapshot(collection: .library(.personal), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(0..<ids.count),
            knownItemIDsByOrdinal: Dictionary(uniqueKeysWithValues: known.enumerated().map { ($0.offset, $0.element) }))
    }

    func testOnlyAlbumsWhoseCachedMembersMatchTheWholeSelectionContainIt() async throws {
        let root = temporaryTestRoot("album-containment")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: ContainmentNoNetworkTransport())
        try await seedMetadataPage([item(1), item(2), item(3)], section: section, repository: repository)
        let full = PhotoCollectionDescriptor.album(10)
        let partial = PhotoCollectionDescriptor.album(11)
        let differentItem = PhotoCollectionDescriptor.album(12)
        let uncached = PhotoCollectionDescriptor.album(13)
        try await seedMetadataPage([item(1), item(2), item(3)], section: section, repository: repository, collection: full)
        let partialSection = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 1, day: 1, itemCount: 2)])
        try await seedMetadataPage([item(1), item(3)], section: partialSection, repository: repository, collection: partial)
        try await seedMetadataPage([item(1), item(2, filename: "other.jpg"), item(3)], section: section, repository: repository, collection: differentItem)

        let targets = [full, partial, differentItem, uncached]
        let contained = await repository.cachedContainment(of: selection([1, 2]), in: targets)
        XCTAssertEqual(contained, [full])
        let first = await repository.cachedContainment(of: selection([1]), in: targets)
        XCTAssertEqual(first, [full, partial, differentItem])
    }

    func testUnloadedSelectedItemsGiveNoAnswer() async throws {
        let root = temporaryTestRoot("album-containment-unloaded")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: credentials, cacheRoot: root, transport: ContainmentNoNetworkTransport())
        try await seedMetadataPage([item(1), item(2), item(3)], section: section, repository: repository)
        try await seedMetadataPage([item(1), item(2), item(3)], section: section, repository: repository, collection: .album(10))
        let contained = await repository.cachedContainment(of: selection([1, 2], known: [1]), in: [.album(10)])
        XCTAssertTrue(contained.isEmpty)
    }
}

private struct ContainmentNoNetworkTransport: TestPhotosTransport {}
