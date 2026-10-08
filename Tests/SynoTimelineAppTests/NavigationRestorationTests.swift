import Foundation
import XCTest
@testable import SynoTimelineApp

@MainActor
final class NavigationRestorationTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let suite = "NavigationRestorationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDestinationOpenedAlbumAndIndependentTimelineAnchorsRoundTrip() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let personal = PhotoTimelineRestorationAnchor(itemID: 41, dayID: "2024-10-13",
                                                      sectionOffsetHint: 300, localOffset: 17,
                                                      sectionFraction: 0.4)
        let favorites = PhotoTimelineRestorationAnchor(itemID: 92, dayID: "2023-05-02",
                                                       sectionOffsetHint: 700, localOffset: 3,
                                                       sectionFraction: 0.1)
        let album = PhotoTimelineRestorationAnchor(itemID: 7, dayID: "2022-01-09",
                                                   sectionOffsetHint: 12, localOffset: 0,
                                                   sectionFraction: 0.0)

        let writer = NavigationRestorationStore(defaults: defaults, key: key)
        writer.setTimelineAnchor(personal, for: .personalLibrary)
        writer.setTimelineAnchor(favorites, for: .favorites)
        writer.setTimelineAnchor(album, for: .album(54))
        writer.select(.albums)
        writer.setOpenedAlbum(54)

        let reader = NavigationRestorationStore(defaults: defaults, key: key)
        XCTAssertEqual(reader.selectedDestination, .albums)
        XCTAssertEqual(reader.openedAlbumID, 54)
        XCTAssertEqual(reader.timelineAnchor(for: .personalLibrary), personal)
        XCTAssertEqual(reader.timelineAnchor(for: .favorites), favorites)
        XCTAssertEqual(reader.timelineAnchor(for: .album(54)), album)
    }

    func testAlbumAnchorIsIsolatedPerAlbum() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let album = PhotoTimelineRestorationAnchor(itemID: 7, dayID: "2022-01-09",
                                                   sectionOffsetHint: nil, localOffset: 1,
                                                   sectionFraction: 0.5)
        let store = NavigationRestorationStore(defaults: defaults, key: key)
        store.setTimelineAnchor(album, for: .album(54))
        XCTAssertEqual(store.timelineAnchor(for: .album(54)), album)
        XCTAssertNil(store.timelineAnchor(for: .album(55)))
    }

    func testOpeningThenClosingAlbumPersists() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationRestorationStore(defaults: defaults, key: key)
        store.setOpenedAlbum(11)
        XCTAssertEqual(NavigationRestorationStore(defaults: defaults, key: key).openedAlbumID, 11)
        store.setOpenedAlbum(nil)
        XCTAssertNil(NavigationRestorationStore(defaults: defaults, key: key).openedAlbumID)
    }

    func testMapDestinationRoundTripsWithoutPersistentFilterState() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationRestorationStore(defaults: defaults, key: key)

        store.select(.map)

        let restored = NavigationRestorationStore(defaults: defaults, key: key)
        XCTAssertEqual(restored.selectedDestination, .map)
        XCTAssertNil(restored.openedAlbumID)
        XCTAssertEqual(restored.state.anchors, [:])
    }

    func testOldVersionIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":2,"selectedDestination":"favorites"}"#)
    }

    func testFutureVersionIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":4,"selectedDestination":"favorites"}"#)
    }

    func testCorruptPayloadIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":3,"selectedDestination":}"#)
    }

    private func assertInvalidPayloadFallsBack(_ payload: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        defaults.set(Data(payload.utf8), forKey: key)

        let store = NavigationRestorationStore(defaults: defaults, key: key)

        XCTAssertEqual(store.selectedDestination, .personalLibrary, file: file, line: line)
        XCTAssertNil(store.openedAlbumID, file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .personalLibrary), file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .favorites), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: key), file: file, line: line)
    }
}
