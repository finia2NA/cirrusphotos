import Foundation
import XCTest
@testable import SynologyAPI

final class SharedCollectionsTransportTests: XCTestCase {
    func testSharedCollectionRoutesAndScopedArguments() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedCollectionsProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        _ = try await client.collectionIndex(.person, space: .shared)
        _ = try await client.collectionIndex(.subject, space: .shared)
        _ = try await client.collectionIndex(.tag, space: .shared)
        let root = try await client.folder(id: 0, space: .shared)
        XCTAssertEqual(root.id, 7)
        _ = try await client.folders(parentID: root.id, space: .shared)
        _ = try await client.readFolderCatalogBatch(folderID: root.id, offset: 0, limit: 1000, space: .shared)
        let day = try CaptureDay(year: 2024, month: 1, day: 1)
        for collection in [PhotoCollectionDescriptor.favorites(.shared), .person(7, space: .shared), .subject(7, space: .shared), .tag(7, space: .shared)] {
            XCTAssertEqual(PhotoCollectionDescriptor(rawValue: collection.rawValue), collection)
            _ = try await client.collectionDayCatalog(collection: collection, initial: false)
            _ = try await client.readCollectionBatch(.init(collection: collection, order: .timeline,
                newestDay: day, oldestDay: day, offset: 0, limit: 1), fields: .fullPage)
        }
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: "shared:folder:7"), .folder(7, space: .shared))
    }
}

private final class SharedCollectionsProtocol: URLProtocol, @unchecked Sendable {
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
        let query = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!.queryItems ?? []
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let api = values["api"] ?? ""
        let payload: String
        if api == "SYNO.API.Auth" { payload = #"{"success":true,"data":{"sid":"fixture"}}"# }
        else {
            XCTAssertTrue(api.hasPrefix("SYNO.FotoTeam.Browse."))
            XCTAssertEqual(request.url!.path, "/webapi/entry.cgi/" + api)
            if api.hasSuffix("Folder") {
                XCTAssertEqual(values["version"], "2")
                if values["method"] == "get" {
                    XCTAssertEqual(values["id"], "0")
                    payload = #"{"success":true,"data":{"folder":{"id":7,"name":"root","parent":0}}}"#
                } else { XCTAssertEqual(values["id"], "7"); payload = #"{"success":true,"data":{"list":[]}}"# }
            } else if api.hasSuffix("Timeline") {
                XCTAssertTrue(values["favorite_only"] == "true" || values["person_id"] == "7" || values["concept_id"] == "7" || values["general_tag_id"] == "7")
                payload = #"{"success":true,"data":{"section":[]}}"#
            } else if api.hasSuffix("Item") {
                XCTAssertTrue(values["folder_id"] == "7" || values["favorite_only"] == "true" || values["person_id"] == "7" || values["concept_id"] == "7" || values["general_tag_id"] == "7")
                payload = #"{"success":true,"data":{"list":[]}}"#
            } else if values["method"] == "count" { payload = #"{"success":true,"data":{"count":0}}"# }
            else { payload = #"{"success":true,"data":{"list":[]}}"# }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
