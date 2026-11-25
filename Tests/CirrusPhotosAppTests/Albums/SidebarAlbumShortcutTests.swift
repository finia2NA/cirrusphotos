import AppKit
import XCTest
import SynologyAPI
@testable import CirrusPhotosApp

@MainActor
final class SidebarAlbumShortcutTests: XCTestCase {
    func testFirstNinePinsAreNumberedInSidebarOrder() {
        let pins = (1...11).map { PhotoCollectionDescriptor.album(Int64($0 * 10)) }
        XCTAssertEqual(sidebarAlbumShortcutNumber(of: pins[0], in: pins), 1)
        XCTAssertEqual(sidebarAlbumShortcutNumber(of: pins[8], in: pins), 9)
        XCTAssertNil(sidebarAlbumShortcutNumber(of: pins[9], in: pins))
        XCTAssertNil(sidebarAlbumShortcutNumber(of: .album(5), in: pins))
    }

    func testCommandAloneShowsShortcutsAfterTheDelayAndOtherKeysHideThem() async {
        let state = CommandKeyHoldState()
        state.delay = 0.01
        state.handle(type: .flagsChanged, flags: .command)
        XCTAssertFalse(state.isShowingShortcuts)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(state.isShowingShortcuts)
        state.handle(type: .keyDown, flags: .command, characters: "3")
        XCTAssertTrue(state.isShowingShortcuts)
        state.handle(type: .keyDown, flags: .command, characters: "c")
        XCTAssertFalse(state.isShowingShortcuts)
        state.handle(type: .flagsChanged, flags: [.command, .shift])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.isShowingShortcuts)
    }

    func testReleasingCommandBeforeTheDelayShowsNothing() async {
        let state = CommandKeyHoldState()
        state.delay = 0.02
        state.handle(type: .flagsChanged, flags: .command)
        state.handle(type: .flagsChanged, flags: [])
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(state.isShowingShortcuts)
    }

    func testAdditionStatusOutranksShortcutBadge() {
        XCTAssertEqual(AlbumRowBadge.resolve(addition: nil, shortcutNumber: nil, contained: true), nil)
        XCTAssertEqual(AlbumRowBadge.resolve(addition: nil, shortcutNumber: 3, contained: false), .number(3))
        XCTAssertEqual(AlbumRowBadge.resolve(addition: nil, shortcutNumber: 3, contained: true), .contained)
        XCTAssertEqual(AlbumRowBadge.resolve(addition: .running, shortcutNumber: 3, contained: true), .running)
        XCTAssertEqual(AlbumRowBadge.resolve(addition: .failed, shortcutNumber: nil, contained: false), .failed)
    }

    private func statusStore() -> AlbumAdditionStatusStore {
        let store = AlbumAdditionStatusStore()
        store.successDuration = .milliseconds(30)
        store.failureDuration = .milliseconds(30)
        return store
    }

    func testQueuedSuccessIsHiddenAndTheLastResultShowsThenClears() async {
        let store = statusStore()
        let album = PhotoCollectionDescriptor.album(7)
        let first = store.begin(album), second = store.begin(album)
        store.finish(album, id: first, succeeded: true)
        XCTAssertEqual(store.phase(for: album), .running)
        store.finish(album, id: second, succeeded: true)
        XCTAssertEqual(store.phase(for: album), .succeeded)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.phase(for: album))
    }

    func testQueuedFailureFlashesThenReturnsToRunning() async {
        let store = statusStore()
        let album = PhotoCollectionDescriptor.album(7)
        let first = store.begin(album), second = store.begin(album)
        store.finish(album, id: first, succeeded: false)
        XCTAssertEqual(store.phase(for: album), .failed)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.phase(for: album), .running)
        store.finish(album, id: second, succeeded: false)
        XCTAssertEqual(store.phase(for: album), .failed)
    }

    func testLastResultReplacesAFailureFlashAtOnce() async {
        let store = statusStore()
        store.failureDuration = .seconds(5)
        let album = PhotoCollectionDescriptor.album(7)
        let first = store.begin(album), second = store.begin(album), third = store.begin(album)
        store.finish(album, id: first, succeeded: false)
        store.finish(album, id: second, succeeded: true)
        XCTAssertEqual(store.phase(for: album), .failed)
        store.finish(album, id: third, succeeded: true)
        XCTAssertEqual(store.phase(for: album), .succeeded)
    }

    func testAdditionStartedAfterAResultShowsRunning() {
        let store = statusStore()
        let album = PhotoCollectionDescriptor.album(7)
        store.finish(album, id: store.begin(album), succeeded: true)
        _ = store.begin(album)
        XCTAssertEqual(store.phase(for: album), .running)
    }
}
