import Foundation
import XCTest
@testable import CirrusPhotosApp

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testHidingViewerToolbarToolsTurnsOverlaysOffAndPersists() {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showsViewerToolbarTools = true
        preferences.showsFilmstrip = true
        preferences.showsHistogram = true
        preferences.showsHighlightPeaking = true
        preferences.showsFocusEdges = true

        preferences.showsViewerToolbarTools = false

        let reloaded = AppPreferences(defaults: defaults)
        for overlays in [preferences, reloaded] {
            XCTAssertFalse(overlays.showsFilmstrip)
            XCTAssertFalse(overlays.showsHistogram)
            XCTAssertFalse(overlays.showsHighlightPeaking)
            XCTAssertFalse(overlays.showsFocusEdges)
        }
    }

    func testOverlaysPersistWhileViewerToolbarToolsStayHidden() {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showsHistogram = true
        preferences.showsViewerToolbarTools = false

        XCTAssertTrue(AppPreferences(defaults: defaults).showsHistogram)
    }
}
