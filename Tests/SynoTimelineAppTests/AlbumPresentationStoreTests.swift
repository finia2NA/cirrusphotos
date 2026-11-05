import AppKit
import Foundation
import PhotoCache
import SynologyAPI
import SwiftUI
import XCTest
@testable import SynoTimelineApp

@MainActor
final class AlbumPresentationStoreTests: XCTestCase {
    func testSharingPasswordCheckboxPreservesWriteOnlyPasswordIntent() {
        var existing = SharingPasswordDraft(originallyRequired: true)
        XCTAssertEqual(existing.change, .unchanged)
        existing.required = false
        XCTAssertEqual(existing.change, .clear)
        existing.required = true
        XCTAssertEqual(existing.change, .unchanged)
        existing.value = "replacement"
        XCTAssertEqual(existing.change, .set("replacement"))

        var new = SharingPasswordDraft(originallyRequired: false)
        XCTAssertEqual(new.change, .unchanged)
        new.required = true
        XCTAssertTrue(new.needsPassword)
        new.value = "new password"
        XCTAssertEqual(new.change, .set("new password"))
        XCTAssertFalse(new.needsPassword)
        new.required = false
        XCTAssertEqual(new.change, .unchanged)
    }
    func testSectionsSortAndPersistIndependentlyWithoutChangingPins() {
        let suite = "AlbumSections.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account")
        store.add(.album(1)); store.add(.album(2))
        store.setExpanded(true, section: .shared)
        store.setSort(.newest)
        let albums = [AlbumSummary(id: 1, name: "A", itemCount: 1, createTime: 1, shared: true),
                      AlbumSummary(id: 2, name: "B", itemCount: 1, createTime: 2, shared: true),
                      AlbumSummary(id: 3, name: "C", itemCount: 1, shared: false)]
        XCTAssertEqual(store.section(albums, section: .shared).map(\.id), [2, 1])
        XCTAssertEqual(store.section(albums, section: .albums).map(\.id), [3])
        let moved = [AlbumSummary(id: 1, name: "A", itemCount: 1, shared: false)] + Array(albums.dropFirst())
        store.reconcile(moved, verified: true)
        XCTAssertEqual(store.pinnedIDs, [1, 2])
        XCTAssertEqual(store.section(moved, section: .albums).map(\.id), [1, 3])
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "account")
        XCTAssertTrue(restored.sharedExpanded)
        XCTAssertFalse(restored.albumsExpanded)
        XCTAssertEqual(restored.sort, .newest)
        XCTAssertEqual(restored.pinnedIDs, [1, 2])
        XCTAssertEqual(CardGrid.cardWidth(width: 448, count: 2), 190)
    }

    func testIncomingPinsKeepOwnerIdentityAndExistingPreferences() {
        let suite = "IncomingPins.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "albumPresentation.account"
        defaults.set(Data(#"{"version":2,"pinnedIDs":[1],"sharedExpanded":true,"albumsExpanded":false,"sort":"name"}"#.utf8), forKey: key)
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account")
        let incoming = PhotoCollectionDescriptor.incomingAlbum(ownerID: 7, albumID: 1)
        XCTAssertEqual(store.pinnedCollections, [.album(1)])
        XCTAssertTrue(store.sharedExpanded)
        store.add(incoming)
        store.setExpanded(true, section: .incoming)
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "account")
        XCTAssertEqual(restored.pinnedCollections, [.album(1), incoming])
        XCTAssertTrue(restored.expanded(.incoming))
        let albums = [AlbumSummary(id: 1, name: "Mine", itemCount: 0),
                      AlbumSummary(id: 1, name: "Theirs", itemCount: 0, ownerUserID: 7, isIncoming: true)]
        XCTAssertEqual(restored.section(albums, section: .albums).map(\.name), ["Mine"])
        XCTAssertEqual(restored.section(albums, section: .incoming).map(\.name), ["Theirs"])
        restored.reconcile(albums, verified: true)
        XCTAssertEqual(restored.pinnedCollections, [.album(1), incoming])
    }

    func testSharingStatusUsesTopLevelFlagAndServerPrivacy() {
        let grant = AlbumSharingPermission(photosUserID: 11, principalID: 1036, name: "Person", role: "view", type: "user")
        let info = AlbumSharingInfo(privacyType: "public-download", isExpired: true, permission: [grant], reference: "stale")
        let shared = AlbumHeaderModel(album: AlbumSummary(id: 1, name: "A", itemCount: 0, shared: true, sharingInfo: info))
        XCTAssertEqual(shared.sharingStatus, "Sharing expired")
        XCTAssertEqual(shared.recipients, [grant])
        let disabled = AlbumHeaderModel(album: AlbumSummary(id: 1, name: "A", itemCount: 0, shared: false, sharingInfo: info))
        XCTAssertEqual(disabled.sharingStatus, "Not shared")
        XCTAssertTrue(disabled.recipients.isEmpty)
    }

    func testAlbumDragUsesTheClickedCardIdentity() {
        var started: [Int] = []
        let suite = "AlbumDragSourceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account")
        let registry = AlbumDragRegistry()
        let cards = HStack(spacing: 20) {
            ForEach(1...3, id: \.self) { id in
                Color.gray.frame(width: 100, height: 100)
                    .background(AlbumDragSourceView { _, _ in
                        started.append(id)
                        let nonce = registry.register(collection: .album(Int64(id)), namespace: "account")
                        defer { registry.remove(nonce) }
                        return registry.insert(nonce.uuidString, namespace: "account", before: nil, presentation: store)
                    })
            }
        }.frame(width: 340, height: 100)
        let host = NSHostingView(rootView: cards)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
        host.layoutSubtreeIfNeeded()
        func anchors(_ view: NSView) -> [AlbumDragAnchorView] {
            (view as? AlbumDragAnchorView).map { [$0] } ?? view.subviews.flatMap(anchors)
        }
        let sources = anchors(host)
        XCTAssertEqual(sources.count, 3)
        for x in [50.0, 170.0, 290.0] {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 50), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: x + 10, y: 50), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            for source in sources { _ = source.handleMouseEvent(down) }
            for source in sources { _ = source.handleMouseEvent(drag) }
        }
        XCTAssertEqual(started, [1, 2, 3])
        XCTAssertEqual(store.pinnedIDs, [1, 2, 3])
    }
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
        store.add(.album(2)); store.add(.album(1)); store.add(.album(2))
        XCTAssertEqual(store.pinnedIDs, [2, 1])
        store.move(.album(1), before: .album(2))
        store.configure(namespace: "server-a-bob")
        XCTAssertEqual(store.pinnedIDs, [])
        store.add(.album(9))
        store.configure(namespace: "server-b-alice")
        XCTAssertEqual(store.pinnedIDs, [])
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "server-a-alice")
        XCTAssertEqual(restored.pinnedIDs, [1, 2])
        restored.remove(.album(1)); restored.remove(.album(1))
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
        store.add(.album(1)); store.add(.album(3))
        store.insert(.album(2), before: .album(3))
        store.insert(.album(3), before: .album(1))
        store.insert(.album(3), before: .album(3))
        XCTAssertEqual(store.pinnedIDs, [3, 1, 2])
        store.insert(.album(3), before: nil)
        store.insert(.album(9), before: .album(100))
        let restored = AlbumPresentationStore(defaults: defaults)
        restored.configure(namespace: "account")
        XCTAssertEqual(restored.pinnedIDs, [1, 2, 3])
    }

    func testSpringTargetOpensOnlyForAnActiveLocalSelection() async {
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites(.personal), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let registry = SelectionDragRegistry()
        let nonce = registry.register(.init(selection: selection, sourceAlbumID: nil, namespace: "a"))
        defer { registry.remove(nonce) }
        let target = AlbumOverviewSpringTarget.TargetView()
        target.selections = registry
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
        XCTAssertNotNil(registry.lookup(nonce.uuidString, namespace: "a"))
    }

    func testDragEndObserverSurvivesAcceptedSelectionAndFiresOnce() {
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites(.personal), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let registry = SelectionDragRegistry()
        let nonce = registry.register(.init(selection: selection, sourceAlbumID: nil, namespace: "a"))
        var ended = 0
        XCTAssertFalse(registry.observeEnd(nonce.uuidString, namespace: "b") { ended += 1 })
        XCTAssertTrue(registry.observeEnd(nonce.uuidString, namespace: "a") { ended += 1 })
        XCTAssertNotNil(registry.take(nonce.uuidString, namespace: "a"))
        XCTAssertEqual(ended, 0)
        registry.remove(nonce)
        registry.remove(nonce)
        XCTAssertEqual(ended, 1)
    }

    func testSelectionNonceIsScopedAndConsumedOnce() {
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites(.personal), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let registry = SelectionDragRegistry()
        let nonce = registry.register(.init(selection: selection, sourceAlbumID: nil, namespace: "a"))
        XCTAssertNil(registry.take(nonce.uuidString, namespace: "b"))
        XCTAssertNil(AlbumDragRegistry().album(nonce.uuidString, namespace: "a"))
        XCTAssertEqual(registry.take(nonce.uuidString, namespace: "a")?.selection.knownItemIDsByOrdinal[1], 42)
        XCTAssertNil(registry.take(nonce.uuidString, namespace: "a"))
        registry.remove(nonce)
    }

    func testAlbumNonceIsScopedAndRemoved() {
        let registry = AlbumDragRegistry()
        let nonce = registry.register(collection: .album(42), namespace: "account-a")
        XCTAssertEqual(registry.album(nonce.uuidString, namespace: "account-a"), .album(42))
        XCTAssertNil(registry.album(nonce.uuidString, namespace: "account-b"))
        XCTAssertNil(registry.album(UUID().uuidString, namespace: "account-a"))
        let suite = "AlbumDispatchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account-a")
        XCTAssertFalse(registry.insert(nonce.uuidString, namespace: "account-b", before: nil, presentation: store))
        XCTAssertTrue(registry.insert(nonce.uuidString, namespace: "account-a", before: nil, presentation: store))
        XCTAssertEqual(store.pinnedIDs, [42])
        registry.remove(nonce)
        XCTAssertNil(registry.album(nonce.uuidString, namespace: "account-a"))
    }

    func testProvisionalOrFailedListDoesNotPruneAndVerifiedListDoes() {
        let suite = "AlbumPresentationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumPresentationStore(defaults: defaults)
        store.configure(namespace: "account")
        store.add(.album(1)); store.add(.album(2))
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

extension AlbumPresentationStoreTests {
    func testSharingExpiryUsesInclusiveLocalDayAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12)))
        XCTAssertEqual(SharingExpiry.endOfDay(date, calendar: calendar), 1794956399)
        let dst = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let nextDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 30)))
        XCTAssertEqual(SharingExpiry.endOfDay(dst, calendar: calendar), Int64(nextDay.timeIntervalSince1970) - 1)
    }
}
