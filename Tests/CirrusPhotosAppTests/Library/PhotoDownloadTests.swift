import AppKit
import Foundation
import PhotoCache
import SynologyAPI
import UniformTypeIdentifiers
import XCTest
@testable import CirrusPhotosApp

final class PhotoDownloadDestinationTests: XCTestCase {
    func testIncomingDownloadCommandsRequireVerifiedDownloadGrant() {
        let source = PhotoCollectionDescriptor.incomingAlbum(ownerID: 7, albumID: 42)
        let viewer = AlbumSummary(id: 42, name: "Shared", itemCount: 1, ownerUserID: 7, isIncoming: true)
        let downloader = AlbumSummary(id: 42, name: "Shared", itemCount: 1, ownerUserID: 7, isIncoming: true, recipientCanDownload: true)
        XCTAssertFalse(CollectionCapabilities(source: source, incomingAlbums: [downloader], incomingAlbumsVerified: false).allowsDownloads)
        XCTAssertFalse(CollectionCapabilities(source: source, incomingAlbums: [viewer], incomingAlbumsVerified: true).allowsDownloads)
        XCTAssertTrue(CollectionCapabilities(source: source, incomingAlbums: [downloader], incomingAlbumsVerified: true).allowsDownloads)
        XCTAssertFalse(CollectionCapabilities(source: .incomingAlbum(ownerID: 8, albumID: 42), incomingAlbums: [downloader], incomingAlbumsVerified: true).allowsDownloads)
    }

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
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity)
        manager.start(repository: repository, source: .album(54), kind: .compressedJPEG, choose: false)
        let completed = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(completed)
        let ids = await transport.downloadedIDs
        let kind = await transport.kind
        XCTAssertEqual(ids, [1, 2])
        XCTAssertEqual(kind, .compressedJPEG)
        XCTAssertTrue((activity.entries[0].detail ?? "").contains("Saved to"))
        manager.start(repository: repository, source: .album(55), kind: .original, choose: false)
        let emptyCompleted = await waitUntil { activity.entries.count == 2 && activity.entries[0].phase.isSettled }
        XCTAssertTrue(emptyCompleted)
        XCTAssertEqual(activity.entries[0].detail, "No eligible photos to download.")
        XCTAssertEqual(activity.entries[0].phase, .failed)
    }

    @MainActor
    func testAlbumCardDownloadRetainsSharedMemberAuthority() async throws {
        let root = temporaryTestRoot("SharedAlbumDownload")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "photoDownloadDirectory")
        UserDefaults.standard.set(root.path, forKey: "photoDownloadDirectory")
        defer { UserDefaults.standard.set(previous, forKey: "photoDownloadDirectory") }
        let transport = AlbumDownloadMockTransport(origin: .shared)
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
            cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity)
        manager.start(repository: repository, source: .album(54), kind: .compressedJPEG, choose: false)
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(finished)
        let space = await transport.downloadedSpace
        let ids = await transport.downloadedIDs
        XCTAssertEqual(space, .shared)
        XCTAssertEqual(ids, [1, 2])
        XCTAssertTrue((activity.entries[0].detail ?? "").contains("Saved to"))
    }

    @MainActor
    func testEditorPreservesVerifiedPersonalAlbumHandoff() async throws {
        let root = temporaryTestRoot("PersonalAlbumEditor")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumDownloadMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
            cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try await transport.albumItems(ids: [1], albumID: 54)[0]
        var opened: URL?
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { root.appendingPathComponent("Edits") },
            editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .album(54),
            applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(finished)
        XCTAssertNotNil(opened)
        let space = await transport.downloadedSpace
        XCTAssertEqual(space, .personal)
    }

    @MainActor
    func testEditorRejectsSharedAlbumMemberBeforePersonalCacheOrDownload() async throws {
        let root = temporaryTestRoot("SharedAlbumEditor")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumDownloadMockTransport(origin: .shared)
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
            cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try await transport.albumItems(ids: [1], albumID: 54)[0]
        var opened = false
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { root.appendingPathComponent("Edits") },
            editorOpener: { _, _ in opened = true })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .album(54),
            applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(finished)
        XCTAssertFalse(opened)
        let ids = await transport.downloadedIDs
        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue((activity.entries[0].detail ?? "").contains("Personal Space"))
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
        XCTAssertEqual(directory.lastPathComponent, "Cirrus Photos Edits")
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
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { directory }, editorOpener: { file, app in
            XCTAssertEqual(app, application)
            opened = file
        })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .library(.personal), applicationURL: application)
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(finished)
        let file = try XCTUnwrap(opened)
        XCTAssertEqual(file, directory.appendingPathComponent("a.dng"))
        XCTAssertEqual(try Data(contentsOf: file), Data("raw-image".utf8))
        let downloadedIDs = await transport.downloadedIDs
        let downloadedKind = await transport.kind
        XCTAssertEqual(downloadedIDs, [1])
        XCTAssertEqual(downloadedKind, .original)
        XCTAssertTrue((activity.entries[0].detail ?? "").contains("Saved to"))
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
        let resource = try XCTUnwrap(photo.fullImageResource(in: .space(.personal)))
        for await _ in await repository.fullImage(resource) {}
        var opened: URL?
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { directory }, editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .library(.personal),
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
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
        let resource = try XCTUnwrap(photo.fullImageResource(in: .space(.personal)))
        for await _ in await repository.fullImage(resource) {}
        let download = try await repository.cachedOriginalForDownload(photo, collection: .library(.personal))
        XCTAssertNil(download)
        var opened: URL?
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { directory }, editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .library(.personal),
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
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
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { directory }, editorOpener: { file, _ in opened = file })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .library(.personal),
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
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
        let resource = try XCTUnwrap(photo.fullImageResource(in: .space(.personal)))
        for await _ in await repository.fullImage(resource) {}
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity)
        manager.start(repository: repository, source: .item(photo, collection: .library(.personal)), kind: .original, choose: false)
        let originalFinished = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(originalFinished)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.dng")), Data("raw-image".utf8))
        let firstCalls = await transport.downloadedIDs
        XCTAssertTrue(firstCalls.isEmpty)
        manager.start(repository: repository, source: .item(photo, collection: .library(.personal)), kind: .compressedJPEG, choose: false)
        let compressedFinished = await waitUntil { activity.entries.count == 2 && activity.entries[0].phase.isSettled }
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
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity, editDirectoryProvider: { directory }, editorOpener: { _, _ in throw URLError(.cannotOpenFile) })
        manager.edit(repository: repository, snapshot: nil, selection: nil, item: photo, collection: .library(.personal),
                     applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"))
        let finished = await waitUntil { activity.entries.first?.phase.isSettled == true }
        XCTAssertTrue(finished)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("a.dng")), Data("raw-image".utf8))
        XCTAssertTrue((activity.entries[0].detail ?? "").contains("File saved to"))
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
        let file = PromisedFile(itemID: 1, filename: "a.dng")
        let payload = PhotoDragPayload(repository: repository, source: .item(photo, collection: .library(.personal)), count: 1,
                                       delivery: .files([file]))
        let downloads = PhotoDownloadManager(activity: ActivityCenter())
        let delegate = PhotoPromiseDelegate(batch: PhotoPromiseBatch(payload: payload), file: file, name: "a.dng", downloads: downloads)
        let provider = LocalHandlePromiseProvider(fileType: UTType.data.identifier, delegate: delegate)
        provider.userInfo = delegate
        XCTAssertEqual(delegate.filePromiseProvider(provider, fileNameForType: UTType.data.identifier), "a.dng")
        let plainTypes = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: delegate)
            .writableTypes(for: NSPasteboard(name: .init("test.\(UUID())")))
        let registry = AlbumDragRegistry()
        let nonce = registry.register(collection: .album(7), namespace: repository.namespace)
        provider.localType = AlbumDragRegistry.type; provider.nonce = nonce
        let pasteboard = NSPasteboard(name: .init("test.\(UUID())"))
        defer { registry.remove(nonce); pasteboard.releaseGlobally() }
        let types = provider.writableTypes(for: pasteboard)
        XCTAssertTrue(types.contains(AlbumDragRegistry.type))
        XCTAssertTrue(Set(plainTypes).isSubset(of: Set(types)))
        XCTAssertEqual(provider.pasteboardPropertyList(forType: AlbumDragRegistry.type) as? String, nonce.uuidString)
        XCTAssertEqual(registry.album(nonce.uuidString, namespace: repository.namespace), .album(7))
        provider.localType = SelectionDragRegistry.type
        XCTAssertFalse(provider.writableTypes(for: pasteboard).contains(AlbumDragRegistry.type))
        XCTAssertTrue(provider.writableTypes(for: pasteboard).contains(SelectionDragRegistry.type))
        XCTAssertEqual(LocalHandleWriter(type: SelectionDragRegistry.type, nonce: nonce).writableTypes(for: pasteboard), [SelectionDragRegistry.type])

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

    @MainActor
    func testFolderPromiseHoldsSingletonOriginal() async throws {
        let root = temporaryTestRoot("FolderPromise")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"filename\":\"a.dng\",\"time\":1,\"type\":\"photo\"}".utf8))
        let payload = PhotoDragPayload(repository: repository, source: .item(photo, collection: .library(.personal)), count: 1,
                                       delivery: .folder(name: "Album"))
        XCTAssertEqual(payload.promises.map(\.type), [.folder])
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity)
        let destination = root.appendingPathComponent("Album")
        let finished = expectation(description: "album folder")
        manager.fulfillPromise(PhotoPromiseBatch(payload: payload), file: nil, destination: destination) { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(contents[0])), Data("raw-image".utf8))
        let ids = await transport.downloadedIDs
        XCTAssertEqual(ids, [1])
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
                    do { try PromisePlaceholder(destination: url, isDirectory: false).install(copyOf: source) }
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

    func testPromisedWriteDoesNotOverwrite() throws {
        let root = temporaryTestRoot("PromiseDestination")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        let destination = root.appendingPathComponent("photo copy.jpg")
        try Data("image".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)
        let placeholder = PromisePlaceholder(destination: destination, isDirectory: false)
        XCTAssertFalse(placeholder.hasPlaceholder)
        XCTAssertThrowsError(try placeholder.install(copyOf: source))
        placeholder.discard()
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
    }

    func testPlaceholderIsReplacedOnlyWhileUnchanged() throws {
        let root = temporaryTestRoot("PromisePlaceholder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        try Data("image".utf8).write(to: source)

        let destination = root.appendingPathComponent("placed.jpg")
        let placeholder = PromisePlaceholder(destination: destination, isDirectory: false)
        XCTAssertTrue(placeholder.hasPlaceholder)
        XCTAssertEqual(try Data(contentsOf: destination), Data())
        try placeholder.install(copyOf: source)
        XCTAssertEqual(try Data(contentsOf: destination), Data("image".utf8))

        // Someone else wrote to the placeholder: it is neither replaced nor removed.
        let taken = root.appendingPathComponent("taken.jpg")
        let other = PromisePlaceholder(destination: taken, isDirectory: false)
        try Data("theirs".utf8).write(to: taken)
        XCTAssertThrowsError(try other.install(copyOf: source))
        other.discard()
        XCTAssertEqual(try Data(contentsOf: taken), Data("theirs".utf8))

        // An unused placeholder is removed on failure.
        let failed = root.appendingPathComponent("failed")
        PromisePlaceholder(destination: failed, isDirectory: true).discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }

    func testLocateMatchesPromisedNamesInExtractedDownload() throws {
        let root = temporaryTestRoot("PromiseLocate")
        let folder = root.appendingPathComponent("payload", isDirectory: true)
        let live = root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: folder.appendingPathComponent("ONE.JPG"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("nested/two.heic"))
        try Data("still".utf8).write(to: live.appendingPathComponent("IMG_3.HEIC"))
        try Data("motion".utf8).write(to: live.appendingPathComponent("IMG_3.MOV"))
        try Self.zip(live, to: folder.appendingPathComponent("IMG_3.zip"), keepParent: false)

        let located = try PhotoDownloadManager.locate([
            PromisedFile(itemID: 1, filename: "one.jpg"),
            PromisedFile(itemID: 2, filename: "two.heic"),
            PromisedFile(itemID: 3, filename: "IMG_3.HEIC"),
            PromisedFile(itemID: 4, filename: "missing.jpg"),
        ], in: folder)
        XCTAssertEqual(try located[1].map { try Data(contentsOf: $0) }, Data("one".utf8))
        XCTAssertEqual(try located[2].map { try Data(contentsOf: $0) }, Data("two".utf8))
        XCTAssertEqual(try located[3].map { try Data(contentsOf: $0) }, Data("still".utf8))
        XCTAssertNil(located[4])

        // A single promised file takes the only file of a single-file download, whatever its name.
        let single = root.appendingPathComponent("single", isDirectory: true)
        try FileManager.default.createDirectory(at: single, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: single.appendingPathComponent("server-name.jpg"))
        XCTAssertNotNil(try PhotoDownloadManager.locate([PromisedFile(itemID: 9, filename: "a.jpg")], in: single)[9])
    }

    @MainActor
    func testFilePromisesShareOneZIPDownload() async throws {
        let root = temporaryTestRoot("FilePromiseBatch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = EditingMockTransport()
        let repository = try CachedPhotosRepository(credentials: .init(username: "test", password: "test"),
                                                     budget: 100_000_000, cacheRoot: root.appendingPathComponent("cache"), transport: transport)
        let photos = try [1, 2].map { id in
            try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"filename\":\"photo-\(id).jpg\",\"time\":1,\"type\":\"photo\"}".utf8))
        }
        let files = try XCTUnwrap(PhotoDragPayload.files(for: photos))
        XCTAssertEqual(files.map(\.filename), ["photo-1.jpg", "photo-2.jpg"])
        XCTAssertNil(PhotoDragPayload.files(for: [photos[0], photos[0]]))
        let payload = PhotoDragPayload(repository: repository, source: .items(photos, collection: .library(.personal)),
                                       count: 2, delivery: .files(files))
        let batch = PhotoPromiseBatch(payload: payload)
        let activity = ActivityCenter()
        let manager = PhotoDownloadManager(activity: activity)
        var settled: [Error?] = []
        let finished = expectation(description: "both promises")
        for file in files {
            manager.fulfillPromise(batch, file: file, destination: root.appendingPathComponent(file.filename)) { error in
                settled.append(error)
                if settled.count == 2 { finished.fulfill() }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo-2.jpg").path),
                      "A placeholder appears before the download finishes")
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(settled.compactMap { $0 }.count, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo-1.jpg")), Data("image-1".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo-2.jpg")), Data("image-2".utf8))
        let ids = await transport.downloadedIDs
        XCTAssertEqual(ids, [1, 2])
        XCTAssertEqual(activity.entries.count, 1)
    }

    func testFolderPromiseUnzipsFilesAtomicallyAndDropsArchiveMetadata() throws {
        let root = temporaryTestRoot("FolderUnzip")
        let content = root.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: content.appendingPathComponent("one.jpg"))
        try Data("two".utf8).write(to: content.appendingPathComponent("two.heic"))
        let archive = root.appendingPathComponent("download.zip")
        try Self.zip(content, to: archive, keepParent: false)
        XCTAssertTrue(try PhotoDownloadManager.isZIPArchive(archive))
        XCTAssertFalse(try PhotoDownloadManager.isZIPArchive(content.appendingPathComponent("one.jpg")))

        let destination = root.appendingPathComponent("Photos")
        try Self.folderPromise(archive, filename: "download.zip", destination: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), ["one.jpg", "two.heic"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("two.heic")), Data("two".utf8))
        XCTAssertThrowsError(try Self.folderPromise(archive, filename: "download.zip", destination: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Photos") }, ["Photos"])

        // A lone wrapper directory is lifted so the promised folder is the container.
        let wrapped = root.appendingPathComponent("wrapped.zip")
        try Self.zip(content, to: wrapped, keepParent: true)
        let lifted = root.appendingPathComponent("Lifted")
        try Self.folderPromise(wrapped, filename: "wrapped.zip", destination: lifted)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lifted.path).sorted(), ["one.jpg", "two.heic"])
    }

    func testFolderPromiseRejectsSymbolicLinksAndEmptyArchives() throws {
        let root = temporaryTestRoot("FolderUnsafe")
        let content = root.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: content.appendingPathComponent("link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let archive = root.appendingPathComponent("link.zip")
        try Self.zip(content, to: archive, keepParent: false)
        let destination = root.appendingPathComponent("Photos")
        XCTAssertThrowsError(try Self.folderPromise(archive, filename: "link.zip", destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let emptyArchive = root.appendingPathComponent("empty.zip")
        try Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: emptyArchive)
        XCTAssertThrowsError(try Self.folderPromise(emptyArchive, filename: "empty.zip", destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadSavesZIPResponseAsUnzippedFolderWithoutOverwriting() throws {
        let root = temporaryTestRoot("DownloadUnzip")
        let content = root.appendingPathComponent("content", isDirectory: true)
        let directory = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: content.appendingPathComponent("one.jpg"))
        try Data("two".utf8).write(to: content.appendingPathComponent("two.jpg"))
        let archive = root.appendingPathComponent("download.zip")
        try Self.zip(content, to: archive, keepParent: false)
        let first = try PhotoDownloadManager.save(archive, filename: "download.zip", directory: directory)
        let second = try PhotoDownloadManager.save(archive, filename: "download.zip", directory: directory)
        XCTAssertEqual(first.lastPathComponent, "download")
        XCTAssertEqual(second.lastPathComponent, "download 1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path).sorted(), ["one.jpg", "two.jpg"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["download", "download 1"])
    }

    /// The folder delivery of a promise: a placeholder folder replaced by the extracted download.
    private static func folderPromise(_ source: URL, filename: String, destination: URL) throws {
        let placeholder = PromisePlaceholder(destination: destination, isDirectory: true)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try PhotoDownloadManager.populateFolder(staging, from: source, filename: filename)
            try placeholder.install(copyOf: staging)
        } catch {
            placeholder.discard()
            throw error
        }
    }

    private static func zip(_ directory: URL, to archive: URL, keepParent: Bool) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [directory.path, archive.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    @MainActor
    func testDragPreviewStaysBoundedForLargeSelection() {
        let preview = PhotoFileDragSource.dragPreview(images: Array(repeating: NSImage(size: NSSize(width: 1, height: 1)), count: 100), badge: 100_000, cropsToSquare: false)
        XCTAssertLessThanOrEqual(preview.size.width, 100)
        XCTAssertLessThanOrEqual(preview.size.height, 100)
    }

    @MainActor
    func testDragPreviewOmitsBadgeWhenSystemDrawsCount() {
        let images = [NSImage(size: NSSize(width: 60, height: 60))]
        let plain = PhotoFileDragSource.dragPreview(images: images, badge: 0, cropsToSquare: true)
        let badged = PhotoFileDragSource.dragPreview(images: images, badge: 5, cropsToSquare: true)
        XCTAssertLessThan(plain.size.height, badged.size.height)
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

private actor EditingMockTransport: TestPhotosTransport {
    private(set) var downloadedIDs: [Int64] = []
    private(set) var kind: PhotoDownloadKind?
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> MediaResponse {
        MediaResponse(data: Data("raw-image".utf8), etag: nil, lastModified: nil)
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        space: PhotoSpace, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        downloadedIDs = itemIDs
        self.kind = kind
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if itemIDs.count > 1 {
            // Several items arrive as one ZIP of `photo-<id>.jpg` files.
            let content = directory.appendingPathComponent("content", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            for id in itemIDs { try Data("image-\(id)".utf8).write(to: content.appendingPathComponent("photo-\(id).jpg")) }
            let archive = directory.appendingPathComponent("download.zip")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            task.arguments = ["-c", "-k", content.path, archive.path]
            try task.run()
            task.waitUntilExit()
            return PhotoDownloadResponse(temporaryURL: archive, filename: "download.zip")
        }
        let file = directory.appendingPathComponent("a.dng")
        try Data("raw-image".utf8).write(to: file)
        return PhotoDownloadResponse(temporaryURL: file, filename: "a.dng")
    }
}

private actor AlbumDownloadMockTransport: TestPhotosTransport {
    let origin: PhotoSpace
    var downloadedSpace: PhotoSpace?
    init(origin: PhotoSpace = .personal) { self.origin = origin }
    var downloadedIDs: [Int64] = []
    var kind: PhotoDownloadKind?
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        guard albumID == 54 else { return [] }
        return Array([DayTimelineEntry(id: 1, time: 1711929602), DayTimelineEntry(id: 2, time: 1711929601),
                      DayTimelineEntry(id: 3, time: 1711929600)].dropFirst(offset).prefix(limit))
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let json = """
        [{"id":1,"time":1711929602,"type":"photo","additional":{"thumbnail":{"unit_id":1,"cache_key":"revision"}}},
         {"id":2,"time":1711929601,"type":"photo","live_type":"live","additional":{"thumbnail":{"unit_id":2,"cache_key":"revision"}}},
         {"id":3,"time":1711929600,"type":"video"}]
        """
        let items = try JSONDecoder().decode([PhotoItem].self, from: Data(json.utf8))
        return CollectionBatchResult(items: Array(items.dropFirst(request.offset).prefix(request.limit)), profile: fields)
    }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] {
        let json = """
        [{"id":1,"time":1711929602,"type":"photo","additional":{"thumbnail":{"unit_id":1,"cache_key":"revision"}}},
         {"id":2,"time":1711929601,"type":"photo","live_type":"live","additional":{"thumbnail":{"unit_id":2,"cache_key":"revision"}}}]
        """
        return try JSONDecoder().decode([PhotoItem].self, from: Data(json.utf8)).filter { ids.contains($0.id) }
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        space == origin ? try await albumItems(ids: ids, albumID: 54) : []
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        space: PhotoSpace, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        downloadedSpace = space
        downloadedIDs = itemIDs; self.kind = kind
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("album.zip")
        try Data("download".utf8).write(to: file)
        return PhotoDownloadResponse(temporaryURL: file, filename: "album.zip")
    }
}
