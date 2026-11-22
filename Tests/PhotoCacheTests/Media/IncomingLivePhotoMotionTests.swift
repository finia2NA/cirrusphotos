import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

private actor IncomingMotionTransport: TestPhotosTransport {
    var motionLookups: [String] = []
    var streamReferences: [String?] = []

    func incomingLivePhotoMotion(itemID: Int64, ownerID: Int64, albumID: Int64,
                                 reference: String) async throws -> VideoPlaybackResource? {
        motionLookups.append("\(ownerID):\(albumID):\(itemID):\(reference)")
        return VideoPlaybackResource(scope: .incomingAlbum(ownerID: ownerID, albumID: albumID), unitID: 99,
                                     cacheKey: "99_1", filename: "IMG.MOV", variant: .converted(.high))
    }

    func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>, reference: String?,
                          receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws {
        streamReferences.append(reference)
        let delivered = range.lowerBound...min(range.upperBound, 3)
        try await receive(.header(VideoRangeHeader(range: delivered, totalLength: 4, contentType: "video/mp4",
                                                  etag: nil, lastModified: nil)))
        try await receive(.bytes(offset: delivered.lowerBound, data: Data([1, 2, 3, 4])))
    }
}

private actor MotionBytes {
    var data = Data()
    func append(_ value: Data) { data.append(value) }
}

private extension CachedPhotosRepository {
    func grantIncomingAccess(_ album: IncomingAlbum, for collection: PhotoCollectionDescriptor) {
        incomingAccess[collection] = album
    }
}

final class IncomingLivePhotoMotionTests: XCTestCase {
    func testIncomingMotionLooksUpAndStreamsWithTheAlbumReference() async throws {
        let root = temporaryTestRoot("IncomingMotion")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = IncomingMotionTransport()
        let repository = try CachedPhotosRepository(credentials: SynologyCredentials(username: "test", password: "unused"),
                                                     baseURL: URL(string: "https://example.invalid")!,
                                                     cacheRoot: root, transport: transport)
        let granted = PhotoCollectionDescriptor.incomingAlbum(ownerID: 1, albumID: 2)
        let album = try JSONDecoder().decode(IncomingAlbum.self, from: Data(#"{"id":2,"name":"Shared","item_count":1,"passphrase":"session-reference","additional":{"access_permission":{"view":true,"download":false}}}"#.utf8))
        await repository.grantIncomingAccess(album, for: granted)

        let motion = try await repository.livePhotoMotion(itemID: 5, collection: granted)
        let resource = try XCTUnwrap(motion)
        XCTAssertEqual(resource.scope, .incomingAlbum(ownerID: 1, albumID: 2))
        let bytes = MotionBytes()
        try await repository.streamVideoData(resource, offset: 0, length: 4) { await bytes.append($0.data) }
        let received = await bytes.data
        let lookups = await transport.motionLookups
        let references = await transport.streamReferences
        XCTAssertEqual(received, Data([1, 2, 3, 4]))
        XCTAssertEqual(lookups, ["1:2:5:session-reference"])
        XCTAssertEqual(references, ["session-reference"])

        let other = PhotoCollectionDescriptor.incomingAlbum(ownerID: 3, albumID: 2)
        do {
            _ = try await repository.livePhotoMotion(itemID: 5, collection: other)
            XCTFail("An album without known access must not look up motion")
        } catch RepositoryError.unavailable {}
        let foreign = VideoPlaybackResource(scope: other.contentScope, unitID: 99, cacheKey: "99_1",
                                            filename: nil, variant: .converted(.high))
        do {
            try await repository.streamVideoData(foreign, offset: 0, length: 4) { _ in }
            XCTFail("An album without known access must not stream")
        } catch RepositoryError.unavailable {}
        let finalLookups = await transport.motionLookups
        let finalReferences = await transport.streamReferences
        XCTAssertEqual(finalLookups.count, 1)
        XCTAssertEqual(finalReferences.count, 1)
    }
}
