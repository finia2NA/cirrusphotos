import Foundation
import XCTest
@testable import SynologyAPI

final class OwnedAlbumThumbnailTransportTests: XCTestCase {
    func testAlbumThumbnailIncludesAlbumID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnedThumbnailProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let items = try await client.albumItems(ids: [5], albumID: 69)
        XCTAssertEqual(items.map(\.id), [5])
        let result = try await client.albumThumbnail(.init(unitID: 9, cacheKey: "key"), size: .sm,
                                                     albumID: 69)
        XCTAssertFalse(result.isEmpty)
    }
}

private final class OwnedThumbnailProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let isThumbnail = request.url?.path == "/synofoto/api/v2/p/Thumbnail/get"
        let payload: Data
        if isThumbnail {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
            XCTAssertEqual(values["album_id"], "69")
            XCTAssertNil(values["passphrase"])
            payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
        } else if request.url?.path.hasSuffix("SYNO.Foto.Browse.Item") == true {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
            }
            let parts = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
            let values = Dictionary(parts.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
            XCTAssertEqual(values["album_id"], "69")
            XCTAssertEqual(values["id"], "[5]")
            XCTAssertEqual(values["method"], "get")
            payload = Data(#"{"success":true,"data":{"list":[{"id":5,"time":100,"type":"photo"}]}}"#.utf8)
        } else {
            payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: isThumbnail ? ["Content-Type": "image/png"] : nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
