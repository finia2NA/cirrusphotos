import Foundation
import XCTest
@testable import SynologyAPI

/// Request shapes and responses observed in `docs/captures/tagsandratings.har` and on the
/// disposable account.
final class AnnotationTransportTests: XCTestCase {
    private func makeClient(_ script: AnnotationScript) async throws -> (SynologyClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        AnnotationProtocol.script = script
        configuration.protocolClasses = [AnnotationProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        return (client, session)
    }

    func testRatingAndTagWritesUseTheirSpaceAPIAndObservedParameters() async throws {
        for space in PhotoSpace.allCases {
            let script = AnnotationScript()
            let (client, session) = try await makeClient(script)
            defer { session.invalidateAndCancel() }
            let api = space == .shared ? "SYNO.FotoTeam.Browse.Item" : "SYNO.Foto.Browse.Item"
            try await client.setRating(itemIDs: [4, 5], rating: 5, space: space)
            try await client.addTags([41], toItems: [4, 5], space: space)
            try await client.removeTags([41, 42], fromItems: [4], space: space)
            let calls = script.calls
            XCTAssertEqual(calls.map { $0["method"] }, ["set", "add_tag", "remove_tag"])
            XCTAssertTrue(calls.allSatisfy { $0["api"] == api && $0["version"] == "7" })
            XCTAssertEqual(calls[0]["id"], "[4,5]")
            XCTAssertEqual(calls[0]["rating"], "5")
            XCTAssertEqual(calls[1]["tag"], "[41]")
            XCTAssertEqual(calls[2]["id"], "[4]")
            XCTAssertEqual(calls[2]["tag"], "[41,42]")
        }
    }

    func testCreateTagQuotesNameAndDecodesTag() async throws {
        let script = AnnotationScript()
        let (client, session) = try await makeClient(script)
        defer { session.invalidateAndCancel() }
        let tag = try await client.createTag(name: "Summer \"24", space: .shared)
        XCTAssertEqual(tag, PhotoTag(id: 41, name: "testtag"))
        let call = try XCTUnwrap(script.calls.first)
        XCTAssertEqual(call["api"], "SYNO.FotoTeam.Browse.GeneralTag")
        XCTAssertEqual(call["version"], "2")
        XCTAssertEqual(call["name"], #""Summer \"24""#)
    }

    func testNonEmptyErrorListIsAFailureWhetherEntriesAreIDsOrObjects() async throws {
        for body in [#"{"success":true,"data":{"error_list":[284555,284553]}}"#,
                     #"{"success":true,"data":{"error_list":[{"id":1,"code":120}]}}"#] {
            let script = AnnotationScript(response: body)
            let (client, session) = try await makeClient(script)
            defer { session.invalidateAndCancel() }
            do {
                try await client.addTags([999], toItems: [1], space: .personal)
                XCTFail("A non-empty error_list must be reported")
            } catch SynologyAPIError.invalidResponse {}
        }
    }

    func testRatingOutsideRangeIsRejectedBeforeSending() async throws {
        let script = AnnotationScript()
        let (client, session) = try await makeClient(script)
        defer { session.invalidateAndCancel() }
        do {
            try await client.setRating(itemIDs: [1], rating: 6, space: .personal)
            XCTFail("Ratings above five stars are invalid")
        } catch SynologyAPIError.invalidResponse {}
        XCTAssertTrue(script.calls.isEmpty)
    }

    func testAPIErrorCodeIsPropagated() async throws {
        let script = AnnotationScript(response: #"{"success":false,"error":{"code":120}}"#)
        let (client, session) = try await makeClient(script)
        defer { session.invalidateAndCancel() }
        do {
            try await client.setRating(itemIDs: [1], rating: 3, space: .personal)
            XCTFail("An API error must be reported")
        } catch SynologyAPIError.api(let code) {
            XCTAssertEqual(code, 120)
        }
    }
}

private final class AnnotationScript: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []
    let response: String?
    init(response: String? = nil) { self.response = response }
    var calls: [[String: String]] { lock.withLock { recorded } }
    func respond(_ values: [String: String]) -> Data {
        lock.withLock {
            recorded.append(values)
            if let response { return Data(response.utf8) }
            if values["method"] == "create" {
                return Data(#"{"success":true,"data":{"tag":{"id":41,"name":"testtag"}}}"#.utf8)
            }
            return Data(#"{"success":true,"data":{"error_list":[]}}"#.utf8)
        }
    }
}

private final class AnnotationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script = AnnotationScript()
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
        let components = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let payload = values["api"] == "SYNO.API.Auth"
            ? Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8)
            : Self.script.respond(values)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
}
