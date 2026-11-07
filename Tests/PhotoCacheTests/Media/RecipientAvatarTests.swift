import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor AvatarTransport: TestPhotosTransport {
    var calls = 0
    var photos = 0
    func userProfiles(ids: [Int64]) async throws -> [PhotosUserProfile] {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        return try JSONDecoder().decode([PhotosUserProfile].self, from: Data(#"[{"id":11,"uid":1036,"name":"Recipient","enabled":true,"profile":{"photo":"descriptor"}}]"#.utf8))
    }
    func profilePhoto(descriptor: String) async throws -> Data { photos += 1; return Data([1, 2, 3]) }
}

final class RecipientAvatarTests: XCTestCase {
    func testCoalescingAndIdentityMismatchFallback() async throws {
        let transport = AvatarTransport()
        let root = temporaryTestRoot("avatars")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"), cacheRoot: root, transport: transport)
        async let first = repository.recipientAvatar(photosID: 11, principalID: 1036)
        async let second = repository.recipientAvatar(photosID: 11, principalID: 1036)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, Data([1, 2, 3])); XCTAssertEqual(b, a)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
        let mismatch = await repository.recipientAvatar(photosID: 11, principalID: 999)
        XCTAssertNil(mismatch)
        let photos = await transport.photos
        XCTAssertEqual(photos, 1)
    }
}
