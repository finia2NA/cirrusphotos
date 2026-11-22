import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

/// Serves one owned-album video member that exists in exactly `origin`, or in both spaces.
private actor AlbumVideoTransport: TestPhotosTransport {
    let member: PhotoItem
    let origins: Set<PhotoSpace>
    init(member: PhotoItem, origins: Set<PhotoSpace>) { self.member = member; self.origins = origins }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] { [member] }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { origins.contains(space) ? [member] : [] }
    func albumThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64) async throws -> Data {
        Data([1])
    }
}

final class AlbumVideoViewerTests: XCTestCase {
    private func video() throws -> PhotoItem {
        let json = #"{"id":12,"filename":"clip.mov","time":1711929600,"type":"video","additional":{"thumbnail":{"unit_id":12,"cache_key":"12_1","sm":"ready","m":"ready","xl":"ready"},"video_convert":[{"quality":"high","metadata":{}}]}}"#
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }

    private func session(origins: Set<PhotoSpace>, root: URL) throws -> PhotoViewerSession {
        let member = try video()
        let repository = try CachedPhotosRepository(credentials: SynologyCredentials(username: "fixture", password: "unused"),
                                                     baseURL: URL(string: "https://example.invalid")!, cacheRoot: root,
                                                     transport: AlbumVideoTransport(member: member, origins: origins))
        let snapshot = TimelineSnapshot(sections: [
            TimelineSection(offset: 0, limit: 1, list: [TimelineDay(year: 2024, month: 4, day: 1, itemCount: 1)])
        ])
        return PhotoViewerSession(repository: repository, collection: .album(3), index: LibraryIndex(snapshot: snapshot),
                                  seed: PhotoViewerSeed(sectionIndex: 0, pageOffset: 0, item: member, page: [member],
                                                        pageVerified: true),
                                  allowNetwork: true)
    }

    func testOwnedAlbumVideoStreamsFromItsVerifiedSpace() async throws {
        let root = temporaryTestRoot("AlbumVideo")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(origins: [.shared], root: root)
        _ = await session.state()
        let resolved = await waitUntil { await session.state().videoResource != nil }
        XCTAssertTrue(resolved)
        let resource = await session.state().videoResource
        XCTAssertEqual(resource?.scope, .space(.shared))
        XCTAssertEqual(resource?.variant, .converted(.high))
        await session.close()
    }

    func testAmbiguousAlbumVideoOriginIsReportedUnavailable() async throws {
        let root = temporaryTestRoot("AlbumVideoAmbiguous")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(origins: [.personal, .shared], root: root)
        _ = await session.state()
        let reported = await waitUntil {
            if case .unsupported = await session.state().fullImageStatus { return true }
            return false
        }
        XCTAssertTrue(reported)
        let resource = await session.state().videoResource
        XCTAssertNil(resource)
        await session.close()
    }
}
