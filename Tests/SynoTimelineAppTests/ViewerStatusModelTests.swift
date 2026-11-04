import XCTest
@testable import SynoTimelineApp

@MainActor
final class ViewerStatusModelTests: XCTestCase {
    private let loading = ViewerStatus(short: "Large · Loading 40%", help: "", progress: .determinate(0.4))
    private let waiting = ViewerStatus(short: "High · Loading", help: "", progress: .indeterminate)
    private let full = ViewerStatus(short: "Full", help: "", isComplete: true)

    func testVisibleLoadEndsWithCompletionThenHides() async {
        let model = ViewerStatusModel()
        model.update(loading, generation: 1)
        XCTAssertEqual(model.bar, .progress(.determinate(0.4)))
        model.update(full, generation: 1)
        XCTAssertEqual(model.bar, .completed)
        // Later updates for the same item do not cut the completion short.
        model.update(full, generation: 1)
        XCTAssertEqual(model.bar, .completed)
        let hidden = await waitUntil { model.bar == .hidden }
        XCTAssertTrue(hidden)
    }

    func testCompletionWithoutAVisibleBarShowsNothing() {
        let model = ViewerStatusModel()
        model.update(ViewerStatus(short: "Medium · Loading", help: ""), generation: 1)
        model.update(full, generation: 1)
        XCTAssertEqual(model.bar, .hidden)
    }

    func testNewItemDoesNotInheritTheBar() {
        let model = ViewerStatusModel()
        model.update(loading, generation: 1)
        model.update(full, generation: 2)
        XCTAssertEqual(model.bar, .hidden)
    }

    func testIndeterminateAppearsOnlyAfterTheDelay() async {
        let model = ViewerStatusModel()
        model.update(waiting, generation: 1)
        XCTAssertEqual(model.bar, .hidden)
        let shown = await waitUntil { model.bar == .progress(.indeterminate) }
        XCTAssertTrue(shown)
    }

    func testQuickIndeterminateWorkNeverShowsABar() async throws {
        let model = ViewerStatusModel()
        model.update(waiting, generation: 1)
        model.update(ViewerStatus(short: "High", help: "", isComplete: true), generation: 1)
        try await Task.sleep(for: ViewerStatusModel.indeterminateDelay + .milliseconds(100))
        XCTAssertEqual(model.bar, .hidden)
    }
}
