import Foundation
import XCTest
@testable import SynologyAPI

final class MixedAlbumTransportTests: XCTestCase {
    func testOwnedAlbumKeepsContextForSharedThumbnailDetailsAndOriginal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MixedAlbumProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        let items = try await client.albumItems(ids: [5], albumID: 3)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.ownerUserID, 0)
        let thumbnail = try XCTUnwrap(item.additional?.thumbnail)
        let response = try await client.albumThumbnail(thumbnail, size: .xl, albumID: 3)
        XCTAssertFalse(response.isEmpty)
        let still = try await client.fullImage(try XCTUnwrap(item.fullImageResource(in: .album(3))))
        XCTAssertNotNil(still.data)
    }
}

private final class MixedAlbumProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n))
            }
        }
        let components = request.httpMethod == "GET" ? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)! : URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        var payload: Data
        var headers = ["Content-Type": "application/json"]
        if values["api"] == "SYNO.API.Auth" {
            payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8)
        } else {
            XCTAssertEqual(values["album_id"], "3")
            if values["api"] == "SYNO.Foto.Browse.Item" {
                XCTAssertEqual(values["id"], "[5]")
                payload = Data(#"{"success":true,"data":{"list":[{"id":5,"owner_user_id":0,"time":1704067200,"type":"photo","additional":{"thumbnail":{"unit_id":9,"cache_key":"revision","xl":"ready"}}}]}}"#.utf8)
            } else if request.url!.path == "/synofoto/api/v2/p/Thumbnail/get" {
                payload = Data(#"{"success":false,"error":{"code":100}}"#.utf8)
            } else {
                if request.url!.path == "/synofoto/api/v2/t/Thumbnail/get" {
                    XCTAssertEqual(values["id"], "9")
                    XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
                } else {
                    XCTAssertEqual(values["api"], "SYNO.Foto.Download")
                    XCTAssertEqual(values["unit_id"], "[9]")
                    XCTAssertNil(values["item_id"])
                }
                headers = ["Content-Type": "image/png"]
                payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
