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
}
