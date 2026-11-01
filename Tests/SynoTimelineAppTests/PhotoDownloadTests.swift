import AppKit
import Foundation
import PhotoCache
import SynologyAPI
import UniformTypeIdentifiers
import XCTest
@testable import SynoTimelineApp

final class PhotoDownloadDestinationTests: XCTestCase {
    @MainActor
    func testContextMenuRoutesEachRequestedDownloadMode() {
        _ = NSApplication.shared
        var selected: [(PhotoDownloadKind, Bool)] = []
        let menu = photoDownloadMenu { selected.append(($0, $1)) }
        XCTAssertEqual(menu.items.map(\.title), ["Download", "Download to…", "Download Compressed JPEG", "Download Compressed JPEG to…"])
        for index in 0..<4 { menu.performActionForItem(at: index) }
        XCTAssertEqual(selected.map { $0.0 }, [.original, .original, .compressedJPEG, .compressedJPEG])
        XCTAssertEqual(selected.map { $0.1 }, [false, true, false, true])
    }

    @MainActor
    func testAlbumDownloadUsesVerifiedItemsAndReportsEmptyAlbum() async throws {
        let root = temporaryTestRoot("AlbumDownload")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "photoDownloadDirectory")
        UserDefaults.standard.set(root.path, forKey: "photoDownloadDirectory")
        defer { UserDefaults.standard.set(previous, forKey: "photoDownloadDirectory") }
        let transport = AlbumDownloadMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let manager = PhotoDownloadManager()
        manager.start(repository: repository, source: .album(54), kind: .compressedJPEG, choose: false)
        let completed = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(completed)
        let ids = await transport.downloadedIDs
        let kind = await transport.kind
        XCTAssertEqual(ids, [1, 2])
        XCTAssertEqual(kind, .compressedJPEG)
        XCTAssertTrue(manager.jobs[0].status.contains("Saved to"))
        manager.start(repository: repository, source: .album(55), kind: .original, choose: false)
        let emptyCompleted = await waitUntil { manager.jobs.count == 2 && !manager.jobs[0].active }
        XCTAssertTrue(emptyCompleted)
        XCTAssertEqual(manager.jobs[0].status, "No eligible photos to download.")
    }

    @MainActor
    func testEditorMenuRoutesSelectedApplicationAndOther() {
        _ = NSApplication.shared
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        var chosen: URL?
        var other = false
        let menu = makeEditorMenu(applications: [app], onChoose: { chosen = $0 }, onOther: { other = true })
        XCTAssertEqual(menu.title, "Edit With")
        XCTAssertNotNil(menu.items.first?.image)
        XCTAssertEqual(menu.items.first?.image?.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(menu.items.first?.image?.isTemplate, false)
        XCTAssertEqual(menu.items.first?.preferredImageVisibility, .visible)
        XCTAssertEqual(menu.items.last?.title, "Other…")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(chosen, app)
        menu.performActionForItem(at: menu.numberOfItems - 1)
        XCTAssertTrue(other)
    }

    func testEditingDirectoryIsWithinDocuments() throws {
        let directory = try PhotoDownloadManager.editDirectory()
        XCTAssertEqual(directory.lastPathComponent, "SynoTimeline Edits")
        XCTAssertEqual(directory.deletingLastPathComponent(), FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
    }

    @MainActor
    func testEditDownloadsOriginalAndHandsOffPersistentCopy() async throws {
        let root = temporaryTestRoot("EditHandoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Edits")
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\"}".utf8))
        let application = URL(fileURLWithPath: "/Applications/Editor.app")
        var opened: URL?
        let manager = PhotoDownloadManager(editDirectoryProvider: { directory }, editorOpener: { file, app in
            XCTAssertEqual(app, application)
            opened = file
        })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, applicationURL: application)
        let finished = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(finished)
        let file = try XCTUnwrap(opened)
        XCTAssertEqual(file, directory.appendingPathComponent("a.dng"))
        XCTAssertEqual(try Data(contentsOf: file), Data("raw-image".utf8))
        let downloadedIDs = await transport.downloadedIDs
        let downloadedKind = await transport.kind
        XCTAssertEqual(downloadedIDs, [1])
        XCTAssertEqual(downloadedKind, .original)
        XCTAssertTrue(manager.jobs[0].status.contains("Saved to"))
    }

    @MainActor
    func testCachedOriginalIsCopiedForEditingWithoutDownloadingAgain() async throws {
        let root = temporaryTestRoot("CachedEditor")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Edits")
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":1,\"cache_key\":\"v1\"}}}".utf8))
        let resource = try XCTUnwrap(photo.fullImageResource)
        for await _ in await repository.fullImage(resource) {}
        var opened: URL?
        let manager = PhotoDownloadManager(editDirectoryProvider: { directory }, editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo,
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(finished)
        let file = try XCTUnwrap(opened)
        XCTAssertEqual(try Data(contentsOf: file), Data("raw-image".utf8))
        let downloads = await transport.downloadedIDs
        XCTAssertTrue(downloads.isEmpty)
        try Data("edited".utf8).write(to: file)
        var cached: Data?
        for await event in await repository.fullImage(resource, allowNetwork: false) {
            if case .value(let data, _) = event { cached = data }
        }
        XCTAssertEqual(cached, Data("raw-image".utf8))
    }

    @MainActor
    func testCachedLivePhotoStillIsUsedForEditingButNotForDownload() async throws {
        let root = temporaryTestRoot("CachedLivePhoto")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Edits")
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.heic\",\"time\":1,\"type\":\"photo\",\"live_type\":\"live\",\"additional\":{\"thumbnail\":{\"unit_id\":1,\"cache_key\":\"v1\"}}}".utf8))
        let resource = try XCTUnwrap(photo.fullImageResource)
        for await _ in await repository.fullImage(resource) {}
        let download = try await repository.cachedOriginalForDownload(photo)
        XCTAssertNil(download)
        var opened: URL?
        let manager = PhotoDownloadManager(editDirectoryProvider: { directory }, editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo,
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(finished)
        let file = try XCTUnwrap(opened)
        XCTAssertEqual(file.lastPathComponent, "a.heic")
        XCTAssertEqual(try Data(contentsOf: file), Data("raw-image".utf8))
        let downloads = await transport.downloadedIDs
        XCTAssertTrue(downloads.isEmpty)
    }

    @MainActor
    func testUncachedLivePhotoOpensStillInsteadOfDownloadArchive() async throws {
        let root = temporaryTestRoot("UncachedLivePhoto")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Edits")
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.heic\",\"time\":1,\"type\":\"photo\",\"live_type\":\"live\",\"additional\":{\"thumbnail\":{\"unit_id\":1,\"cache_key\":\"v1\"}}}".utf8))
        var opened: URL?
        let manager = PhotoDownloadManager(editDirectoryProvider: { directory }, editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo,
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(finished)
        let file = try XCTUnwrap(opened)
        XCTAssertEqual(file.lastPathComponent, "a.heic")
        XCTAssertEqual(try Data(contentsOf: file), Data("raw-image".utf8))
        let downloads = await transport.downloadedIDs
        XCTAssertTrue(downloads.isEmpty)
    }

    @MainActor
    func testCachedOriginalIsUsedOnlyForOriginalSingleDownloads() async throws {
        let root = temporaryTestRoot("CachedDownload")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = UserDefaults.standard.object(forKey: "photoDownloadDirectory")
        UserDefaults.standard.set(root.path, forKey: "photoDownloadDirectory")
        defer { UserDefaults.standard.set(previous, forKey: "photoDownloadDirectory") }
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":1,\"cache_key\":\"v1\"}}}".utf8))
        let resource = try XCTUnwrap(photo.fullImageResource)
        for await _ in await repository.fullImage(resource) {}
        let manager = PhotoDownloadManager()
        manager.start(repository: repository, source: .item(photo), kind: .original, choose: false)
        let originalFinished = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(originalFinished)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.dng")), Data("raw-image".utf8))
        let firstCalls = await transport.downloadedIDs
        XCTAssertTrue(firstCalls.isEmpty)
        manager.start(repository: repository, source: .item(photo), kind: .compressedJPEG, choose: false)
        let compressedFinished = await waitUntil { manager.jobs.count == 2 && !manager.jobs[0].active }
        XCTAssertTrue(compressedFinished)
        let kind = await transport.kind
        XCTAssertEqual(kind, .compressedJPEG)
    }

    @MainActor
    func testEditPreservesCopyWhenEditorFailsToOpen() async throws {
        let root = temporaryTestRoot("EditFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Edits")
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: EditingMockTransport())
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\"}".utf8))
        let manager = PhotoDownloadManager(editDirectoryProvider: { directory }, editorOpener: { _, _ in throw URLError(.cannotOpenFile) })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo,
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { !manager.jobs.isEmpty && !manager.jobs[0].active }
        XCTAssertTrue(finished)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("a.dng")), Data("raw-image".utf8))
        XCTAssertTrue(manager.jobs[0].status.contains("file saved to"))
    }

    @MainActor
    func testFilePromiseWaitsForDropAndWritesToRequestedLocation() async throws {
        let root = temporaryTestRoot("FilePromise")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\"}".utf8))
        let payload = PhotoDragPayload(repository: repository, source: .item(photo), count: 1, filename: "a.dng")
        let delegate = PhotoPromiseDelegate(payload: payload)
        let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: delegate)
        provider.userInfo = delegate
        XCTAssertEqual(delegate.filePromiseProvider(provider, fileNameForType: UTType.data.identifier), "a.dng")
        let before = await transport.downloadedIDs
        XCTAssertTrue(before.isEmpty)
        let destination = root.appendingPathComponent("dropped.dng")
        let finished = expectation(description: "file promise fulfilled")
        delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: destination), Data("raw-image".utf8))
        let after = await transport.downloadedIDs
        XCTAssertEqual(after, [1])
    }

    func testPromisedWriteFinishesWhileDestinationIsAlreadyCoordinated() async throws {
        let root = temporaryTestRoot("CoordinatedPromise")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        let destination = root.appendingPathComponent("result.jpg")
        try Data("image".utf8).write(to: source)
        let finished = expectation(description: "coordinated promise")
        DispatchQueue.global().async {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            coordinator.coordinate(writingItemAt: destination, options: [], error: &error) { url in
                let signal = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    defer { signal.signal() }
                    do { try PhotoDownloadManager.writePromise(source, destination: url, makeArchive: false) }
                    catch { XCTFail("Promised write failed: \(error)") }
                }
                XCTAssertEqual(signal.wait(timeout: .now() + 3), .success, "Nested coordination blocked the promised write")
            }
            XCTAssertNil(error)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 8)
        XCTAssertEqual(try Data(contentsOf: destination), Data("image".utf8))
    }

    func testPromisedWriteDoesNotOverwriteAndCanCreateZIP() throws {
        let root = temporaryTestRoot("PromiseDestination")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        let destination = root.appendingPathComponent("Photos.zip")
        try Data("image".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)
        XCTAssertThrowsError(try PhotoDownloadManager.writePromise(source, destination: destination, makeArchive: true))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        try FileManager.default.removeItem(at: destination)
        try PhotoDownloadManager.writePromise(source, destination: destination, makeArchive: true)
        let bytes = try Data(contentsOf: destination)
        XCTAssertTrue(bytes.starts(with: [0x50, 0x4b]))
    }

    @MainActor
    func testDragPreviewStaysBoundedForLargeSelection() {
        let preview = PhotoFileDragSource.dragPreview(images: Array(repeating: NSImage(size: NSSize(width: 1, height: 1)), count: 100), count: 100_000, cropsToSquare: false)
        XCTAssertLessThanOrEqual(preview.size.width, 100)
        XCTAssertLessThanOrEqual(preview.size.height, 100)
    }

    @MainActor
    func testDragThumbnailPreservesAspectOrUsesCenteredSquareCrop() {
        for size in [NSSize(width: 600, height: 400), NSSize(width: 400, height: 600)] {
            let fitted = PhotoFileDragSource.thumbnailSize(for: size, cropsToSquare: false)
            XCTAssertEqual(fitted.width / fitted.height, size.width / size.height, accuracy: 0.0001)
            XCTAssertEqual(PhotoFileDragSource.sourceRect(for: size, cropsToSquare: false), NSRect(origin: .zero, size: size))
            let cropped = PhotoFileDragSource.sourceRect(for: size, cropsToSquare: true)
            XCTAssertEqual(cropped.width, min(size.width, size.height))
            XCTAssertEqual(cropped.height, cropped.width)
            XCTAssertEqual(cropped.midX, size.width / 2)
            XCTAssertEqual(cropped.midY, size.height / 2)
            let square = PhotoFileDragSource.thumbnailSize(for: size, cropsToSquare: true)
            XCTAssertEqual(square.width, square.height)
        }
    }

    @MainActor
    func testCloseGuardPreservesExistingWindowDelegate() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let original = OriginalCloseDelegate()
        window.delegate = original
        let view = DownloadCloseGuardView(frame: .zero)
        window.contentView?.addSubview(view)
        let delegate = window.delegate
        XCTAssertTrue(delegate is DownloadWindowDelegate)
        XCTAssertEqual(delegate?.windowShouldClose?(window), true)
        XCTAssertEqual(original.closeChecks, 1)
    }

    func testSavingPreservesExistingFilesAndCopiesCompleteBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: root.appendingPathComponent("download.zip"))
        let result = try PhotoDownloadManager.save(source, filename: "download.zip", directory: root)
        XCTAssertEqual(result.lastPathComponent, "download 1.zip")
        XCTAssertEqual(try Data(contentsOf: result), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("download.zip")), Data("old".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".syno-") })
    }
}

@MainActor
private final class OriginalCloseDelegate: NSObject, NSWindowDelegate {
    var closeChecks = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeChecks += 1; return true }
}

private actor EditingMockTransport: PhotosTransport {
    private(set) var downloadedIDs: [Int64] = []
    private(set) var kind: PhotoDownloadKind?
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> FullImageResponse {
        FullImageResponse(data: Data("raw-image".utf8), etag: nil, lastModified: nil)
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        downloadedIDs = itemIDs
        self.kind = kind
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("a.dng")
        try Data("raw-image".utf8).write(to: file)
        return PhotoDownloadResponse(temporaryURL: file, filename: "a.dng")
    }
}

private actor AlbumDownloadMockTransport: PhotosTransport {
    var downloadedIDs: [Int64] = []
    var kind: PhotoDownloadKind?
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        guard albumID == 54 else { return [] }
        return Array([DayTimelineEntry(id: 1, time: 1711929602), DayTimelineEntry(id: 2, time: 1711929601),
                      DayTimelineEntry(id: 3, time: 1711929600)].dropFirst(offset).prefix(limit))
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let json = """
        [{"id":1,"time":1711929602,"type":"photo"},
         {"id":2,"time":1711929601,"type":"photo","live_type":"live"},
         {"id":3,"time":1711929600,"type":"video"}]
        """
        let items = try JSONDecoder().decode([PhotoItem].self, from: Data(json.utf8))
        return CollectionBatchResult(items: Array(items.dropFirst(request.offset).prefix(request.limit)), profile: fields)
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        downloadedIDs = itemIDs; self.kind = kind
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("album.zip")
        try Data("download".utf8).write(to: file)
        return PhotoDownloadResponse(temporaryURL: file, filename: "album.zip")
    }
}
