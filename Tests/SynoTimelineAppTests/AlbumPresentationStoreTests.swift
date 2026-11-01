import AppKit
import Foundation
import PhotoCache
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

@MainActor
final class AlbumPresentationStoreTests: XCTestCase {
    func testAlbumDragAnchorDoesNotInterceptCardClicks() {
        let anchor = AlbumDragAnchorView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(anchor.hitTest(NSPoint(x: 50, y: 50)))
    }

    func testPinsPersistUniquelyAndAreIsolatedByAccountAndServer() {
        let suite = "AlbumPresentationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "server-a-alice")
        store.add(2); store.add(1); store.add(2)
        XCTAssertEqual(store.pinnedIDs, [2, 1])
        store.move(1, before: 2)
        store.configure(namespace: "server-a-bob")
        XCTAssertEqual(store.pinnedIDs, [])
        store.add(9)
        store.configure(namespace: "server-b-alice")
        XCTAssertEqual(store.pinnedIDs, [])
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "server-a-alice")
        XCTAssertEqual(restored.pinnedIDs, [1, 2])
        restored.remove(1); restored.remove(1)
        let again = AlbumPresentationStore(defaults: defaults)
        again.configure(namespace: "server-a-alice")
        XCTAssertEqual(again.pinnedIDs, [2])
    }

    func testInsertionPinsAndReordersWithoutDuplicates() {
        let suite = "AlbumInsertionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account")
        store.add(1); store.add(3)
        store.insert(2, before: 3)
        store.insert(3, before: 1)
        store.insert(3, before: 3)
        XCTAssertEqual(store.pinnedIDs, [3, 1, 2])
        store.insert(3, before: nil)
        store.insert(9, before: 100)
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "account")
        XCTAssertEqual(restored.pinnedIDs, [1, 2, 3])
    }

    func testSpringTargetOpensOnlyForAnActiveLocalSelection() async {
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites, timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let nonce = SelectionDragRegistry.register(.init(selection: selection, sourceAlbumID: nil, namespace: "a"))
        defer { SelectionDragRegistry.remove(nonce) }
        let target = AlbumOverviewSpringTarget.TargetView()
        target.namespace = "b"
        target.hoverDelay = 0.02
        let opened = expectation(description: "overview opens")
        var opens = 0
        target.open = { _ in opens += 1; opened.fulfill() }
        XCTAssertFalse(target.beginHover(nonce.uuidString))
        target.namespace = "a"
        XCTAssertTrue(target.beginHover(nonce.uuidString))
        target.cancel()
        XCTAssertTrue(target.beginHover(nonce.uuidString))
        await fulfillment(of: [opened], timeout: 1)
        XCTAssertEqual(opens, 1)
        XCTAssertNotNil(SelectionDragRegistry.lookup(nonce.uuidString, namespace: "a"))
    }

    func testDragEndObserverSurvivesAcceptedSelectionAndFiresOnce() {
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites, timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let nonce = SelectionDragRegistry.register(.init(selection: selection, sourceAlbumID: nil, namespace: "a"))
        var ended = 0
        XCTAssertFalse(SelectionDragRegistry.observeEnd(nonce.uuidString, namespace: "b") { ended += 1 })
        XCTAssertTrue(SelectionDragRegistry.observeEnd(nonce.uuidString, namespace: "a") { ended += 1 })
        XCTAssertNotNil(SelectionDragRegistry.take(nonce.uuidString, namespace: "a"))
        XCTAssertEqual(ended, 0)
        SelectionDragRegistry.remove(nonce)
        SelectionDragRegistry.remove(nonce)
        XCTAssertEqual(ended, 1)
    }

    func testSelectionNonceIsScopedAndConsumedOnce() {
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites, timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let nonce = SelectionDragRegistry.register(.init(selection: selection, sourceAlbumID: nil, namespace: "a"))
        XCTAssertNil(SelectionDragRegistry.take(nonce.uuidString, namespace: "b"))
        XCTAssertNil(AlbumDragRegistry.album(nonce.uuidString, namespace: "a"))
        XCTAssertEqual(SelectionDragRegistry.take(nonce.uuidString, namespace: "a")?.selection.knownItemIDsByOrdinal[1], 42)
        XCTAssertNil(SelectionDragRegistry.take(nonce.uuidString, namespace: "a"))
        SelectionDragRegistry.remove(nonce)
    }

    func testAlbumNonceIsScopedAndRemoved() {
        let nonce = AlbumDragRegistry.register(albumID: 42, namespace: "account-a")
        XCTAssertEqual(AlbumDragRegistry.album(nonce.uuidString, namespace: "account-a"), 42)
        XCTAssertNil(AlbumDragRegistry.album(nonce.uuidString, namespace: "account-b"))
        XCTAssertNil(AlbumDragRegistry.album(UUID().uuidString, namespace: "account-a"))
        let suite = "AlbumDispatchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account-a")
        XCTAssertFalse(AlbumDragRegistry.insert(nonce.uuidString, namespace: "account-b", before: nil, presentation: store))
        XCTAssertTrue(AlbumDragRegistry.insert(nonce.uuidString, namespace: "account-a", before: nil, presentation: store))
        XCTAssertEqual(store.pinnedIDs, [42])
        AlbumDragRegistry.remove(nonce)
        XCTAssertNil(AlbumDragRegistry.album(nonce.uuidString, namespace: "account-a"))
    }

    func testProvisionalOrFailedListDoesNotPruneAndVerifiedListDoes() {
        let suite = "AlbumPresentationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account")
        store.add(1); store.add(2)
        let cached = [AlbumSummary(id: 1, name: "Cached", itemCount: 1)]
        store.reconcile(cached, verified: false)
        store.reconcile([], verified: false) // failed or unavailable validation
        XCTAssertEqual(store.pinnedIDs, [1, 2])
        let offline = AlbumPresentationStore(defaults: defaults)
        offline.configure(namespace: "account")
        XCTAssertEqual(offline.pinnedIDs, [1, 2])
        offline.reconcile(cached, verified: true)
        XCTAssertEqual(offline.pinnedIDs, [1])
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "account")
        XCTAssertEqual(restored.pinnedIDs, [1])
    }

    func testInvalidVersionAndDuplicateStoredIDsAreDiscarded() {
        let suite = "AlbumPresentationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for payload in [#"{"version":2,"pinnedIDs":[1]}"#, #"{"version":1,"pinnedIDs":[1,1]}"#] {
            defaults.set(Data(payload.utf8), forKey: "albumPresentation.account")
            let store = AlbumPresentationStore(defaults: defaults)
            store.configure(namespace: "account")
            XCTAssertEqual(store.pinnedIDs, [])
            XCTAssertNil(defaults.data(forKey: "albumPresentation.account"))
        }
    }
}
