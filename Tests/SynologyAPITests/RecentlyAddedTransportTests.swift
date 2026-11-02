import Foundation
import XCTest
@testable import SynologyAPI

final class RecentlyAddedTransportTests: XCTestCase {
    func testRecentlyAddedUsesItsOwnTimelineAndIndexDayBounds() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecentFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let collection = PhotoCollectionDescriptor.recentlyAdded
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: collection.rawValue), collection)
        let catalog = try await client.collectionDayCatalog(collection: collection, initial: false)
        let day = try CaptureDay(year: 2026, month: 11, day: 2)
        XCTAssertEqual(catalog.days.first?.day, day)
        let batch = try await client.readCollectionBatch(.init(collection: collection, order: .timeline, newestDay: day, oldestDay: day, offset: 0, limit: 1), fields: .fullPage)
        XCTAssertEqual(batch.items.first?.time, 1577836800)
        XCTAssertEqual(batch.items.first?.indexedTime, 1793577600123)
    }
}

private final class RecentFixtureProtocol: URLProtocol, @unchecked Sendable {
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
        let payload: String
        if request.url!.path.hasSuffix("SYNO.Foto.Browse.RecentlyAdded") {
            XCTAssertEqual(values["api"], "SYNO.Foto.Browse.RecentlyAdded")
            XCTAssertEqual(values["version"], "6")
            if values["method"] == "get_timeline" {
                payload = #"{"success":true,"data":{"section":[{"offset":0,"limit":1,"list":[{"year":2026,"month":11,"day":2,"item_count":1}]}]}}"#
            } else {
                XCTAssertEqual(values["method"], "list")
                XCTAssertEqual(values["start_time"], "1793577600")
                XCTAssertEqual(values["end_time"], "1793663999")
                payload = #"{"success":true,"data":{"list":[{"id":1,"time":1577836800,"indexed_time":1793577600123,"type":"photo"}]}}"#
            }
        } else { payload = #"{"success":true,"data":{"sid":"fixture"}}"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
