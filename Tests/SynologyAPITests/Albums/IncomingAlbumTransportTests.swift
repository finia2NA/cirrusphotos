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

    func testLivePhotoMotionUsesTheRecipientUnitAndStreamingForms() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncomingAlbumProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let motion = try await client.incomingLivePhotoMotion(itemID: 5, ownerID: 1, albumID: 42, reference: "motion-reference")
        let resource = try XCTUnwrap(motion)
        XCTAssertEqual(resource.scope, .incomingAlbum(ownerID: 1, albumID: 42))
        XCTAssertEqual(resource.unitID, 99)
        XCTAssertEqual(resource.variant, .converted(.high))
        let received = IncomingVideoBytes()
        try await client.streamVideoRange(resource, range: 0...3, reference: "stream-reference") { event in
            if case .bytes(_, let data) = event { await received.append(data) }
        }
        let bytes = await received.data
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
    }

    func testVideoStreamsByItemIDWithTheRecipientForm() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncomingAlbumProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let resource = VideoPlaybackResource(scope: .incomingAlbum(ownerID: 1, albumID: 42), unitID: 99, cacheKey: "99_1",
                                             filename: "IMG.MOV", variant: .converted(.high), itemID: 5)
        let received = IncomingVideoBytes()
        try await client.streamVideoRange(resource, range: 0...3, reference: "video-reference") { event in
            if case .bytes(_, let data) = event { await received.append(data) }
        }
        let bytes = await received.data
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
    }

    func testIncomingVideoRequiresReferenceAndConvertedRendition() async throws {
        let client = SynologyClient(baseURL: URL(string: "https://example.invalid")!)
        let scope = PhotoContentScope.incomingAlbum(ownerID: 1, albumID: 42)
        let cases: [(VideoPlaybackResource, String?)] = [
            (VideoPlaybackResource(scope: scope, unitID: 99, cacheKey: "k", filename: nil, variant: .converted(.high)), nil),
            (VideoPlaybackResource(scope: scope, unitID: 99, cacheKey: "k", filename: nil, variant: .converted(.high)), ""),
            (VideoPlaybackResource(scope: scope, unitID: 99, cacheKey: "k", filename: nil, variant: .original), "reference"),
            (VideoPlaybackResource(scope: .space(.personal), unitID: 99, cacheKey: "k", filename: nil, variant: .converted(.high)), "reference"),
        ]
        for (resource, reference) in cases {
            do {
                try await client.streamVideoRange(resource, range: 0...3, reference: reference, receive: { _ in })
                XCTFail("Unsupported incoming video request must fail before sending")
            } catch SynologyAPIError.unsupported {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }
}

private actor IncomingVideoBytes {
    var data = Data()
    func append(_ value: Data) { data.append(value) }
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
        if request.httpMethod == "GET" {
            // The recipient streaming form observed in the web app.
            XCTAssertEqual(request.url?.path, "/webapi/entry.cgi")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
            XCTAssertEqual(values["api"], "SYNO.Foto.Streaming")
            XCTAssertEqual(values["version"], "2")
            XCTAssertEqual(values["method"], "streaming")
            if values["passphrase"] == #""video-reference""# {
                // A video streams by its item ID.
                XCTAssertEqual(values["id"], "5")
                XCTAssertEqual(values["type"], #""item""#)
            } else {
                // Live Photo motion streams by its unit ID.
                XCTAssertEqual(values["id"], "99")
                XCTAssertEqual(values["type"], #""unit""#)
                XCTAssertEqual(values["passphrase"], #""stream-reference""#)
            }
            XCTAssertEqual(values["quality"], #""high""#)
            XCTAssertNil(values["cache_key"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-3")
            let headers = ["Content-Type": "video/mp4", "Content-Range": "bytes 0-3/4"]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1, 2, 3, 4])); client?.urlProtocolDidFinishLoading(self)
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
        } else if values["api"] == "SYNO.Foto.Browse.Unit" {
            XCTAssertEqual(values["version"], "1")
            XCTAssertEqual(values["method"], "get")
            XCTAssertEqual(values["id_item"], "[5]")
            XCTAssertEqual(values["passphrase"], #""motion-reference""#)
            XCTAssertEqual(values["additional"], #"["orientation","resolution","thumbnail","video_meta","video_convert"]"#)
            json = #"{"success":true,"data":{"list":[{"id_item":5,"type":"live","unit":[{"live_type":"video","filename":"IMG.MOV","owner_user_id":1,"additional":{"thumbnail":{"unit_id":99,"cache_key":"99_1"},"video_convert":[{"quality":"high","metadata":{}}]}},{"live_type":"photo","filename":"IMG.HEIC","additional":{"thumbnail":{"unit_id":98,"cache_key":"98_1"}}}]}]}}"#
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
