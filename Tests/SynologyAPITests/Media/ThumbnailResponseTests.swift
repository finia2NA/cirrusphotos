import Foundation
import XCTest
@testable import SynologyAPI

final class ThumbnailResponseTests: XCTestCase {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!

    private func thumbnail(body: Data, contentType: String) async throws -> Data {
        ThumbnailResponseProtocol.response = (body, contentType)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThumbnailResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        return try await client.thumbnail(.init(unitID: 9, cacheKey: "9_1"), size: .m, space: .personal)
    }

    /// Observed for a WebP: every size is the original, labelled as generic binary data.
    func testADecodableImageIsAcceptedWhateverItsContentType() async throws {
        let data = try await thumbnail(body: Self.png, contentType: "application/octet-stream")
        XCTAssertEqual(data, Self.png)
    }

    func testUndecodableBytesAreRejected() async {
        do {
            _ = try await thumbnail(body: Data(), contentType: "image/jpeg")
            XCTFail("An empty thumbnail was accepted")
        } catch {
            XCTAssertEqual(error as? SynologyAPIError, .invalidResponse)
        }
    }
}

private final class ThumbnailResponseProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Data, String) = (Data(), "")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let isThumbnail = request.url?.path == "/synofoto/api/v2/p/Thumbnail/get"
        let payload = isThumbnail ? Self.response.0 : Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8)
        let headers = ["Content-Type": isThumbnail ? Self.response.1 : "application/json"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
