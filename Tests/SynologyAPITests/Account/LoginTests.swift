import Foundation
import os
import XCTest
@testable import SynologyAPI

final class LoginTests: XCTestCase {
    private func client(_ protocolClass: AnyClass) -> (SynologyClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        return (SynologyClient(baseURL: URL(string: "https://example.test")!, session: session), session)
    }

    func testMissingAndBlankOTPAllowCredentials() throws {
        for suffix in ["", "OTP=\n", "OTP='   '\n"] {
            let credentials = try CredentialStore.credentials(from: Data("NAS_URL=https://nas.example.test\nUSER=phototest\nPW=test-password\n\(suffix)".utf8))
            XCTAssertEqual(credentials.secondFactor, .none)
            XCTAssertEqual(credentials.serverTrust, .system)
        }
        XCTAssertThrowsError(try CredentialStore.credentials(from: Data("USER=phototest\n".utf8)))
        XCTAssertThrowsError(try CredentialStore.credentials(from: Data("NAS_URL=nas\nUSER=phototest\nPW=x\n".utf8)))
        XCTAssertThrowsError(try CredentialStore.credentials(from: Data("USER=phototest\nPW=x\n".utf8)))
    }

    func testEachSecondFactorSendsItsLoginParameters() async throws {
        let cases: [(String, SecondFactor)] = [
            ("none", .none), ("secret", .totpSecret("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")),
            ("code", .code("123456")), ("token", .deviceToken("device-token"))
        ]
        for (name, factor) in cases {
            let (client, session) = client(SuccessfulLoginProtocol.self)
            defer { session.invalidateAndCancel() }
            let result = try await client.signIn(.init(username: name, password: "test-password", secondFactor: factor))
            XCTAssertEqual(result.deviceToken, "issued-token")
        }
    }

    func testMissingCodeOrUntrustedDeviceRequiresSecondFactor() async throws {
        for factor in [SecondFactor.none, .deviceToken("removed-device")] {
            let (client, session) = client(RequiredOTPProtocol.self)
            defer { session.invalidateAndCancel() }
            do {
                try await client.login(credentials: .init(username: "403", password: "test-password", secondFactor: factor))
                XCTFail("Expected a second-factor requirement")
            } catch SynologyAPIError.secondFactorRequired {}
        }
    }

    func testRejectedCodeAndOtherFailuresKeepTheirCodes() async throws {
        let (client, session) = client(RequiredOTPProtocol.self)
        defer { session.invalidateAndCancel() }
        for (account, factor) in [("404", SecondFactor.code("000000")), ("406", .none), ("400", .none)] {
            do {
                try await client.login(credentials: .init(username: account, password: "test-password", secondFactor: factor))
                XCTFail("Expected a failure")
            } catch SynologyAPIError.api(let code) {
                XCTAssertEqual(String(code), account)
            }
        }
    }

    func testExpiredSessionRenewsOnceWithTheTrustedDeviceAndRetries() async throws {
        RenewingProtocol.reset()
        let (client, session) = client(RenewingProtocol.self)
        defer { session.invalidateAndCancel() }
        try await client.signIn(.init(username: "user", password: "test-password", secondFactor: .code("123456")))
        let albums = try await client.albums()
        XCTAssertTrue(albums.isEmpty)
        let logins = RenewingProtocol.logins()
        XCTAssertEqual(logins.count, 2)
        XCTAssertEqual(logins.last?["otp_code"], nil)
        XCTAssertEqual(logins.last?["device_id"], "issued-token")
    }

    func testConcurrentExpiredThumbnailsShareOneRenewalAndRetry() async throws {
        RenewingProtocol.reset()
        let (client, session) = client(RenewingProtocol.self)
        defer { session.invalidateAndCancel() }
        try await client.signIn(.init(username: "user", password: "test-password", secondFactor: .code("123456")))
        let images = try await withThrowingTaskGroup(of: Data.self) { group in
            for id in 1...20 {
                group.addTask {
                    try await client.thumbnail(ThumbnailInfo(unitID: Int64(id), cacheKey: "\(id)_1"), size: .m, space: .personal)
                }
            }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        XCTAssertEqual(images.count, 20)
        XCTAssertEqual(RenewingProtocol.logins().count, 2)
    }

    func testEveryMediaRequestRenewsAnExpiredSessionAndRetries() async throws {
        let requests: [(String, (SynologyClient) async throws -> Void)] = [
            ("original", { client in
                let response = try await client.fullImage(FullImageResource(scope: .space(.personal), unitID: 7, cacheKey: "7_1"))
                XCTAssertNotNil(response.data)
            }),
            ("video", { client in
                let resource = VideoPlaybackResource(scope: .space(.personal), unitID: 7, cacheKey: "7_1",
                                                     filename: nil, variant: .original)
                try await client.streamVideoRange(resource, range: 0...3) { _ in }
            }),
            ("download", { client in
                let download = try await client.downloadPhotos(itemIDs: [7], kind: .original, space: .personal, progress: { _ in })
                try? FileManager.default.removeItem(at: download.temporaryURL.deletingLastPathComponent())
            }),
            ("profile photo", { client in
                _ = try await client.profilePhoto(
                    descriptor: "webapi/entry.cgi?api=SYNO.Personal.Profile.Photo&method=get&version=1&f=file.png")
            }),
        ]
        for (name, perform) in requests {
            RenewingProtocol.reset()
            let (client, session) = client(RenewingProtocol.self)
            defer { session.invalidateAndCancel() }
            try await client.signIn(.init(username: "user", password: "test-password", secondFactor: .code("123456")))
            do { try await perform(client) } catch { XCTFail("\(name): \(error)") }
            XCTAssertEqual(RenewingProtocol.logins().count, 2, name)
        }
    }

    func testReachabilityChangesAreReportedOnce() async throws {
        RenewingProtocol.reset(offline: true)
        let (client, session) = client(RenewingProtocol.self)
        defer { session.invalidateAndCancel() }
        try await client.signIn(.init(username: "user", password: "test-password", secondFactor: .code("123456")))
        let changes = OSAllocatedUnfairLock(initialState: [Bool]())
        await client.onReachabilityChange { reachable in changes.withLock { $0.append(reachable) } }
        let descriptor = ThumbnailInfo(unitID: 1, cacheKey: "1_1")
        for _ in 0..<2 {
            do { _ = try await client.thumbnail(descriptor, size: .m, space: .personal); XCTFail("Expected offline") }
            catch SynologyAPIError.transport {}
        }
        RenewingProtocol.setOffline(false)
        _ = try await client.thumbnail(descriptor, size: .m, space: .personal)
        _ = try await client.thumbnail(descriptor, size: .m, space: .personal)
        XCTAssertEqual(changes.withLock { $0 }, [false, true])
    }

    func testFailedRenewalIsReportedAndNotRetried() async throws {
        RenewingProtocol.reset(rejectRenewal: true)
        let (client, session) = client(RenewingProtocol.self)
        defer { session.invalidateAndCancel() }
        try await client.signIn(.init(username: "user", password: "test-password", secondFactor: .code("123456")))
        let reported = expectation(description: "renewal failure reported")
        await client.onSessionRenewalFailure { error in
            XCTAssertEqual(error, .secondFactorRequired)
            reported.fulfill()
        }
        do {
            _ = try await client.albums()
            XCTFail("Expected the renewal failure")
        } catch SynologyAPIError.secondFactorRequired {}
        await fulfillment(of: [reported], timeout: 1)
        do {
            _ = try await client.albums()
            XCTFail("Expected the expired session")
        } catch SynologyAPIError.api(119) {}
        XCTAssertEqual(RenewingProtocol.logins().count, 2)
    }

    func testTypedServerAddresses() {
        XCTAssertEqual(ServerAddress.url(from: "NAS.example.com")?.absoluteString, "https://nas.example.com:5001")
        XCTAssertEqual(ServerAddress.url(from: " nas.local:5443 ")?.absoluteString, "https://nas.local:5443")
        XCTAssertEqual(ServerAddress.url(from: "https://nas.example.com")?.absoluteString, "https://nas.example.com")
        XCTAssertEqual(ServerAddress.url(from: "https://nas.example.com/")?.absoluteString, "https://nas.example.com")
        XCTAssertNil(ServerAddress.url(from: "http://nas.example.com"))
        XCTAssertNil(ServerAddress.url(from: "https://nas.example.com/photo"))
        XCTAssertNil(ServerAddress.url(from: "https://user:pw@nas.example.com"))
        XCTAssertNil(ServerAddress.url(from: ""))
    }
}

private class LoginProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    func parameters() -> [String: String] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            data = body
        } else { data = Data() }
        let components = URLComponents(string: "https://example.test/?" + String(decoding: data, as: UTF8.self))
        return Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    func respond(_ json: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SuccessfulLoginProtocol: LoginProtocol, @unchecked Sendable {
    override func startLoading() {
        let values = parameters()
        XCTAssertEqual(values["session"], "webui")
        XCTAssertEqual(values["device_name"], "Cirrus Photos")
        switch values["account"] {
        case "none":
            XCTAssertNil(values["otp_code"]); XCTAssertNil(values["device_id"])
            XCTAssertEqual(values["enable_device_token"], "no")
        case "secret":
            XCTAssertEqual(values["otp_code"]?.count, 6)
            XCTAssertEqual(values["enable_device_token"], "no")
        case "code":
            XCTAssertEqual(values["otp_code"], "123456")
            XCTAssertEqual(values["enable_device_token"], "yes")
        case "token":
            XCTAssertNil(values["otp_code"])
            XCTAssertEqual(values["device_id"], "device-token")
        default:
            XCTFail("Unexpected account")
        }
        respond("{\"success\":true,\"data\":{\"sid\":\"test-session\",\"did\":\"issued-token\"}}")
    }
}

private final class RequiredOTPProtocol: LoginProtocol, @unchecked Sendable {
    override func startLoading() {
        let code = Int(parameters()["account"]!)!
        respond("{\"success\":false,\"error\":{\"code\":\(code)}}")
    }
}

/// Logs in, expires the first session on the next API call, then accepts the renewed one.
private final class RenewingProtocol: LoginProtocol, @unchecked Sendable {
    private struct State {
        var logins: [[String: String]] = []
        var rejectRenewal = false
        var offline = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset(rejectRenewal: Bool = false, offline: Bool = false) {
        state.withLock { $0 = State(rejectRenewal: rejectRenewal, offline: offline) }
    }
    static func setOffline(_ offline: Bool) { state.withLock { $0.offline = offline } }
    static func logins() -> [[String: String]] { state.withLock { $0.logins } }
    static let pngPixel = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    /// The successful reply of a renewed session, for each media endpoint.
    private func mediaResponse(_ form: [String: String]) -> (status: Int, headers: [String: String], body: Data)? {
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let png = ["Content-Type": "image/png"]
        if request.url!.path.hasSuffix("/Thumbnail/get") { return (200, png, Self.pngPixel) }
        if query["api"] == "SYNO.Personal.Profile.Photo" { return (200, png, Self.pngPixel) }
        if query["api"] == "SYNO.Foto.Streaming" || request.value(forHTTPHeaderField: "Range") != nil {
            return (206, ["Content-Type": "video/mp4", "Content-Range": "bytes 0-3/10", "Content-Length": "4"], Data([0, 1, 2, 3]))
        }
        if query["api"] == "SYNO.Foto.Download" { return (200, png, Self.pngPixel) }
        if form["api"] == "SYNO.Foto.Download" {
            return (200, ["Content-Type": "image/jpeg", "Content-Disposition": "attachment; filename=\"one.jpg\""], Data([0xFF, 0xD8, 0xFF]))
        }
        return nil
    }

    private func send(_ status: Int, _ headers: [String: String], _ body: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                              headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let values = parameters()
        if values["api"] == "SYNO.API.Auth" {
            let (count, reject) = Self.state.withLock { state -> (Int, Bool) in
                state.logins.append(values)
                return (state.logins.count, state.rejectRenewal)
            }
            if count > 1 && reject {
                respond("{\"success\":false,\"error\":{\"code\":403}}")
            } else {
                respond("{\"success\":true,\"data\":{\"sid\":\"session-\(count)\",\"did\":\"issued-token\"}}")
            }
        } else if Self.state.withLock({ $0.offline }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else if let media = mediaResponse(values) {
            // Media requests carry the session in the cookie; an expired one gets a JSON error body.
            guard request.value(forHTTPHeaderField: "Cookie") == "id=session-2" else {
                return send(200, ["Content-Type": "application/json; charset=\"UTF-8\""],
                            Data("{\"success\":false,\"error\":{\"code\":119}}".utf8))
            }
            send(media.status, media.headers, media.body)
        } else if values["_sid"] == "session-2" {
            respond("{\"success\":true,\"data\":{\"list\":[]}}")
        } else {
            respond("{\"success\":false,\"error\":{\"code\":119}}")
        }
    }
}
