import AppKit
import Testing
@testable import CirrusPhotosApp

@Suite @MainActor struct KeyboardNavigationStateTests {
    @Test func tabActivatesAndClickClears() {
        let state = KeyboardNavigationState()
        state.update(for: .keyDown, keyCode: 48)
        #expect(state.isActive)
        state.update(for: .leftMouseDown, keyCode: 0)
        #expect(!state.isActive)
        state.update(for: .keyDown, keyCode: 48)
        state.update(for: .rightMouseDown, keyCode: 0)
        #expect(!state.isActive)
    }

    @Test func otherKeysLeaveStateUnchanged() {
        let state = KeyboardNavigationState()
        state.update(for: .keyDown, keyCode: 0)
        #expect(!state.isActive)
        state.update(for: .keyDown, keyCode: 48)
        state.update(for: .keyDown, keyCode: 36)
        #expect(state.isActive)
    }

    @Test func otherEventTypesAreIgnored() {
        let state = KeyboardNavigationState()
        state.update(for: .keyDown, keyCode: 48)
        state.update(for: .mouseMoved, keyCode: 0)
        #expect(state.isActive)
    }
}
