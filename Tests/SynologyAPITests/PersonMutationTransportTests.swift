import Foundation
import XCTest
@testable import SynologyAPI

final class PersonMutationTransportTests: XCTestCase {
    func testScopedSuggestionRenameAndMergeRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonMutationFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        for space in PhotoSpace.allCases {
            let suggestions = try await client.suggestPeople(prefix: "Ali", space: space)
            XCTAssertEqual(suggestions.first?.thumbnail?.kind, "person")
            let renamed = try await client.renamePerson(id: 1, name: "Alice", space: space)
            let merged = try await client.mergePerson(sourceID: 2, targetID: 1, name: "Alice", space: space)
            XCTAssertEqual(renamed.name, "Alice")
            XCTAssertEqual(merged.id, 1)
        }
    }
}

private final class PersonMutationFixtureProtocol: URLProtocol, @unchecked Sendable {
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
        let items = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let payload: String
        if request.url!.path.hasSuffix(".Browse.Person") {
            XCTAssertTrue(["SYNO.Foto.Browse.Person", "SYNO.FotoTeam.Browse.Person"].contains(values["api"] ?? ""))
            let person = #"{"id":1,"name":"Alice","item_count":3,"additional":{"thumbnail":{"cache_key":"face"}}}"#
            switch values["method"] {
            case "suggest":
                XCTAssertEqual(values["version"], "3"); XCTAssertEqual(values["name_prefix"], "Ali")
                XCTAssertEqual(values["limit"], "10"); XCTAssertEqual(values["additional"], #"["thumbnail"]"#)
                payload = "{\"success\":true,\"data\":{\"list\":[\(person)]}}"
            case "set":
                XCTAssertEqual(values["version"], "1"); XCTAssertEqual(values["id"], "1"); XCTAssertEqual(values["name"], #""Alice""#)
                payload = "{\"success\":true,\"data\":\(person)}"
            case "merge":
                XCTAssertEqual(values["version"], "2"); XCTAssertEqual(values["target_id"], "1")
                XCTAssertEqual(values["merged_id"], "[2]"); XCTAssertEqual(values["name"], #""Alice""#)
                payload = "{\"success\":true,\"data\":\(person)}"
            default: XCTFail("Unexpected Person method"); payload = #"{"success":false}"#
            }
        } else { payload = #"{"success":true,"data":{"sid":"fixture"}}"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
