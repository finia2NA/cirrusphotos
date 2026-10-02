import Foundation
import XCTest
@testable import TimelinePrototype

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

    func testUnknownAnchorKindDoesNotDiscardKnownDestination() throws {
        let data = Data(#"""
        {
          "version": 1,
          "selectedDestinationID": "favorites",
          "anchorsByDestinationID": {
            "personal-library": {
              "kind": "photoTimeline",
              "value": {
                "itemID": 12,
                "dayID": "2024-09-08",
                "sectionOffsetHint": 100,
                "localOffset": 4,
                "sectionFraction": 0.25
              }
            },
            "future-destination": { "kind": "map", "value": { "latitude": 1 } }
          }
        }
        """#.utf8)

        let state = try JSONDecoder().decode(RestorableAppNavigationState.self, from: data)

        XCTAssertEqual(state.selectedDestinationID, "favorites")
        XCTAssertEqual(state.anchorsByDestinationID.count, 1)
        guard case .photoTimeline(let anchor) = state.anchorsByDestinationID["personal-library"] else {
            return XCTFail("Expected the known timeline anchor to survive")
        }
        XCTAssertEqual(anchor.itemID, 12)
        XCTAssertEqual(anchor.dayID, "2024-09-08")
    }

    func testUnsupportedFutureDocumentFallsBackSafely() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        defaults.set(Data(#"{"version":99,"selectedDestinationID":"favorites"}"#.utf8), forKey: key)

        let store = NavigationRestorationStore(defaults: defaults, key: key)

        XCTAssertEqual(store.selectedCollection, .personalLibrary)
        XCTAssertNil(store.timelineAnchor(for: .favorites))
    }
}
