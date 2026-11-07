import Foundation
import PhotoCache
import SynologyAPI
import XCTest
@testable import CirrusPhotosApp

@MainActor
final class ActivityCenterTests: XCTestCase {
    @MainActor private final class RetryState {
        var retried: [[String]] = []
        var accepts = true
    }

    private var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private lazy var center = ActivityCenter(now: { [unowned self] in self.date })

    private func photo(_ id: Int64) throws -> ActivityItem {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"filename\":\"p\(id).jpg\",\"time\":1,\"type\":\"photo\"}".utf8))
        return ActivityItem(photo: item, collection: .library(.personal))
    }

    private func photos(_ ids: ClosedRange<Int64>) throws -> [ActivityItem] { try ids.map(photo) }

    func testSucceededChangeMovesToHistoryAndTransferStays() throws {
        let change = center.begin(.favorite(true), items: try photos(1...2))
        let download = center.begin(.download(name: "a.jpg"))
        XCTAssertEqual(center.inProgress.count, 1)
        XCTAssertEqual(center.transfers.count, 1)
        change.succeed()
        download.succeed(savedURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        XCTAssertTrue(center.inProgress.isEmpty)
        XCTAssertEqual(center.transfers.map(\.phase), [.succeeded])
        XCTAssertEqual(center.history.map(\.title), ["Downloaded a.jpg", "Favorited 2 photos"])
    }

    func testFailureStaysAndOpensPanel() throws {
        let handle = center.begin(.favorite(true), items: try photos(1...3))
        handle.fail(RepositoryError.server(.transport("offline")), operation: "Favorites")
        XCTAssertEqual(center.attention.count, 1)
        XCTAssertEqual(center.attention[0].title, "Favoriting failed for 3 photos")
        XCTAssertEqual(center.unseenFailureIDs, [handle.id])
        XCTAssertTrue(center.isPresented)
        XCTAssertEqual(center.selectedTab, .activity)
        XCTAssertEqual(center.highlightedEntryID, handle.id)
        XCTAssertEqual(center.history.first?.outcome, .failed)
        center.markFailuresSeen()
        XCTAssertTrue(center.unseenFailureIDs.isEmpty)
    }

    func testPartialFailureKeepsFailedItemsAndSummarizesHistory() throws {
        let items = try photos(1...5)
        let handle = center.begin(.favorite(true), items: items)
        handle.progress(completed: 2)
        XCTAssertEqual(center.inProgress[0].title, "Favoriting 3 photos")
        handle.fail(RepositoryError.server(.http(500)), operation: "Favorites", failedItems: Array(items[3...]))
        XCTAssertEqual(center.attention[0].failedItems.map(\.photoID), [4, 5])
        XCTAssertEqual(center.attention[0].title, "Favoriting failed for 2 photos")
        XCTAssertEqual(center.history[0].outcome, .partial(failed: 2))
        XCTAssertEqual(center.history[0].title, "Favorited 3 of 5 photos")
    }

    func testUnconfirmedFailureIsMarked() {
        let handle = center.begin(.deleteItems, totalCount: 3)
        handle.fail(RepositoryError.unconfirmed("Unknown"), operation: "Deletion")
        XCTAssertEqual(center.attention[0].phase, .unconfirmed)
        XCTAssertEqual(center.history[0].outcome, .unconfirmed)
        XCTAssertTrue(center.attention[0].detail?.contains("Refresh to check") == true)
    }

    func testCancellationIsNotAFailure() {
        let handle = center.begin(.download(name: "a.jpg"))
        handle.fail(CancellationError(), operation: "Download")
        XCTAssertTrue(center.attention.isEmpty)
        XCTAssertEqual(center.transfers[0].phase, .cancelled)
        XCTAssertFalse(center.isPresented)
        XCTAssertEqual(center.history[0].outcome, .cancelled)
    }

    func testClearKeepsRunningWorkAndDismissRefusesIt() throws {
        let running = center.begin(.download(name: "running"))
        let queued = center.begin(.addToAlbum(id: 1, name: "Trip"), items: try photos(1...1), queued: true)
        center.begin(.download(name: "done")).succeed()
        center.begin(.favorite(true), items: try photos(2...2)).fail(RepositoryError.busy("Busy"), operation: "Favorites")
        center.dismiss(running.id)
        XCTAssertEqual(center.entries.count, 4)
        center.clearActivity()
        XCTAssertEqual(Set(center.entries.map(\.id)), [running.id, queued.id])
        XCTAssertTrue(center.unseenFailureIDs.isEmpty)
        XCTAssertEqual(center.entries.first { $0.id == queued.id }?.detail, "Waiting…")
        XCTAssertEqual(center.history.count, 2)
        center.clearHistory()
        XCTAssertTrue(center.history.isEmpty)
    }

    func testDismissingLastFailedItemRemovesEntry() throws {
        let items = try photos(1...2)
        let handle = center.begin(.favorite(false), items: items)
        handle.fail(RepositoryError.busy("Busy"), operation: "Favorites")
        center.dismiss(itemID: items[0].id, from: handle.id)
        XCTAssertEqual(center.attention[0].failedItems.map(\.id), [items[1].id])
        center.dismiss(itemID: items[1].id, from: handle.id)
        XCTAssertTrue(center.entries.isEmpty)
    }

    func testHistoryMergesConsecutiveMatchingChangesWithinWindow() throws {
        center.begin(.favorite(true), items: try photos(1...1)).succeed()
        date += 30
        center.begin(.favorite(true), items: try photos(2...3)).succeed()
        XCTAssertEqual(center.history.count, 1)
        XCTAssertEqual(center.history[0].title, "Favorited 3 photos")
        XCTAssertEqual(center.history[0].items.count, 3)

        date += 30
        center.begin(.favorite(false), items: try photos(4...4)).succeed()
        date += 61
        center.begin(.favorite(false), items: try photos(5...5)).succeed()
        center.begin(.download(name: "a.jpg")).succeed()
        center.begin(.download(name: "a.jpg")).succeed()
        XCTAssertEqual(center.history.map(\.title), ["Downloaded a.jpg", "Downloaded a.jpg", "Unfavorited 1 photo",
                                                     "Unfavorited 1 photo", "Favorited 3 photos"])
    }

    func testPartialRecordsDoNotMerge() throws {
        center.begin(.favorite(true), items: try photos(1...1)).succeed()
        let items = try photos(2...3)
        center.begin(.favorite(true), items: items).fail(RepositoryError.busy("Busy"), operation: "Favorites", failedItems: [items[0]])
        center.begin(.favorite(true), items: try photos(4...4)).succeed()
        XCTAssertEqual(center.history.map(\.title), ["Favorited 1 photo", "Favorited 1 of 2 photos", "Favorited 1 photo"])
    }

    func testRetryRemovesChosenItemsAndRestoresWhenRetryCannotStart() throws {
        let items = try photos(1...3)
        let state = RetryState()
        let handle = center.begin(.favorite(true), items: items, retry: { items in
            state.retried.append(items.map(\.id))
            return state.accepts
        })
        handle.fail(RepositoryError.busy("Busy"), operation: "Favorites")
        center.retry(handle.id, itemIDs: [items[0].id])
        XCTAssertEqual(state.retried, [[items[0].id]])
        XCTAssertEqual(center.attention[0].failedItems.map(\.id), [items[1].id, items[2].id])

        state.accepts = false
        center.retry(handle.id)
        XCTAssertEqual(state.retried.last, [items[1].id, items[2].id])
        XCTAssertEqual(center.attention[0].failedItems.map(\.id), [items[1].id, items[2].id])

        state.accepts = true
        center.retryAllFailed()
        XCTAssertTrue(center.attention.isEmpty)
    }

    func testNewerFavoriteSupersedesOlderFailure() throws {
        let items = try photos(1...2)
        center.begin(.favorite(true), items: items).fail(RepositoryError.busy("Busy"), operation: "Favorites")
        center.begin(.rating(3), items: [items[0]]).succeed()
        XCTAssertEqual(center.attention[0].failedItems.count, 2)
        center.begin(.favorite(false), items: [items[0]])
        XCTAssertEqual(center.attention[0].failedItems.map(\.id), [items[1].id])
        center.begin(.favorite(true), items: [items[1]])
        XCTAssertTrue(center.attention.isEmpty)
    }

    func testAutoPresentIsThrottledAndSuppressible() {
        center.begin(.deleteItems).fail(RepositoryError.busy("Busy"), operation: "Deletion")
        XCTAssertTrue(center.isPresented)
        center.isPresented = false
        date += 5
        center.begin(.deleteItems).fail(RepositoryError.busy("Busy"), operation: "Deletion")
        XCTAssertFalse(center.isPresented)
        XCTAssertEqual(center.unseenFailureIDs.count, 2)
        date += 10
        center.canAutoPresent = false
        center.begin(.deleteItems).fail(RepositoryError.busy("Busy"), operation: "Deletion")
        XCTAssertFalse(center.isPresented)
        center.canAutoPresent = true
        center.begin(.deleteItems).fail(RepositoryError.busy("Busy"), operation: "Deletion")
        XCTAssertTrue(center.isPresented)
    }

    func testLimitsDropOldestSettledEntriesAndHistory() {
        let running = center.begin(.download(name: "running"))
        for index in 0..<(ActivityCenter.settledEntryLimit + 5) {
            center.begin(.download(name: "\(index)")).succeed()
        }
        XCTAssertEqual(center.entries.count { $0.phase.isSettled }, ActivityCenter.settledEntryLimit)
        XCTAssertTrue(center.entries.contains { $0.id == running.id })
        XCTAssertEqual(center.transfers.first?.title, "Downloaded \(ActivityCenter.settledEntryLimit + 4)")
        for index in 0..<ActivityCenter.historyLimit {
            center.record(.renamePerson(name: "\(index)"), outcome: .succeeded)
        }
        XCTAssertEqual(center.history.count, ActivityCenter.historyLimit)
        XCTAssertEqual(center.history.first?.title, "Renamed person to \(ActivityCenter.historyLimit - 1)")
    }

    func testSettledHandleIgnoresLaterUpdates() {
        let handle = center.begin(.download(name: "a.jpg"))
        handle.succeed()
        handle.status("late")
        handle.fail(RepositoryError.busy("Busy"), operation: "Download")
        XCTAssertEqual(center.transfers[0].phase, .succeeded)
        XCTAssertNil(center.transfers[0].status)
        XCTAssertEqual(center.history.count, 1)
    }

    func testDiscardLeavesNoTrace() {
        center.begin(.addToAlbum(id: 1, name: "Trip")).discard()
        XCTAssertTrue(center.entries.isEmpty)
        XCTAssertTrue(center.history.isEmpty)
    }

    func testNoticesReplaceByKeyAndStayOutOfHistory() {
        center.notice("Login failed", detail: "Offline. Showing cached content.", key: "connection")
        center.notice("Connected to the NAS again", key: "connection")
        center.notice("Couldn't load full resolution of a.jpg", detail: "Timed out", key: "viewer:1")
        XCTAssertEqual(center.notices.map(\.title), ["Couldn't load full resolution of a.jpg", "Connected to the NAS again"])
        XCTAssertEqual(center.notices.first?.detail, "Timed out")
        XCTAssertTrue(center.attention.isEmpty)
        XCTAssertTrue(center.transfers.isEmpty)
        XCTAssertTrue(center.history.isEmpty)
        XCTAssertFalse(center.isPresented)
        center.clearActivity()
        XCTAssertTrue(center.notices.isEmpty)
    }

    func testRefreshFailureNeedsAttentionButNeverEntersHistory() {
        center.begin(.refresh).succeed()
        XCTAssertTrue(center.entries.isEmpty)
        let failed = center.begin(.refresh, retry: { _ in true })
        failed.fail(RepositoryError.server(.transport("offline")), operation: "Refresh")
        XCTAssertEqual(center.attention.map(\.title), ["Refresh failed"])
        XCTAssertTrue(center.isPresented)
        XCTAssertTrue(center.history.isEmpty)
        center.resolveFailures(of: .refresh)
        XCTAssertTrue(center.attention.isEmpty)
        XCTAssertTrue(center.unseenFailureIDs.isEmpty)
    }

    func testRevealOnlyForTheShownCollection() throws {
        let item = try photo(1)
        var revealed: [Int64] = []
        center.revealHandler = { photo, _ in revealed.append(photo.id) }
        center.revealableCollection = .favorites(.personal)
        XCTAssertFalse(center.canReveal(item))
        center.reveal(item)
        center.revealableCollection = .library(.personal)
        XCTAssertTrue(center.canReveal(item))
        XCTAssertFalse(center.canReveal(ActivityItem(file: URL(fileURLWithPath: "/tmp/a.jpg"))))
        center.reveal(item)
        XCTAssertEqual(revealed, [1])
    }

    func testWording() {
        XCTAssertEqual(ActivityWording.text(.favorite(true), .running, count: 1), "Favoriting 1 photo")
        XCTAssertEqual(ActivityWording.text(.rotate(.counterClockwise), .done, count: 2), "Rotated 2 photos left")
        XCTAssertEqual(ActivityWording.text(.rating(0), .done, count: 2), "Cleared rating of 2 photos")
        XCTAssertEqual(ActivityWording.text(.rating(3), .done, count: 1), "Rated 1 photo ★★★")
        XCTAssertEqual(ActivityWording.text(.addTags(["a", "b"]), .done, count: 2), "Tagged 2 photos “a, b”")
        XCTAssertEqual(ActivityWording.text(.addToAlbum(id: 1, name: "Trip"), .done, count: 1), "Added 1 item to Trip")
        XCTAssertEqual(ActivityWording.text(.upload(destination: "Trip"), .failed, count: 2), "Uploading failed for 2 files")
        XCTAssertEqual(ActivityWording.text(.deleteItems, .done, count: 4, of: 5), "Deleted 4 of 5 items")
    }
}
