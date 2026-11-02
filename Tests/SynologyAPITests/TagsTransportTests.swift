import Foundation
import XCTest
@testable import SynologyAPI

final class TagsTransportTests: XCTestCase {
    func testTagsRequestsAndCoverThumbnail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TagsFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let tags = try await client.collectionIndex(.tag, space: .personal)
        XCTAssertEqual(tags.map(\.id), Array(1...101).map(Int64.init))
        let cover = try XCTUnwrap(tags.first?.thumbnail)
        XCTAssertEqual(cover.unitID, 1)
        XCTAssertNil(cover.kind)
        XCTAssertEqual(try CollectionIndexEntry.decoder(for: .tag).decode(CollectionIndexEntry.self, from: JSONEncoder().encode(tags[0])), tags[0])
        let thumbnail = try await client.thumbnail(cover, size: .m, space: .personal, etag: nil, lastModified: nil)
        XCTAssertNotNil(thumbnail.data)
        let collection = PhotoCollectionDescriptor.tag(1, space: .personal)
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: collection.rawValue), collection)
        _ = try await client.collectionDayCatalog(collection: collection, initial: false)
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        _ = try await client.readCollectionBatch(.init(collection: collection, order: .timeline, newestDay: day, oldestDay: day, offset: 0, limit: 10), fields: .fullPage)
    }
}

private final class TagsFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        let query = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let path = request.url!.path
        let payload: Data
        if path.hasSuffix("/Thumbnail/get") {
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let q = Dictionary(parts.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
            XCTAssertEqual(q["type"], #""unit""#); XCTAssertEqual(q["size"], #""m""#); XCTAssertEqual(q["id"], "1")
            payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
        } else if path.hasSuffix("SYNO.Foto.Browse.GeneralTag") {
            XCTAssertNil(values["show_more"]); XCTAssertNil(values["show_hidden"]); XCTAssertEqual(values["version"], "2")
            if values["method"] == "count" { payload = Data(#"{"success":true,"data":{"count":101}}"#.utf8) }
            else {
                let offset = Int(values["offset"] ?? "") ?? -1
                let range = offset == 0 ? 1...100 : 101...101
                let rows = range.map { "{\"id\":\($0),\"name\":\"Tag\",\"item_count\":1,\"additional\":{\"thumbnail\":{\"unit_id\":\($0),\"cache_key\":\"face\",\"m\":\"ready\"}}}" }.joined(separator: ",")
                payload = Data("{\"success\":true,\"data\":{\"list\":[\(rows)]}}".utf8)
            }
        } else if path.hasSuffix("SYNO.Foto.Browse.Timeline") {
            XCTAssertEqual(values["general_tag_id"], "1")
            payload = Data(#"{"success":true,"data":{"section":[]}}"#.utf8)
        } else if path.hasSuffix("SYNO.Foto.Browse.Item") {
            XCTAssertEqual(values["general_tag_id"], "1")
            payload = Data(#"{"success":true,"data":{"list":[]}}"#.utf8)
        } else { payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: path.hasSuffix("/Thumbnail/get") ? ["Content-Type": "image/png"] : nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
