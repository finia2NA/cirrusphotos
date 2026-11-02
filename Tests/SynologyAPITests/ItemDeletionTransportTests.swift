import Foundation
import XCTest
@testable import SynologyAPI

final class ItemDeletionTransportTests: XCTestCase {
    private func makeClient(_ script: DeletionScript) async throws -> (SynologyClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        DeletionProtocol.script = script
        configuration.protocolClasses = [DeletionProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        return (client, session)
    }

    func testSpacesSubmitToTheirOwnAPIAndShareTaskStatus() async throws {
        for space in PhotoSpace.allCases {
            let script = DeletionScript(statuses: ["waiting", "done"])
            let (client, session) = try await makeClient(script)
            defer { session.invalidateAndCancel() }
            try await client.deleteItems([5, 6], space: space)
            let calls = script.calls
            XCTAssertEqual(calls.first?["api"], space == .shared ? "SYNO.FotoTeam.BackgroundTask.File" : "SYNO.Foto.BackgroundTask.File")
            XCTAssertEqual(calls.first?["method"], "delete")
            XCTAssertEqual(calls.first?["version"], "1")
            XCTAssertEqual(calls.first?["item_id"], "[5,6]")
            XCTAssertEqual(calls.first?["folder_id"], "[]")
            let polls = calls.dropFirst()
            XCTAssertEqual(polls.count, 2)
            XCTAssertTrue(polls.allSatisfy { $0["api"] == "SYNO.Foto.BackgroundTask.Info" && $0["method"] == "get_status" && $0["id"] == "[22]" })
        }
    }

    func testTaskErrorIsReported() async throws {
        let script = DeletionScript(statuses: ["done"], taskError: 1)
        let (client, session) = try await makeClient(script)
        defer { session.invalidateAndCancel() }
        do {
            try await client.deleteItems([5], space: .personal)
            XCTFail("A task error must be reported")
        } catch SynologyAPIError.unsupported {}
    }
}

private final class DeletionScript: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []
    private var remaining: [String]
    let taskError: Int
    init(statuses: [String], taskError: Int = 0) { remaining = statuses; self.taskError = taskError }
    var calls: [[String: String]] { lock.withLock { recorded } }
    func respond(_ values: [String: String]) -> Data {
        lock.withLock {
            recorded.append(values)
            if values["method"] == "delete" {
                return Data(#"{"success":true,"data":{"task_info":{"id":22,"status":"waiting","error":0}}}"#.utf8)
            }
            let status = remaining.count > 1 ? remaining.removeFirst() : (remaining.first ?? "done")
            return Data(#"{"success":true,"data":{"list":[{"id":22,"status":"\#(status)","error":\#(taskError)}]}}"#.utf8)
        }
    }
}

private final class DeletionProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script = DeletionScript(statuses: [])
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
