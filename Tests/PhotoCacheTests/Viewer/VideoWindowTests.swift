import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class VideoWindowTests: XCTestCase {
    func testLateSubscriberReceivesPrefixAndLastSubscriberCancelsWork() async throws {
        let stopped = expectation(description: "last subscriber cancels producer")
        let ready = expectation(description: "prefix published")
        let window = VideoWindow(range: 0...65535)
        let first = UUID(), second = UUID()
        await window.subscribe(first)
        await window.start { window in
            try await window.append(.header(VideoRangeHeader(range: 0...65535, totalLength: 65536,
                                                              contentType: "video/mp4", etag: nil, lastModified: nil)))
            try await window.append(.bytes(offset: 0, data: Data([1, 2, 3])))
            ready.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { stopped.fulfill(); throw error }
        }
        await fulfillment(of: [ready], timeout: 5)
        await window.subscribe(second)
        await window.unsubscribe(first)
        let prefix = try await window.read(from: 0)
        XCTAssertEqual(prefix?.data, Data([1, 2, 3]))
        await window.unsubscribe(second)
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testGateReleaseIsIdempotent() async throws {
        let gate = VideoTransferGate()
        let first = UUID(), second = UUID(), third = UUID()
        try await gate.acquire(first)
        try await gate.acquire(second)
        await gate.release(first)
        await gate.release(first)
        try await gate.acquire(third)
        await gate.release(second)
        await gate.release(third)
    }

    func testCancellationBeforeProducerStartsRejectsSubscribers() async throws {
        let window = VideoWindow(range: 0...65535)
        await window.cancel()
        let admitted = await window.subscribe(UUID())
        XCTAssertFalse(admitted)
        do { _ = try await window.read(from: 0); XCTFail("Cancelled window must not wait for data") }
        catch is CancellationError { }
    }
}
