import Foundation
import XCTest
@testable import SynologyAPI

final class LoginTests: XCTestCase {
    func testMissingAndBlankOTPAllowCredentials() throws {
        for suffix in ["", "OTP=\n", "OTP='   '\n"] {
            let credentials = try CredentialStore.credentials(from: Data("USER=phototest\nPW=test-password\n\(suffix)".utf8))
            XCTAssertNil(credentials.otpSecret)
        }
        XCTAssertThrowsError(try CredentialStore.credentials(from: Data("USER=phototest\n".utf8)))
    }

    func testLoginWithoutOTPAndWithConfiguredOTP() async throws {
        for secret: String? in [nil, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SuccessfulLoginProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
            try await client.login(credentials: .init(username: secret == nil ? "without-otp" : "with-otp", password: "test-password", otpSecret: secret))
        }
    }

    func testRequiredOTPReportsConfigurationErrorWithoutRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequiredOTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for code in [403, 404, 406] {
            let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
            do {
                try await client.login(credentials: .init(username: String(code), password: "test-password"))
                XCTFail("Expected OTP requirement")
            } catch SynologyAPIError.configuration(let message) {
                XCTAssertTrue(message.contains("Set OTP"))
            }
        }
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
        if values["account"] == "without-otp" {
            XCTAssertNil(values["otp_code"])
        } else {
            XCTAssertEqual(values["otp_code"]?.count, 6)
        }
        respond("{\"success\":true,\"data\":{\"sid\":\"test-session\"}}")
    }
}

private final class RequiredOTPProtocol: LoginProtocol, @unchecked Sendable {
    override func startLoading() {
        XCTAssertNil(parameters()["otp_code"])
        let code = Int(parameters()["account"]!)!
        respond("{\"success\":false,\"error\":{\"code\":\(code)}}")
    }
}
