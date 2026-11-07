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
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset(rejectRenewal: Bool = false) {
        state.withLock { $0 = State(rejectRenewal: rejectRenewal) }
    }
    static func logins() -> [[String: String]] { state.withLock { $0.logins } }

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
        } else if values["_sid"] == "session-2" {
            respond("{\"success\":true,\"data\":{\"list\":[]}}")
        } else {
            respond("{\"success\":false,\"error\":{\"code\":119}}")
        }
    }
}
