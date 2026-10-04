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

    func testSelectedDestinationAndIndependentTimelineAnchorsRoundTrip() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let personal = PhotoTimelineRestorationAnchor(itemID: 41, dayID: "2024-10-13",
                                                      sectionOffsetHint: 300, localOffset: 17,
                                                      sectionFraction: 0.4)
        let favorites = PhotoTimelineRestorationAnchor(itemID: 92, dayID: "2023-05-02",
                                                       sectionOffsetHint: 700, localOffset: 3,
                                                       sectionFraction: 0.1)

        let writer = NavigationRestorationStore(defaults: defaults, key: key)
        writer.setTimelineAnchor(personal, for: .personalLibrary)
        writer.setTimelineAnchor(favorites, for: .favorites)
        writer.select(.favorites)

        let reader = NavigationRestorationStore(defaults: defaults, key: key)
        XCTAssertEqual(reader.selectedCollection, .favorites)
        XCTAssertEqual(reader.timelineAnchor(for: .personalLibrary), personal)
        XCTAssertEqual(reader.timelineAnchor(for: .favorites), favorites)
    }

    func testOldVersionIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":1,"selectedCollection":"favorites"}"#)
    }

    func testFutureVersionIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":3,"selectedCollection":"favorites"}"#)
    }

    func testCorruptPayloadIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":2,"selectedCollection":}"#)
    }

    private func assertInvalidPayloadFallsBack(_ payload: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        defaults.set(Data(payload.utf8), forKey: key)

        let store = NavigationRestorationStore(defaults: defaults, key: key)

        XCTAssertEqual(store.selectedCollection, .personalLibrary, file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .personalLibrary), file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .favorites), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: key), file: file, line: line)
    }
}
