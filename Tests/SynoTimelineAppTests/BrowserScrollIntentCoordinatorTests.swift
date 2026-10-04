import Foundation
@testable import PhotoCache
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

final class BrowserScrollIntentCoordinatorTests: XCTestCase {
    private func index(day: Int = 3, pages: Int = 1) -> LibraryIndex {
        LibraryIndex(snapshot: TimelineSnapshot(sections: (0..<pages).map {
            TimelineSection(offset: $0 * 2, limit: 2,
                list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: pages * 2)])
        }))
    }

    private func saved(dayID: String = "2024-04-03", hint: Int? = nil) -> PhotoTimelineRestorationAnchor {
        PhotoTimelineRestorationAnchor(itemID: 42, dayID: dayID, sectionOffsetHint: hint,
                                       localOffset: 17, sectionFraction: 0.2)
    }

    private func page(section: Int = 0, verified: Bool, itemID: Int64 = 42) throws -> LibraryPage {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
            {"id":\(itemID),"time":1712102400,"type":"photo",
             "additional":{"resolution":{"width":100,"height":100}}}
            """.utf8))
        return LibraryPage(sectionIndex: section, items: [item], verified: verified)
    }

    @discardableResult
    private func rebuild(_ state: inout BrowserScrollIntentCoordinator, index: LibraryIndex,
                         verified: Bool = false) -> LibraryViewportGeometry {
        let geometry = LibraryViewportGeometry(index: index, width: 500)
        _ = state.rebuild(index: index, geometry: geometry, previousIndex: nil,
                          visibleAnchor: nil, timelineVerified: verified)
        return geometry
    }

    func testExplicitNavigationSupersedesRestorationAndRepeatedJumpDoesNotReplay() {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        state.captureRestoration(saved())
        let geometry = rebuild(&state, index: index)
        let jumpID = UUID()
        XCTAssertNotNil(state.jump(id: jumpID, dayID: "2024-04-03", index: index, geometry: geometry))
        XCTAssertTrue(state.canPersistViewport)
        state.captureRestoration(saved())
        XCTAssertNil(state.restoration, "Subsequent SwiftUI inputs must not restore again")

        let reveal = BrowserRevealRequest(itemID: 7, dayID: "2024-04-03", sectionOffsetHint: nil)
        _ = state.reveal(reveal, index: index, geometry: geometry)
        XCTAssertNil(state.jump(id: jumpID, dayID: "2024-04-03", index: index, geometry: geometry))
        XCTAssertEqual(state.revealID, reveal.id)
        XCTAssertNotNil(state.jump(id: UUID(), dayID: "2024-04-03", index: index, geometry: geometry))
        XCTAssertNil(state.revealID)
        XCTAssertFalse(state.finishReveal(id: reveal.id))
    }

    func testRevealSupersedesRestorationAndRejectsStaleDeferredCompletion() {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        state.captureRestoration(saved())
        let geometry = rebuild(&state, index: index)
        let first = BrowserRevealRequest(itemID: 1, dayID: "2024-04-03", sectionOffsetHint: nil)
        let second = BrowserRevealRequest(itemID: 2, dayID: "2024-04-03", sectionOffsetHint: nil)
        _ = state.reveal(first, index: index, geometry: geometry)
        state.revealPositioned(id: first.id)
        XCTAssertNil(state.anchor)
        XCTAssertFalse(state.canPersistViewport)
        _ = state.reveal(second, index: index, geometry: geometry)
        XCTAssertNil(state.restoration)
        state.revealPositioned(id: first.id)
        XCTAssertEqual(state.anchor?.itemID, 2)
        XCTAssertFalse(state.finishReveal(id: first.id))
        XCTAssertEqual(state.revealID, second.id)
        XCTAssertTrue(state.finishReveal(id: second.id))
        XCTAssertFalse(state.finishReveal(id: second.id), "Completion is consumed once")
        XCTAssertTrue(state.canPersistViewport)
    }

    func testUserScrollCancelsOutstandingIntentButProgrammaticFeedbackDoesNot() {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        state.captureRestoration(saved())
        let geometry = rebuild(&state, index: index)
        state.didScrollProgrammatically(to: 100)
        state.viewportMoved(to: 101)
        XCTAssertNotNil(state.restoration)
        state.viewportMoved(to: 130)
        XCTAssertTrue(state.canPersistViewport)

        let request = BrowserRevealRequest(itemID: 42, dayID: "2024-04-03", sectionOffsetHint: nil)
        _ = state.reveal(request, index: index, geometry: geometry)
        state.didScrollProgrammatically(to: 300)
        state.viewportMoved(to: 250)
        XCTAssertNil(state.revealID)
        XCTAssertFalse(state.finishReveal(id: request.id))
    }

    func testCachedExactRestorationUsesPixelOffsetWithoutViewerCentering() throws {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        state.captureRestoration(saved())
        var geometry = rebuild(&state, index: index)
        let pages = [0: try page(verified: false)]
        geometry.reconcile(pages: pages)
        guard case .scroll(let y) = state.reconcile(pages: pages, index: index,
            geometry: geometry, timelineVerified: false) else { return XCTFail("Expected exact restoration") }
        XCTAssertEqual(y, try XCTUnwrap(geometry.y(forItem: 42, offset: 17)), accuracy: 0.001)
        XCTAssertTrue(state.canPersistViewport)
    }

    func testMissingSavedDayWaitsForTimelineVerificationIncludingWithoutRebuild() throws {
        let index = index(day: 1)
        var state = BrowserScrollIntentCoordinator()
        state.captureRestoration(saved())
        var geometry = rebuild(&state, index: index)
        XCTAssertEqual(state.anchor?.dayID, "2024-04-01")
        XCTAssertNil(state.anchor?.itemID)
        let pages = [0: try page(verified: true, itemID: 2)]
        geometry.reconcile(pages: pages)
        _ = state.reconcile(pages: pages, index: index, geometry: geometry, timelineVerified: false)
        XCTAssertEqual(state.restoration, saved())
        state.timelineDidVerify(index: index, verified: true)
        XCTAssertTrue(state.canPersistViewport)

        var verified = BrowserScrollIntentCoordinator()
        verified.captureRestoration(saved())
        _ = rebuild(&verified, index: index, verified: true)
        XCTAssertTrue(verified.canPersistViewport)
    }

    func testMissingItemVerifiesSplitDayOneSectionAtATimeAcrossEviction() throws {
        let index = index(pages: 12)
        var state = BrowserScrollIntentCoordinator()
        state.captureRestoration(saved(hint: 20))
        var geometry = rebuild(&state, index: index)
        XCTAssertNil(state.nextSectionToVerify(index: index, allowNetwork: false))
        XCTAssertEqual(state.nextSectionToVerify(index: index, allowNetwork: true), 10)
        let cached = [10: try page(section: 10, verified: false, itemID: 2)]
        geometry.reconcile(pages: cached)
        _ = state.reconcile(pages: cached, index: index, geometry: geometry, timelineVerified: true)
        XCTAssertEqual(state.nextSectionToVerify(index: index, allowNetwork: true), 10)

        var visited: Set<Int> = []
        while let section = state.nextSectionToVerify(index: index, allowNetwork: true) {
            XCTAssertTrue(visited.insert(section).inserted)
            let pages = [section: try page(section: section, verified: true, itemID: 2)]
            geometry.reconcile(pages: pages)
            _ = state.reconcile(pages: pages, index: index, geometry: geometry, timelineVerified: true)
            if visited.count > 12 { return XCTFail("Unbounded verification loop") }
        }
        XCTAssertEqual(visited.count, 12)
        XCTAssertTrue(state.canPersistViewport)
    }

    func testRebuildRetainsRevealIdentityAndHintedSlice() {
        let oldIndex = index(pages: 12)
        let geometry = LibraryViewportGeometry(index: oldIndex, width: 500)
        var state = BrowserScrollIntentCoordinator()
        let request = BrowserRevealRequest(itemID: 42, dayID: "2024-04-03", sectionOffsetHint: 20)
        let target = state.reveal(request, index: oldIndex, geometry: geometry)
        XCTAssertEqual(state.anchor?.sectionIndex, 10)
        XCTAssertEqual(target, geometry.y(for: state.anchor!))
        XCTAssertGreaterThan(target!, geometry.y(forDay: request.dayID)!)

        _ = rebuild(&state, index: index(pages: 13), verified: true)
        XCTAssertEqual(state.revealID, request.id)
        XCTAssertEqual(state.anchor?.sectionIndex, 10)
        state.stop()
        XCTAssertTrue(state.canPersistViewport)
        XCTAssertFalse(state.finishReveal(id: request.id))
    }

    func testViewerPageArrivalReturnsIdentityBoundReveal() throws {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        var geometry = LibraryViewportGeometry(index: index, width: 500)
        let request = BrowserRevealRequest(itemID: 42, dayID: "2024-04-03", sectionOffsetHint: nil)
        _ = state.reveal(request, index: index, geometry: geometry)
        let pages = [0: try page(verified: true)]
        geometry.reconcile(pages: pages)
        guard case .reveal(let id, let itemID) = state.reconcile(pages: pages, index: index,
            geometry: geometry, timelineVerified: true) else { return XCTFail("Expected viewer positioning") }
        XCTAssertEqual(id, request.id)
        XCTAssertEqual(itemID, 42)
        state.revealPositioned(id: id)
        guard case .preserveViewport = state.reconcile(pages: pages, index: index,
            geometry: geometry, timelineVerified: true) else { return XCTFail("Do not schedule a second completion") }
    }

    func testMissingRevealedItemSettlesAfterAuthoritativePage() throws {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        var geometry = LibraryViewportGeometry(index: index, width: 500)
        let request = BrowserRevealRequest(itemID: 42, dayID: "2024-04-03", sectionOffsetHint: nil)
        _ = state.reveal(request, index: index, geometry: geometry)
        let pages = [0: try page(verified: true, itemID: 2)]
        geometry.reconcile(pages: pages)
        guard case .settled = state.reconcile(pages: pages, index: index,
            geometry: geometry, timelineVerified: true) else { return XCTFail("Expected missing reveal to settle") }
        XCTAssertNil(state.revealID)
    }

    func testOrdinaryRebuildPreservesVisibleAnchorUntilPagesArrive() throws {
        let index = index()
        var state = BrowserScrollIntentCoordinator()
        var geometry = LibraryViewportGeometry(index: index, width: 500)
        let visible = LibraryViewportGeometry.Anchor(dayID: "2024-04-03", sectionIndex: 0,
            itemID: 42, localOffset: 9, fraction: 0.3)
        _ = state.rebuild(index: index, geometry: geometry, previousIndex: index,
            visibleAnchor: visible, timelineVerified: true)
        XCTAssertNil(state.restoration)
        XCTAssertEqual(state.anchor?.itemID, 42)
        let pages = [0: try page(verified: true)]
        geometry.reconcile(pages: pages)
        guard case .scroll(let y) = state.reconcile(pages: pages, index: index,
            geometry: geometry, timelineVerified: true) else { return XCTFail("Expected viewport preservation") }
        XCTAssertEqual(y, try XCTUnwrap(geometry.y(forItem: 42, offset: 9)), accuracy: 0.001)
        XCTAssertTrue(state.canPersistViewport)
    }
}
