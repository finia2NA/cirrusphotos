import Foundation
import XCTest
@testable import SynologyAPI

final class PrivateSharingTransportTests: XCTestCase {
    func testCapturedFormsAndDatalessUpdate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivateSharingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let owner = try await client.currentPhotosUserID()
        XCTAssertEqual(owner, 11)
        let principals = try await client.sharingPrincipals()
        XCTAssertEqual(principals.first?.id, 1036)
        let reference = try await client.setAlbumShared(id: 69, enabled: true)
        let member = SharingPermissionChange.Member(type: "user", id: 1036)
        try await client.updateAlbumSharing(reference: reference.passphrase, changes: [
            .init(action: "update", role: "download", member: member),
            .init(action: "delete", member: .init(type: "user", id: 1035))
        ], password: .unchanged, expiration: 0)
        try await client.updateAlbumSharing(reference: reference.passphrase, changes: [.init(action: "update", role: "view", member: member)], password: .unchanged, expiration: nil)
        try await client.updateAlbumSharing(reference: reference.passphrase, changes: [.init(action: "update", role: "view", member: .init(type: "public"))], password: .set("fixture-password"), expiration: 1794956399)
        try await client.updateAlbumSharing(reference: reference.passphrase, changes: [.init(action: "update", role: "download", member: .init(type: "public"))], password: .unchanged, expiration: nil)
        try await client.updateAlbumSharing(reference: reference.passphrase, changes: [.init(action: "delete", member: .init(type: "public"))], password: .clear, expiration: 0)
        _ = try await client.setAlbumShared(id: 69, enabled: false)
    }
}

private final class PrivateSharingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        let components = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary(components.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        let json: String
        switch values["method"] {
        case "login": json = #"{"success":true,"data":{"sid":"fixture"}}"#
        case "me": json = #"{"success":true,"data":{"id":11,"uid":1036}}"#
        case "list_user_group":
            XCTAssertEqual(values["team_space_sharable_list"], "false")
            json = #"{"success":true,"data":{"list":[{"id":1036,"name":"Test","type":"user"}]}}"#
        case "set_shared":
            XCTAssertEqual(values["policy"], "\"album\"")
            XCTAssertEqual(values["album_id"], "69")
            json = #"{"success":true,"data":{"passphrase":"fixture-reference","sharing_link":"https://example.test/share"}}"#
        case "update":
            XCTAssertEqual(values["passphrase"], "\"fixture-reference\"")
            let changes = try! JSONSerialization.jsonObject(with: Data(values["permission"]!.utf8)) as! [[String: Any]]
            let member = changes[0]["member"] as! [String: Any]
            if member["type"] as? String == "public" {
                XCTAssertNil(member["id"])
                if changes[0]["action"] as? String == "update" {
                    if changes[0]["role"] as? String == "download" {
                        XCTAssertNil(values["password"])
                        XCTAssertNil(values["expiration"])
                    } else {
                        XCTAssertEqual(changes[0]["role"] as? String, "view")
                        XCTAssertEqual(values["password"], "\"fixture-password\"")
                        XCTAssertEqual(values["expiration"], "1794956399")
                    }
                } else {
                    XCTAssertEqual(changes[0]["action"] as? String, "delete")
                    XCTAssertNil(changes[0]["role"])
                    XCTAssertEqual(values["password"], "\"\"")
                    XCTAssertEqual(values["expiration"], "0")
                }
                json = #"{"success":true}"#
                break
            }
            XCTAssertEqual(changes[0]["action"] as? String, "update")
            if changes.count == 1 {
                XCTAssertNil(values["expiration"])
                XCTAssertNil(values["password"])
                XCTAssertEqual(changes[0]["role"] as? String, "view")
                json = #"{"success":true}"#
                break
            }
            XCTAssertEqual(values["expiration"], "0")
            XCTAssertEqual(changes.count, 2)
            XCTAssertEqual(changes[0]["role"] as? String, "download")
            XCTAssertEqual((changes[0]["member"] as? [String: Any])?["id"] as? Int, 1036)
            XCTAssertEqual(changes[1]["action"] as? String, "delete")
            XCTAssertNil(changes[1]["role"])
            XCTAssertEqual((changes[1]["member"] as? [String: Any])?["id"] as? Int, 1035)
            json = #"{"success":true}"#
        default: XCTFail("Unexpected request"); json = #"{"success":false}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
