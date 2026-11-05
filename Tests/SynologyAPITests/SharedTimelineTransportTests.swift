import Foundation
import XCTest
@testable import SynologyAPI

final class SharedTimelineTransportTests: XCTestCase {
    func testSharedTimelinePageDetailsAndThumbnailRoutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedTimelineProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let catalog = try await client.collectionDayCatalog(collection: .library(.shared), initial: false)
        let day = try XCTUnwrap(catalog.days.first?.day)
        let batch = try await client.readCollectionBatch(.init(collection: .library(.shared), order: .timeline,
            newestDay: day, oldestDay: day, offset: 0, limit: 1), fields: .fullPage)
        XCTAssertEqual(batch.items.first?.id, 5)
        let details = try await client.items(ids: [5], space: .shared)
        XCTAssertEqual(details.first?.id, 5)
        let thumbnail = try await client.thumbnail(.init(unitID: 9, cacheKey: "key"), size: .sm,
            space: .shared)
        XCTAssertFalse(thumbnail.isEmpty)
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: "shared"), .library(.shared))
    }
}

private final class SharedTimelineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let isThumbnail = request.url!.path.hasPrefix("/synofoto/")
        let parts = isThumbnail ? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)! : URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let payload: Data
        if isThumbnail {
            XCTAssertEqual(request.url!.path, "/synofoto/api/v2/t/Thumbnail/get")
            XCTAssertEqual(values["id"], "9")
            XCTAssertNil(values["album_id"])
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
            payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
        } else if values["api"] == "SYNO.API.Auth" {
            payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8)
        } else if values["api"] == "SYNO.FotoTeam.Browse.Timeline" {
            XCTAssertEqual(values["version"], "6")
            XCTAssertEqual(values["method"], "get")
            XCTAssertEqual(values["timeline_group_unit"], "\"day\"")
            payload = Data(#"{"success":true,"data":{"section":[{"offset":0,"limit":1,"list":[{"year":2024,"month":1,"day":1,"item_count":1}]}]}}"#.utf8)
        } else {
            XCTAssertEqual(values["api"], "SYNO.FotoTeam.Browse.Item")
            XCTAssertEqual(values["version"], "7")
            XCTAssertEqual(request.url!.path, "/webapi/entry.cgi/SYNO.FotoTeam.Browse.Item")
            if values["method"] == "list" {
                XCTAssertEqual(values["start_time"], "1704067200")
                XCTAssertEqual(values["end_time"], "1704153599")
            } else { XCTAssertEqual(values["method"], "get"); XCTAssertEqual(values["id"], "[5]") }
            payload = Data(#"{"success":true,"data":{"list":[{"id":5,"time":1704067200,"type":"photo"}]}}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: isThumbnail ? ["Content-Type": "image/png"] : nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
