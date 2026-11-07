import Foundation
import SynologyAPI
import XCTest
@testable import CirrusPhotosApp

@MainActor
final class NavigationModelTests: XCTestCase {
    func testNestedCollectionsRestoreIndependentlyInEachSpace() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationModel(defaults: defaults)
        for space in PhotoSpace.allCases {
            store.selectedSpace = space
            _ = store.prepareIndexEntry(.person, namespace: "account")
            _ = store.prepareIndexEntry(.subject, namespace: "account")
            _ = store.prepareIndexEntry(.tag, namespace: "account")
            _ = store.prepareFolders(namespace: "account")
            let id: Int64 = space == .personal ? 1 : 2
            store.openedIndexEntries[.person] = id; store.openedIndexEntries[.subject] = id; store.openedIndexEntries[.tag] = id
            store.showsFolders = true; store.folderPath = [id]
        }
        let reopened = NavigationModel(defaults: defaults)
        for space in PhotoSpace.allCases {
            reopened.selectedSpace = space
            let id: Int64 = space == .personal ? 1 : 2
            XCTAssertEqual(reopened.prepareIndexEntry(.person, namespace: "account"), id)
            XCTAssertEqual(reopened.prepareIndexEntry(.subject, namespace: "account"), id)
            XCTAssertEqual(reopened.prepareIndexEntry(.tag, namespace: "account"), id)
            XCTAssertEqual(reopened.prepareFolders(namespace: "account"), [id])
        }
    }

    func testFolderModeAndAccountResetStayWithinTheirSpace() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationModel(defaults: defaults)
        _ = store.prepareFolders(namespace: "first")
        store.showsFolders = true; store.folderPath = [1]
        store.openedIndexEntries[.person] = 4
        store.selectedSpace = .shared
        _ = store.prepareFolders(namespace: "first")
        store.showsFolders = false; store.folderPath = [2]
        store.openedIndexEntries[.person] = 5
        store.selectedSpace = .personal
        XCTAssertTrue(store.showsFolders)
        XCTAssertEqual(store.folderPath, [1])
        XCTAssertNil(store.prepareIndexEntry(.person, namespace: "second"))
        XCTAssertTrue(store.folderPath.isEmpty)
        store.selectedSpace = .shared
        XCTAssertFalse(store.showsFolders)
        XCTAssertEqual(store.prepareIndexEntry(.person, namespace: "first"), 5)
        XCTAssertEqual(store.folderPath, [2])
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "NavigationModelTests.\(UUID().uuidString)"
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

        let writer = NavigationModel(defaults: defaults, key: key)
        writer.setTimelineAnchor(personal, for: .library(.personal))
        writer.setTimelineAnchor(favorites, for: .favorites(.personal))
        writer.setTimelineAnchor(album, for: .album(54))
        writer.sidebarSelection = .destination(.albums)
        writer.openedAlbum = .album(54)
        writer.sidebarSelection = .album(.album(54))

        let reader = NavigationModel(defaults: defaults, key: key)
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
        let store = NavigationModel(defaults: defaults, key: "state")
        let shared = PhotoTimelineRestorationAnchor(itemID: 41, dayID: "2024-10-13", sectionOffsetHint: nil, localOffset: 0, sectionFraction: 0)
        store.selectedSpace = .shared
        store.setTimelineAnchor(shared, for: .library(.shared))
        store.sidebarSelection = .album(.album(54))
        store.openedAlbum = .album(54)
        let restored = NavigationModel(defaults: defaults, key: "state")
        XCTAssertEqual(restored.selectedSpace, .shared)
        XCTAssertEqual(restored.openedAlbum, .album(54))
        XCTAssertEqual(restored.timelineAnchor(for: .library(.shared)), shared)
        XCTAssertNil(restored.timelineAnchor(for: .library(.personal)))
    }

    func testFolderModeAndPathRoundTrip() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationModel(defaults: defaults, key: "state")
        store.showsFolders = true; store.folderPath = [2, 8]
        let restored = NavigationModel(defaults: defaults, key: "state")
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
        let store = NavigationModel(defaults: defaults, key: key)
        store.setTimelineAnchor(album, for: .album(54))
        XCTAssertEqual(store.timelineAnchor(for: .album(54)), album)
        XCTAssertNil(store.timelineAnchor(for: .album(55)))
    }

    func testOpeningThenClosingAlbumPersists() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationModel(defaults: defaults, key: key)
        store.openedAlbum = .album(11)
        XCTAssertEqual(NavigationModel(defaults: defaults, key: key).openedAlbum, .album(11))
        store.openedAlbum = nil
        XCTAssertNil(NavigationModel(defaults: defaults, key: key).openedAlbum)
    }

    func testMissingOpenedAlbumClearsOnlyAfterVerifiedList() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationModel(defaults: defaults, key: key)
        store.openedAlbum = .album(11)
        store.sidebarSelection = .album(.album(11))
        let other = AlbumSummary(id: 12, name: "Other", itemCount: 1)

        XCTAssertFalse(store.clearOpenedAlbumIfMissing(in: [other], verified: false))
        XCTAssertEqual(store.openedAlbum, .album(11))
        XCTAssertTrue(store.clearOpenedAlbumIfMissing(in: [other], verified: true))
        XCTAssertNil(store.openedAlbum)
        XCTAssertEqual(store.sidebarSelection, .destination(.albums))
        XCTAssertNil(NavigationModel(defaults: defaults, key: key).openedAlbum)
    }

    func testMapDestinationRoundTripsWithoutPersistentFilterState() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "state"
        let store = NavigationModel(defaults: defaults, key: key)

        store.sidebarSelection = .destination(.map)

        let restored = NavigationModel(defaults: defaults, key: key)
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

        let store = NavigationModel(defaults: defaults, key: key)

        XCTAssertEqual(store.selectedDestination, .personalLibrary, file: file, line: line)
        XCTAssertNil(store.openedAlbum, file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .library(.personal)), file: file, line: line)
        XCTAssertNil(store.timelineAnchor(for: .favorites(.personal)), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: key), file: file, line: line)
    }
}
