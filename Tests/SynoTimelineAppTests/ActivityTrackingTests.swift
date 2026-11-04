import Foundation
import XCTest
@testable import SynoTimelineApp

@MainActor
final class ActivityTrackingTests: XCTestCase {
    @MainActor private final class Log { var entries: [String] = [] }

    func testAlbumWritesRunOneAtATimeAndStayQueuedUntilTheirTurn() async {
        let activity = ActivityCenter()
        let model = LibraryModel(activity: activity)
        let log = Log()
        let first = activity.begin(.deleteAlbum(name: "A"), queued: true)
        let second = activity.begin(.deleteAlbum(name: "B"), queued: true)
        model.enqueueAlbumWrite(first) {
            log.entries.append("A")
            try? await Task.sleep(for: .milliseconds(50))
            log.entries.append("A done")
            first.succeed()
        }
        model.enqueueAlbumWrite(second) {
            log.entries.append("B")
            second.succeed()
        }
        let started = await waitUntil { log.entries == ["A"] }
        XCTAssertTrue(started)
        XCTAssertEqual(activity.inProgress.first { $0.id == first.id }?.phase, .running)
        XCTAssertEqual(activity.inProgress.first { $0.id == second.id }?.phase, .queued)

        let finished = await waitUntil { log.entries.count == 3 }
        XCTAssertTrue(finished)
        XCTAssertEqual(log.entries, ["A", "A done", "B"])
        XCTAssertEqual(activity.history.map(\.title), ["Deleted album B", "Deleted album A"])
    }

    func testFailedWriteDoesNotBlockTheQueue() async throws {
        let model = LibraryModel(activity: ActivityCenter())
        do {
            _ = try await model.serializedAlbumWrite { () async throws -> Int in throw URLError(.notConnectedToInternet) }
            XCTFail("Expected the write to fail")
        } catch {}
        let value = try await model.serializedAlbumWrite { 7 }
        XCTAssertEqual(value, 7)
    }

    func testUnverifiedSelectionIsReportedAsFailure() {
        let activity = ActivityCenter()
        let model = LibraryModel(activity: activity)
        model.reportUnverified("Rotate")
        XCTAssertEqual(activity.attention.first?.title, "Rotate failed")
        XCTAssertEqual(activity.attention.first?.detail, "The selected photos could not be verified. Try again.")
        XCTAssertNil(activity.attention.first?.retry)
    }
}
