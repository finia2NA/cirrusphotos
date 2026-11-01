import Foundation
import XCTest
@testable import SynologyAPI

final class PeopleTransportTests: XCTestCase {
    func testPeopleRequestsAndFaceThumbnail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PeopleFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let people = try await client.people()
        XCTAssertEqual(people.map(\.id), Array(1...101).map(Int64.init))
        let face = try XCTUnwrap(people.first?.thumbnail)
        XCTAssertEqual(face.unitID, 1)
        XCTAssertEqual(face.kind, "person")
        XCTAssertEqual(try JSONDecoder().decode(PersonSummary.self, from: JSONEncoder().encode(people[0])), people[0])
        let thumbnail = try await client.thumbnail(face, size: .m)
        XCTAssertNotNil(thumbnail.data)
        let collection = PhotoCollectionDescriptor.person(1)
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: collection.rawValue), collection)
        _ = try await client.collectionDayCatalog(collection: collection, initial: false)
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        _ = try await client.readCollectionBatch(.init(collection: collection, order: .timeline, newestDay: day, oldestDay: day, offset: 0, limit: 10), fields: .fullPage)
    }
}

private final class PeopleFixtureProtocol: URLProtocol, @unchecked Sendable {
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
            XCTAssertEqual(q["type"], #""person""#); XCTAssertNil(q["size"]); XCTAssertEqual(q["id"], "1")
            payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
        } else if path.hasSuffix("SYNO.Foto.Browse.Person") {
            XCTAssertEqual(values["show_more"], "true"); XCTAssertEqual(values["show_hidden"], "false")
            if values["method"] == "count" { payload = Data(#"{"success":true,"data":{"count":101}}"#.utf8) }
            else {
                let offset = Int(values["offset"] ?? "") ?? -1
                let range = offset == 0 ? 1...100 : 101...101
                let rows = range.map { "{\"id\":\($0),\"name\":\"Person\",\"item_count\":1,\"additional\":{\"thumbnail\":{\"cache_key\":\"face\"}}}" }.joined(separator: ",")
                payload = Data("{\"success\":true,\"data\":{\"list\":[\(rows)]}}".utf8)
            }
        } else if path.hasSuffix("SYNO.Foto.Browse.Timeline") {
            XCTAssertEqual(values["person_id"], "1")
            payload = Data(#"{"success":true,"data":{"section":[]}}"#.utf8)
        } else if path.hasSuffix("SYNO.Foto.Browse.Item") {
            XCTAssertEqual(values["person_id"], "1")
            payload = Data(#"{"success":true,"data":{"list":[]}}"#.utf8)
        } else { payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: path.hasSuffix("/Thumbnail/get") ? ["Content-Type": "image/png"] : nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
