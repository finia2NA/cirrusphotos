import Foundation
import XCTest
@testable import SynologyAPI

final class VideoStreamingTransportTests: XCTestCase {
    func testRejectsInvalidResponsesAndTruncatedBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InvalidVideoProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        let resource = VideoPlaybackResource(scope: .space(.personal), unitID: 1, cacheKey: "r", filename: nil, variant: .original)
        for scenario in 0...4 {
            InvalidVideoProtocol.scenario = scenario
            do {
                try await client.streamVideoRange(resource, range: 0...3, receive: { _ in })
                XCTFail("Invalid response scenario \(scenario) must fail")
            } catch { }
        }
    }

    func testFirstBytesArriveBeforeResponseCompletes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedVideoProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        let signal = expectation(description: "first streamed body")
        let resource = VideoPlaybackResource(scope: .space(.personal), unitID: 1, cacheKey: "r", filename: nil, variant: .original)
        let task = Task {
            try await client.streamVideoRange(resource, range: 0...32767) { event in
                if case .bytes(let offset, _) = event, offset == 0 { signal.fulfill() }
            }
        }
        await fulfillment(of: [signal], timeout: 5)
        DelayedVideoProtocol.resume.signal()
        try await task.value
    }

    func testCancellationStopsUnderlyingRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedVideoProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        let first = expectation(description: "first streamed body")
        let stopped = expectation(description: "URLSession stopped the request")
        DelayedVideoProtocol.stopped = stopped
        defer { DelayedVideoProtocol.stopped = nil; DelayedVideoProtocol.resume.signal() }
        let resource = VideoPlaybackResource(scope: .space(.personal), unitID: 1, cacheKey: "r", filename: nil, variant: .original)
        let task = Task {
            try await client.streamVideoRange(resource, range: 0...32767) { event in
                if case .bytes(let offset, _) = event, offset == 0 { first.fulfill() }
            }
        }
        await fulfillment(of: [first], timeout: 5)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        do { try await task.value; XCTFail("Cancellation must stop the transfer") } catch { }
    }
}

private final class InvalidVideoProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scenario = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if request.httpMethod == "POST" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8))
        } else {
            var headers = ["Content-Type": "video/mp4", "Content-Range": "bytes 0-3/4"]
            if Self.scenario == 1 { headers["Content-Range"] = "bytes 1-3/4" }
            if Self.scenario == 2 { headers["Content-Type"] = "application/json" }
            if Self.scenario == 3 { headers["Content-Length"] = "3" }
            let status = Self.scenario == 0 ? 200 : 206
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: Self.scenario == 4 ? 3 : 4))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DelayedVideoProtocol: URLProtocol, @unchecked Sendable {
    static let resume = DispatchSemaphore(value: 0)
    nonisolated(unsafe) static var stopped: XCTestExpectation?
    private let stateLock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
        Self.stopped?.fulfill()
    }
    override func startLoading() {
        if request.httpMethod == "POST" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let headers = ["Content-Type": "video/mp4", "Content-Range": "bytes 0-32767/32768", "Content-Length": "32768"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 16384))
        DispatchQueue.global().async { [self] in
            Self.resume.wait()
            stateLock.lock(); let isCancelled = cancelled; stateLock.unlock()
            guard !isCancelled else { return }
            client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 16384))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
