import Foundation
import XCTest
@testable import SynologyAPI

final class FolderThumbnailTransportTests: XCTestCase {
    func testPersonalAndSharedCustomCoversUseFolderIdentityWithoutSize() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FolderThumbnailProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "unused"))
        for space in PhotoSpace.allCases {
            let bytes = try await client.folderThumbnail(folderID: 950, cacheKey: "revision", sequence: 0, space: space)
            XCTAssertTrue(PhotoDownloadValidation.containsImage(bytes))
        }
    }

    func testCustomCoverRejectsInvalidIdentityBeforeNetwork() async throws {
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!)
        do {
            _ = try await client.folderThumbnail(folderID: 0, cacheKey: "revision", sequence: 0, space: .shared)
            XCTFail("Invalid folder identity must fail")
        } catch SynologyAPIError.invalidResponse {}
    }
}

private final class FolderThumbnailProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        let image = path.hasSuffix("/Thumbnail/get")
        let payload: Data
        if image {
            XCTAssertTrue(["/synofoto/api/v2/p/Thumbnail/get", "/synofoto/api/v2/t/Thumbnail/get"].contains(path))
            let values = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
                ($0.name, $0.value ?? "")
            }, uniquingKeysWith: { _, last in last })
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(values["id"], "950")
            XCTAssertEqual(values["type"], #""folder""#)
            XCTAssertEqual(values["cache_key"], #""revision""#)
            XCTAssertEqual(values["folder_cover_seq"], "0")
            XCTAssertNil(values["size"])
            XCTAssertNil(values["album_id"])
            XCTAssertNil(values["passphrase"])
            XCTAssertEqual(values["_sid"], "fixture")
            payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
        } else {
            payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: image ? ["Content-Type": "image/png"] : nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
