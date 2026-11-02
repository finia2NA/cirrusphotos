import Foundation
import XCTest
@testable import SynologyAPI

final class ProgressiveDataTransferTests: XCTestCase {
    func testDataDelegateAccumulatesDeliveredDataAndReportsCompletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedImageURLProtocol.self]
        let recorder = TransferProgressRecorder()
        let transfer = ProgressiveDataTransfer(
            allowedHost: "example.test", configuration: configuration,
            progress: { recorder.append($0) }
        )

        let (data, response) = try await transfer.data(
            for: URLRequest(url: URL(string: "https://example.test/original")!)
        )

        XCTAssertEqual(data, Data("abcdefghijkl".utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(recorder.snapshot().last?.completedBytes, 12)
        XCTAssertEqual(recorder.snapshot().last?.totalBytes, 12)
    }

    func testLiveSlowOriginalReportsIncrementalChunksWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SYNOLOGY_TEST=1 to test the Cirrus transfer delegate.")
        }
        let client = SynologyClient()
        try await client.login(credentials: CredentialStore.load())
        let items = try await client.items(ids: [239363], space: .personal)
        let item = try XCTUnwrap(items.first)
        let resource = try XCTUnwrap(item.fullImageResource(in: .space(.personal)))
        let recorder = TransferProgressRecorder()

        let response = try await client.fullImage(
            resource, etag: nil, lastModified: nil,
            progress: { recorder.append($0) }
        )

        XCTAssertEqual(response.data?.count, Int(item.filesize ?? -1))
        let updates = recorder.snapshot()
        XCTAssertGreaterThan(updates.count, 2)
        XCTAssertEqual(updates.last?.completedBytes, item.filesize)
        XCTAssertEqual(updates.last?.totalBytes, item.filesize)
    }
}

private final class TransferProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgress] = []

    func append(_ value: TransferProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [TransferProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ChunkedImageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg", "Content-Length": "12"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(["abcd", "efgh", "ijkl"], at: 0)
    }

    override func stopLoading() {}

    private func deliver(_ chunks: [String], at index: Int) {
        guard index < chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: Data(chunks[index].utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            self.deliver(chunks, at: index + 1)
        }
    }
}
