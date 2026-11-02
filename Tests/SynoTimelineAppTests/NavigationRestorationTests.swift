import Foundation
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

@MainActor
final class NavigationRestorationTests: XCTestCase {
    func testNestedCollectionsRestoreIndependentlyInEachSpace() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationRestorationStore(defaults: defaults)
        for space in PhotoSpace.allCases {
            store.selectSpace(space)
            _ = store.preparePerson(namespace: "account")
            _ = store.prepareSubject(namespace: "account")
            _ = store.prepareTag(namespace: "account")
            _ = store.prepareFolders(namespace: "account")
            let id: Int64 = space == .personal ? 1 : 2
            store.setOpenedPerson(id); store.setOpenedSubject(id); store.setOpenedTag(id)
            store.setFolders(shown: true, path: [id])
        }
        let reopened = NavigationRestorationStore(defaults: defaults)
        for space in PhotoSpace.allCases {
            reopened.selectSpace(space)
            let id: Int64 = space == .personal ? 1 : 2
            XCTAssertEqual(reopened.preparePerson(namespace: "account"), id)
            XCTAssertEqual(reopened.prepareSubject(namespace: "account"), id)
            XCTAssertEqual(reopened.prepareTag(namespace: "account"), id)
            XCTAssertEqual(reopened.prepareFolders(namespace: "account"), [id])
        }
    }

    func testFolderModeAndAccountResetStayWithinTheirSpace() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationRestorationStore(defaults: defaults)
        _ = store.prepareFolders(namespace: "first")
        store.setFolders(shown: true, path: [1])
        store.setOpenedPerson(4)
        store.selectSpace(.shared)
        _ = store.prepareFolders(namespace: "first")
        store.setFolders(shown: false, path: [2])
        store.setOpenedPerson(5)
        store.selectSpace(.personal)
        XCTAssertTrue(store.showsFolders)
        XCTAssertEqual(store.folderPath, [1])
        XCTAssertNil(store.preparePerson(namespace: "second"))
        XCTAssertTrue(store.folderPath.isEmpty)
        store.selectSpace(.shared)
        XCTAssertFalse(store.showsFolders)
        XCTAssertEqual(store.preparePerson(namespace: "first"), 5)
        XCTAssertEqual(store.folderPath, [2])
    }

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
        writer.setTimelineAnchor(personal, for: .library(.personal))
        writer.setTimelineAnchor(favorites, for: .favorites(.personal))
        writer.setTimelineAnchor(album, for: .album(54))
        writer.selectSidebar(.destination(.albums))
        writer.setOpenedAlbum(.album(54))
        writer.selectSidebar(.album(.album(54)))

        let reader = NavigationRestorationStore(defaults: defaults, key: key)
        XCTAssertEqual(reader.selectedDestination, .albums)
        XCTAssertEqual(reader.openedAlbum, .album(54))
        XCTAssertEqual(reader.sidebarSelection, .album(.album(54)))
        XCTAssertEqual(reader.timelineAnchor(for: .library(.personal)), personal)
        XCTAssertEqual(reader.timelineAnchor(for: .favorites(.personal)), favorites)
        XCTAssertEqual(reader.timelineAnchor(for: .album(54)), album)
    }

    func testSpaceSelectionAndIndependentAnchorsRoundTrip() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationRestorationStore(defaults: defaults, key: "state")
        let shared = PhotoTimelineRestorationAnchor(itemID: 41, dayID: "2024-10-13", sectionOffsetHint: nil, localOffset: 0, sectionFraction: 0)
        store.selectSpace(.shared)
        store.setTimelineAnchor(shared, for: .library(.shared))
        store.selectSidebar(.album(.album(54)))
        store.setOpenedAlbum(.album(54))
        let restored = NavigationRestorationStore(defaults: defaults, key: "state")
        XCTAssertEqual(restored.selectedSpace, .shared)
        XCTAssertEqual(restored.openedAlbum, .album(54))
        XCTAssertEqual(restored.timelineAnchor(for: .library(.shared)), shared)
        XCTAssertNil(restored.timelineAnchor(for: .library(.personal)))
    }

    func testFolderModeAndPathRoundTrip() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationRestorationStore(defaults: defaults, key: "state")
        store.setFolders(shown: true, path: [2, 8])
        let restored = NavigationRestorationStore(defaults: defaults, key: "state")
        XCTAssertTrue(restored.showsFolders)
        XCTAssertEqual(restored.folderPath, [2, 8])
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
        store.setOpenedAlbum(.album(11))
        XCTAssertEqual(NavigationRestorationStore(defaults: defaults, key: key).openedAlbum, .album(11))
        store.setOpenedAlbum(nil)
        XCTAssertNil(NavigationRestorationStore(defaults: defaults, key: key).openedAlbum)
    }

    func testMissingOpenedAlbumClearsOnlyAfterVerifiedList() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationRestorationStore(defaults: defaults, key: key)
        store.setOpenedAlbum(.album(11))
        store.selectSidebar(.album(.album(11)))
        let other = AlbumSummary(id: 12, name: "Other", itemCount: 1)

        XCTAssertFalse(store.clearOpenedAlbumIfMissing(in: [other], verified: false))
        XCTAssertEqual(store.openedAlbum, .album(11))
        XCTAssertTrue(store.clearOpenedAlbumIfMissing(in: [other], verified: true))
        XCTAssertNil(store.openedAlbum)
        XCTAssertEqual(store.sidebarSelection, .destination(.albums))
        XCTAssertNil(NavigationRestorationStore(defaults: defaults, key: key).openedAlbum)
    }

    func testMapDestinationRoundTripsWithoutPersistentFilterState() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationRestorationStore(defaults: defaults, key: key)

        store.selectSidebar(.destination(.map))

        let restored = NavigationRestorationStore(defaults: defaults, key: key)
        XCTAssertEqual(restored.selectedDestination, .map)
        XCTAssertNil(restored.openedAlbum)
        XCTAssertEqual(restored.state.anchors, [:])
    }

    func testOldVersionIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":3,"selectedDestination":"favorites"}"#)
    }

    func testFutureVersionIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":5,"sidebarSelection":"favorites"}"#)
    }

    func testCorruptPayloadIsDiscardedCompletely() {
        assertInvalidPayloadFallsBack(#"{"version":4,"sidebarSelection":}"#)
    }

    private func assertInvalidPayloadFallsBack(_ payload: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        defaults.set(Data(payload.utf8), forKey: key)

        let store = NavigationRestorationStore(defaults: defaults, key: key)

        XCTAssertEqual(store.selectedDestination, .personalLibrary, file: file, line: line)
        XCTAssertNil(store.openedAlbum, file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .library(.personal)), file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .favorites(.personal)), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: key), file: file, line: line)
    }
}
