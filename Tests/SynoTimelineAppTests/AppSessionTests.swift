import AppKit
import Foundation
import PhotoCache
import SynologyAPI
import TransportTestSupport
import XCTest
@testable import SynoTimelineApp

@MainActor
final class AppSessionTests: XCTestCase {
    func testEndCancelsTransfersDropsHandlesAndRetriesAndRefusesNewWork() async throws {
        let root = temporaryTestRoot("AppSessionEnd")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = BlockingDownloadTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let session = AppSession(preferences: AppPreferences(), repository: repository)
        let activity = session.activity
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\"}".utf8))
        let source = PhotoDownloadSource.item(photo, collection: .library(.personal))

        session.downloads.start(repository: repository, source: source, kind: .original, directory: root)
        let started = await waitUntil { await transport.started }
        XCTAssertTrue(started)
        XCTAssertTrue(session.hasActiveTransfers)
        activity.begin(.download(name: "earlier"), retry: { _ in true })
            .fail(URLError(.timedOut), operation: "Download", logs: false)
        XCTAssertTrue(activity.hasRetryableFailures)

        let namespace = repository.namespace
        let albumNonce = session.drags.albums.register(collection: .album(7), namespace: namespace)
        let timeline = TimelineSnapshot(sections: [])
        let selection = PhotoSelectionSnapshot(collection: .favorites(.personal), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 1), knownItemIDsByOrdinal: [1: 42])
        let selectionNonce = session.drags.selections.register(.init(selection: selection, sourceAlbumID: nil, namespace: namespace))
        var dragEnded = 0
        XCTAssertTrue(session.drags.selections.observeEnd(selectionNonce.uuidString, namespace: namespace) { dragEnded += 1 })

        session.end()

        XCTAssertTrue(session.isEnded)
        XCTAssertNil(session.repository)
        XCTAssertThrowsError(try session.start())
        XCTAssertTrue(activity.entries.allSatisfy { $0.phase.isSettled && $0.cancel == nil && $0.retry == nil })
        XCTAssertFalse(activity.hasRetryableFailures)
        XCTAssertEqual(activity.entries.first { $0.kind == .download(name: "a.dng") }?.phase, .cancelled)
        XCTAssertNil(session.drags.albums.album(albumNonce.uuidString, namespace: namespace))
        XCTAssertNil(session.drags.selections.lookup(selectionNonce.uuidString, namespace: namespace))
        XCTAssertEqual(dragEnded, 1)
        let drained = await waitUntil { !session.downloads.hasActiveJobs }
        XCTAssertTrue(drained)
        XCTAssertEqual(activity.entries.first { $0.kind == .download(name: "a.dng") }?.phase, .cancelled)

        let entryCount = activity.entries.count
        session.downloads.start(repository: repository, source: source, kind: .original, directory: root)
        session.downloads.edit(repository: repository, snapshot: nil, selection: nil, item: photo,
                               collection: .library(.personal), applicationURL: URL(fileURLWithPath: "/Applications/Preview.app"))
        XCTAssertFalse(session.uploads.start([root.appendingPathComponent("b.jpg")], repository: repository,
                                             destination: .timeline(.personal)) {})
        XCTAssertEqual(activity.entries.count, entryCount)
        XCTAssertFalse(session.hasActiveTransfers)

        let promise = expectation(description: "late file promise fails")
        let file = PromisedFile(itemID: photo.id, filename: "a.dng")
        let batch = PhotoPromiseBatch(payload: PhotoDragPayload(repository: repository, source: source, count: 1, delivery: .files([file])))
        session.downloads.fulfillPromise(batch, file: file, destination: root.appendingPathComponent("late.dng")) { error in
            XCTAssertTrue(error is CancellationError)
            promise.fulfill()
        }
        await fulfillment(of: [promise], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late.dng").path))
        XCTAssertEqual(activity.entries.count, entryCount)
    }

    func testPromiseDelegateFailsOnceItsSessionIsGone() async throws {
        let root = temporaryTestRoot("AppSessionPromise")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"),
                                                     transport: BlockingDownloadTransport())
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\"}".utf8))
        let file = PromisedFile(itemID: photo.id, filename: "a.dng")
        let payload = PhotoDragPayload(repository: repository, source: .item(photo, collection: .library(.personal)),
                                       count: 1, delivery: .files([file]))
        var session: AppSession? = AppSession(preferences: AppPreferences(), repository: repository)
        let delegate = PhotoPromiseDelegate(batch: PhotoPromiseBatch(payload: payload), file: file, name: "a.dng",
                                            downloads: session!.downloads)
        session?.end()
        session = nil
        let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)
        let failed = expectation(description: "promise fails")
        delegate.filePromiseProvider(provider, writePromiseTo: root.appendingPathComponent("late.dng")) { error in
            XCTAssertTrue(error is CancellationError)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 1)
    }

    func testThumbnailPollingStopsOnlyForItsOwnerAndAllOnEnd() throws {
        let root = temporaryTestRoot("AppSessionPolls")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"),
                                                     transport: BlockingDownloadTransport())
        let uploads = PhotoUploadManager(activity: ActivityCenter())
        let first = UUID(), second = UUID()
        // The first poll delay is seconds long, so every poll is still waiting here.
        uploads.pollThumbnails(of: [1], repository: repository, destination: .timeline(.personal), owner: first) {}
        uploads.pollThumbnails(of: [2], repository: repository, destination: .timeline(.personal), owner: second) {}
        uploads.pollThumbnails(of: [3], repository: repository, destination: .timeline(.personal), owner: nil) {}
        XCTAssertEqual(uploads.thumbnailPollCount, 3)
        uploads.cancelThumbnailPolling(owner: first)
        XCTAssertEqual(uploads.thumbnailPollCount, 2)
        uploads.cancelThumbnailPolling(owner: UUID())
        XCTAssertEqual(uploads.thumbnailPollCount, 2)
        uploads.end()
        XCTAssertEqual(uploads.thumbnailPollCount, 0)
        uploads.pollThumbnails(of: [4], repository: repository, destination: .timeline(.personal), owner: second) {}
        XCTAssertEqual(uploads.thumbnailPollCount, 0)
    }

    func testDragRegistryEndDropsHandlesButKeepsRunningSources() {
        let drags = LocalDragRegistry()
        let source = PhotoFileDragSource()
        drags.retain(source, id: UUID())
        let nonce = drags.albums.register(collection: .album(1), namespace: "a")
        drags.end()
        XCTAssertTrue(drags.isEnded)
        XCTAssertNil(drags.albums.album(nonce.uuidString, namespace: "a"))
        XCTAssertEqual(drags.activeSourceCount, 1)
    }
}

/// Blocks every download until its task is cancelled.
private actor BlockingDownloadTransport: TestPhotosTransport {
    private(set) var started = false
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> MediaResponse {
        started = true
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        space: PhotoSpace, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        started = true
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
