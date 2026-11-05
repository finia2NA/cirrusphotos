import Foundation
import XCTest
@testable import SynologyAPI

final class IncomingAlbumTransportTests: XCTestCase {
    func testIncomingListCarriesReferenceAndRecipientPermissions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncomingAlbumProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let albums = try await client.incomingAlbums()
        XCTAssertEqual(albums.map(\.summary.id), [42, 43])
        XCTAssertTrue(albums[0].access.upload)
        XCTAssertFalse(albums[1].access.upload)
        XCTAssertEqual(albums[0].sharingReference, "fixture-reference")
    }

    func testScopedItemAndThumbnailRequestsCarryTheirOwnReference() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncomingAlbumProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let items = try await client.incomingItems(ids: [5], reference: "item-reference")
        XCTAssertEqual(items.map(\.id), [5])
        let image = try await client.incomingThumbnail(ThumbnailInfo(unitID: 9, cacheKey: "key"), size: .xl,
                                                       reference: "image-reference")
        XCTAssertFalse(image.isEmpty)
    }
}

private final class IncomingAlbumProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if request.url?.path == "/synofoto/api/v2/p/Thumbnail/get" {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
            XCTAssertEqual(values["passphrase"], #""image-reference""#)
            XCTAssertEqual(values["size"], #""xl""#)
            let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: image); client?.urlProtocolDidFinishLoading(self)
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        let parts = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary(parts.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let json: String
        if values["method"] == "login" {
            json = #"{"success":true,"data":{"sid":"fixture"}}"#
        } else if values["api"] == "SYNO.Foto.Browse.Item" {
            XCTAssertEqual(values["method"], "get")
            XCTAssertEqual(values["id"], "[5]")
            XCTAssertEqual(values["passphrase"], #""item-reference""#)
            json = #"{"success":true,"data":{"list":[{"id":5,"time":100,"type":"photo"}]}}"#
        } else {
            XCTAssertEqual(values["api"], "SYNO.Foto.Sharing.Misc")
            XCTAssertEqual(values["version"], "2")
            XCTAssertEqual(values["method"], "list_shared_with_me_album")
            XCTAssertEqual(values["additional"], #"["sharing_info","thumbnail","access_permission"]"#)
            XCTAssertEqual(values["offset"], "0")
            XCTAssertEqual(values["limit"], "50")
            json = #"{"success":true,"data":{"list":[{"id":42,"name":"Provider","item_count":1,"passphrase":"fixture-reference","additional":{"access_permission":{"view":true,"download":true,"upload":true,"manage":false,"own":false}}},{"id":43,"name":"Viewer","item_count":1,"passphrase":"fixture-reference-2","additional":{"access_permission":{"view":true,"upload":false}}}]}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
