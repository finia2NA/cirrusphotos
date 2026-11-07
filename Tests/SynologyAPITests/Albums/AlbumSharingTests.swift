import XCTest
@testable import SynologyAPI

final class AlbumSharingTests: XCTestCase {
    func testDisabledAlbumCanRetainNestedReference() throws {
        let data = Data(#"{"id":7,"name":"Example","item_count":2,"type":"normal","shared":false,"passphrase":"","additional":{"sharing_info":{"privacy_type":"private","permission":[],"passphrase":"fixture-reference","sharing_link":""}}}"#.utf8)
        let album = try JSONDecoder().decode(AlbumSummary.self, from: data)
        XCTAssertFalse(album.shared)
        XCTAssertEqual(album.sharingInfo?.permission, [])
        XCTAssertEqual(album.sharingInfo?.reference, "fixture-reference")
        XCTAssertEqual(album.sharingInfo?.sharingLink, "")
        let encoded = String(decoding: try JSONEncoder().encode(album), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-reference"))
        XCTAssertFalse(encoded.contains("sharing_link"))
    }
    func testSharingRoundTripKeepsIdentityAndUnknownValues() throws {
        let data = Data(#"{"id":7,"name":"Example","item_count":2,"type":"normal","owner_user_id":1,"shared":true,"additional":{"sharing_info":{"privacy_type":"future-mode","expiration":3,"is_expired":true,"enable_password":false,"permission":[{"db_id":11,"id":1036,"name":"Person","role":"future-role","type":"user"}]}}}"#.utf8)
        let album = try JSONDecoder().decode(AlbumSummary.self, from: data)
        let grant = try XCTUnwrap(album.sharingInfo?.permission?.first)
        XCTAssertEqual(grant.photosUserID, 11)
        XCTAssertEqual(grant.principalID, 1036)
        XCTAssertEqual(grant.role, "future-role")
        XCTAssertEqual(album.sharingInfo?.privacyType, "future-mode")
        XCTAssertEqual(try JSONDecoder().decode(AlbumSummary.self, from: JSONEncoder().encode(album)), album)
    }
}

private final class ProfileProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let isPhoto = request.httpMethod != "POST"
        if isPhoto {
            let url = request.url!
            XCTAssertEqual(url.host, "example.test")
            let values = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            XCTAssertEqual(values["f"], "opaque/file.png")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isPhoto ? "image/png" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isPhoto ? Data([1, 2, 3]) : Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension AlbumSharingTests {
    func testProfileDescriptorIsRestrictedToConfiguredHostAndCapturedShape() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let data = try await client.profilePhoto(descriptor: "webapi/entry.cgi?api=SYNO.Personal.Profile.Photo&method=get&version=1&f=opaque%2Ffile.png")
        XCTAssertEqual(data, Data([1, 2, 3]))
        do {
            _ = try await client.profilePhoto(descriptor: "https://elsewhere.test/webapi/entry.cgi?api=SYNO.Personal.Profile.Photo&method=get&version=1&f=x")
            XCTFail("A remote descriptor must be rejected")
        } catch { }
    }
}
