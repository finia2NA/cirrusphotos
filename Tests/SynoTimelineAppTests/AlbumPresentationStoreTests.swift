import Foundation
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

@MainActor
final class AlbumPresentationStoreTests: XCTestCase {
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
