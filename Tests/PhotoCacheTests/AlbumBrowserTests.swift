import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

private actor AlbumFakeTransport: TestPhotosTransport {
    var folderCatalogCalls: [Int64] = []
    var folderFailure = false
    func setFolderFailure() { folderFailure = true }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        if folderFailure { throw TestFailure("Offline") }
        return try JSONDecoder().decode(FolderSummary.self, from: Data(#"{"id":2,"name":"/","parent":2}"#.utf8))
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] {
        if folderFailure { throw TestFailure("Offline") }
        return [try JSONDecoder().decode(FolderSummary.self, from: Data(#"{"id":3,"name":"/Trip","parent":2,"additional":{"thumbnail":[]}}"#.utf8))]
    }
    func readFolderCatalogBatch(folderID: Int64, offset: Int, limit: Int, space: PhotoSpace) async throws -> [DayTimelineEntry] {
        if offset == 0 { folderCatalogCalls.append(folderID) }
        return Array((albumEntriesByID[folderID] ?? []).dropFirst(offset).prefix(limit))
    }
    var albumList: [AlbumSummary] = []
    var albumListFailure: String?
    var albumEntriesByID: [Int64: [DayTimelineEntry]] = [:]
    var timelineSnapshot = TimelineSnapshot(sections: [])
    var pageItems: [PhotoItem] = []
    var pageFailure: String?
    var catalogFailure = false
    var pausePage = false
    var pageStarted = false
    var pageContinuation: CheckedContinuation<Void, Never>?
    var pauseAlbumList = false
    var albumListStarted = false
    var albumListContinuation: CheckedContinuation<Void, Never>?
    func pauseNextAlbumList() { pauseAlbumList = true }
    func releaseAlbumList() { albumListContinuation?.resume(); albumListContinuation = nil }
    var albumListCalls = 0
    var albumTimelineCalls: [Int64] = []
    var collectionTimelineCalls: [(PhotoCollectionDescriptor, Bool)] = []
    var itemRequests: [(TimelineSection, PhotoCollectionDescriptor)] = []
    var favoriteWrites: [(Int64, Bool)] = []
    var favoriteFailure = false
    var mutationFails = false
    var mutationWrites = 0
    var writtenIDs: [Int64] = []
    var replacementEntries: [DayTimelineEntry] = []
    var replacementList: [AlbumSummary] = []
    var pauseMutation = false
    var mutationStarted = false
    var mutationContinuation: CheckedContinuation<Void, Never>?
    var pauseCatalog = false
    var catalogStarted = false
    var catalogContinuation: CheckedContinuation<Void, Never>?

    func configure(albumList: [AlbumSummary] = [],
                   albumEntriesByID: [Int64: [DayTimelineEntry]] = [:],
                   timelineSnapshot: TimelineSnapshot = TimelineSnapshot(sections: []),
                   pageItems: [PhotoItem] = [],
                   albumListFailure: String? = nil,
                   pageFailure: String? = nil) {
        self.albumList = albumList
        self.albumEntriesByID = albumEntriesByID.isEmpty && !pageItems.isEmpty ? [54: pageItems.map { DayTimelineEntry(id: $0.id, time: $0.time) }] : albumEntriesByID
        self.timelineSnapshot = timelineSnapshot
        self.pageItems = pageItems
        self.albumListFailure = albumListFailure
        self.pageFailure = pageFailure
    }

    var sharingUserID: Int64 = 11
    var sharingFailsUpdate = false
    var sharingWrites: [String] = []
    var sharingPause = false
    var sharingStarted = false
    var sharingContinuation: CheckedContinuation<Void, Never>?
    func configureSharingFailure(_ value: Bool) { sharingFailsUpdate = value }
    func pauseSharing() { sharingPause = true }
    func releaseSharing() { sharingContinuation?.resume(); sharingContinuation = nil }
    func currentPhotosUserID() async throws -> Int64 { sharingUserID }
    func sharingPrincipals() async throws -> [SharingPrincipal] { [.init(id: 1036, name: "Test", type: "user")] }
    func setAlbumShared(id: Int64, enabled: Bool) async throws -> AlbumSharingReference {
        sharingWrites.append(enabled ? "enable" : "disable")
        if sharingPause { sharingStarted = true; await withCheckedContinuation { sharingContinuation = $0 }; sharingPause = false }
        let old = albumList[0]
        albumList[0] = AlbumSummary(id: old.id, name: old.name, itemCount: old.itemCount, type: "normal", ownerUserID: 11, shared: enabled,
            sharingInfo: .init(privacyType: "private", expiration: 0, permission: [], reference: "fixture-reference", sharingLink: enabled ? "https://example.test/share" : ""))
        return try JSONDecoder().decode(AlbumSharingReference.self, from: Data(#"{"passphrase":"fixture-reference","sharing_link":"https://example.test/share"}"#.utf8))
    }
    func updateAlbumSharing(reference: String, changes: [SharingPermissionChange], password: SharingPasswordChange, expiration: Int64?) async throws {
        sharingWrites.append("update")
        if sharingFailsUpdate { throw TestFailure("fixture update failed") }
        let old = albumList[0]
        var permissions = old.sharingInfo?.permission ?? []
        var privacy = old.sharingInfo?.privacyType ?? "private"
        for change in changes {
            if change.member.type == "public" {
                privacy = change.action == "delete" ? "private" : (change.role == "download" ? "public-download" : "public-view")
                continue
            }
            permissions.removeAll { $0.principalID == change.member.id && $0.type == "user" }
            if let role = change.role { permissions.append(.init(photosUserID: 99, principalID: change.member.id, name: "Test", role: role, type: "user")) }
        }
        albumList[0] = AlbumSummary(id: old.id, name: old.name, itemCount: old.itemCount, type: "normal", ownerUserID: 11, shared: true,
            sharingInfo: .init(privacyType: privacy, expiration: expiration ?? old.sharingInfo?.expiration, enablePassword: password == .unchanged ? old.sharingInfo?.enablePassword : password != .clear, permission: permissions, reference: "fixture-reference", sharingLink: "https://example.test/share"))
    }

    func login(credentials: SynologyCredentials) async throws {}
    func personalItems(ids: [Int64]) async throws -> [PhotoItem] { ids.compactMap { id in pageItems.first { $0.id == id } } }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] { space == .personal ? try await personalItems(ids: ids) : [] }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] { try await personalItems(ids: ids) }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        collectionTimelineCalls.append((collection, initial))
        return try fixtureDayCatalog(timelineSnapshot, initial: initial)
    }

    func albums() async throws -> [AlbumSummary] {
        albumListCalls += 1
        if let albumListFailure { throw TestFailure(albumListFailure) }
        let result = albumList
        if pauseAlbumList {
            pauseAlbumList = false; albumListStarted = true
            await withCheckedContinuation { albumListContinuation = $0 }
        }
        return result
    }

    func configureMutation(entries: [DayTimelineEntry], list: [AlbumSummary], fails: Bool = false) {
        replacementEntries = entries; replacementList = list; mutationFails = fails
    }

    func pauseNextPage() { pausePage = true }
    func releasePage() { pageContinuation?.resume(); pageContinuation = nil }

    func failCatalog() { catalogFailure = true }

    func pauseNextCatalog() { pauseCatalog = true }
    func releaseCatalog() { catalogContinuation?.resume(); catalogContinuation = nil }
    func pauseNextMutation() { pauseMutation = true }
    func releaseMutation() { mutationContinuation?.resume(); mutationContinuation = nil }

    func album(id: Int64) async throws -> AlbumSummary {
        guard let album = albumList.first(where: { $0.id == id }) else { throw TestFailure("Missing album") }
        return album
    }

    func deleteAlbum(id: Int64) async throws {
        mutationWrites += 1
        if mutationFails { throw TestFailure("Album delete failed") }
        albumList.removeAll { $0.id == id }
        albumEntriesByID[id] = nil
    }

    func renameAlbum(id: Int64, name: String) async throws {
        mutationWrites += 1
        if mutationFails { throw TestFailure("Album rename failed") }
        guard let index = albumList.firstIndex(where: { $0.id == id }) else { throw TestFailure("Missing album") }
        let old = albumList[index]
        albumList[index] = AlbumSummary(id: old.id, name: name, itemCount: old.itemCount, type: old.type,
                                         ownerUserID: old.ownerUserID, shared: old.shared, sharingInfo: old.sharingInfo)
    }

    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws {
        mutationWrites += 1
        writtenIDs = itemIDs
        albumEntriesByID[id] = replacementEntries
        albumList = replacementList
        if pauseMutation {
            mutationStarted = true
            await withCheckedContinuation { mutationContinuation = $0 }
            pauseMutation = false
        }
        if mutationFails { throw TestFailure("Incomplete album change") }
    }

    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws {
        try await addItems(itemIDs, toAlbum: id)
    }

    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        if catalogFailure { throw TestFailure("Offline") }
        if offset == 0 { albumTimelineCalls.append(albumID) }
        let result = Array((albumEntriesByID[albumID] ?? []).dropFirst(offset).prefix(limit))
        if pauseCatalog {
            pauseCatalog = false; catalogStarted = true
            await withCheckedContinuation { catalogContinuation = $0 }
        }
        return result
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        itemRequests.append((section, collection))
        if pausePage {
            pausePage = false; pageStarted = true
            await withCheckedContinuation { pageContinuation = $0 }
        }
        if let pageFailure { throw TestFailure(pageFailure) }
        let available: [PhotoItem]
        if let albumID = collection.albumID, let entries = albumEntriesByID[albumID] {
            let ids = Set(entries.map(\.id))
            available = pageItems.filter { ids.contains($0.id) }
        } else { available = pageItems }
        let items = available.count > 250 ? Array(available.dropFirst(request.offset).prefix(request.limit)) : available
        return try fixtureBatch(items, request: request, fields: fields)
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {
        if favoriteFailure { throw TestFailure("Favorite write failed") }
        favoriteWrites.append(contentsOf: itemIDs.map { ($0, favorite) })
    }

    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   space: PhotoSpace, etag: String?, lastModified: String?) async throws -> MediaResponse {
        throw TestFailure("Unexpected thumbnail request")
    }

    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> MediaResponse {
        throw TestFailure("Unexpected original-image request")
    }
}

final class AlbumBrowserTests: XCTestCase {
    private let server = URL(string: "https://example.invalid")!
    private let credentials = SynologyCredentials(username: "test", password: "unused", otpSecret: "unused")

    private func root() -> URL { temporaryTestRoot("SynoAlbumTest") }

    private func makeRepository(root: URL, transport: AlbumFakeTransport) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, baseURL: server, cacheRoot: root, transport: transport)
    }

    private func section(_ day: Int, offset: Int = 0, limit: Int = 1, count: Int = 1) -> TimelineSection {
        TimelineSection(offset: offset, limit: limit,
                        list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: count)])
    }

    private func item(_ id: Int, favorite: Bool = false) throws -> PhotoItem {
        let favoriteJSON = favorite ? ",\"favorite\":true" : ""
        return try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":\(id),\"time\":1711929600,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":\(id),\"cache_key\":\"\(id)_rev\"}\(favoriteJSON)}}".utf8))
    }

    private func thumbnail(_ unit: Int64) -> ThumbnailInfo {
        ThumbnailInfo(unitID: unit, cacheKey: "\(unit)_rev", sm: "ready", m: "ready", xl: "ready")
    }

    func testSharingPartialSuccessAndStaleSnapshot() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, sharingInfo: .init(privacyType: "private", expiration: 0, permission: []))])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        await transport.configureSharingFailure(true)
        let change = SharingPermissionChange(action: "update", role: "download", member: .init(type: "user", id: 1036))
        do { _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [change], disable: false); XCTFail("Expected update failure") } catch {}
        let after = try await repository.albumSharing(id: 54)
        XCTAssertTrue(after.album.shared)
        XCTAssertEqual(after.album.sharingInfo?.permission, [])
        do { _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [change], disable: false); XCTFail("Stale snapshot was accepted") } catch {}
        let writes = await transport.sharingWrites
        XCTAssertEqual(writes, ["enable", "update"])
    }

    func testEnablingSharingWithoutOtherChangesDoesNotSendEmptyUpdate() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11,
                                                    sharingInfo: .init(privacyType: "private", expiration: 0, permission: []))])
        await transport.configureSharingFailure(true)
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        let result = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false)
        XCTAssertTrue(result.shared)
        let writes = await transport.sharingWrites
        XCTAssertEqual(writes, ["enable"])
    }

    func testPublicDownloadUpdatesAccessAndPreservesNamedGrants() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let member = AlbumSharingPermission(photosUserID: 12, principalID: 1035, name: "Other", role: "view", type: "user")
        let info = AlbumSharingInfo(privacyType: "public-view", expiration: 0, permission: [member], reference: "fixture-reference")
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, shared: true, sharingInfo: info)])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        let result = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false, access: .publicDownload)
        XCTAssertEqual(result.sharingInfo?.privacyType, "public-download")
        XCTAssertEqual(result.sharingInfo?.permission, [member])
    }

    func testProviderGrantCanBeSetAndChanged() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let info = AlbumSharingInfo(privacyType: "private", expiration: 0, permission: [], reference: "fixture-reference")
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, shared: true, sharingInfo: info)])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        let member = SharingPermissionChange.Member(type: "user", id: 1036)
        let added = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [.init(action: "update", role: "upload", member: member)], disable: false)
        XCTAssertEqual(added.sharingInfo?.permission?.first?.role, "upload")
        let next = try await repository.albumSharing(id: 54)
        let updated = try await repository.saveAlbumSharing(snapshot: next, changes: [.init(action: "update", role: "view", member: member)], disable: false)
        XCTAssertEqual(updated.sharingInfo?.permission?.first?.role, "view")
    }

    func testAlbumDeletionRefreshesListAndRequiresOwnership() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [.init(id: 54, name: "Owned", itemCount: 0, type: "normal", ownerUserID: 11),
                                              .init(id: 55, name: "Other", itemCount: 0, type: "normal", ownerUserID: 12)])
        let repository = try makeRepository(root: root, transport: transport)
        do { try await repository.deleteAlbum(id: 55); XCTFail("Non-owner deletion accepted") } catch {}
        try await repository.deleteAlbum(id: 54)
        var verified: [AlbumSummary]?
        for await event in await repository.albums() { if case .value(let albums, true) = event { verified = albums } }
        XCTAssertEqual(verified?.map(\.id), [55])
        let writes = await transport.mutationWrites
        XCTAssertEqual(writes, 1)
    }

    func testAlbumRenameRefreshesAndRequiresOwnership() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let info = AlbumSharingInfo(privacyType: "private", expiration: 0, permission: [], reference: "fixture-reference")
        await transport.configure(albumList: [.init(id: 54, name: "Owned", itemCount: 0, type: "normal", ownerUserID: 11, shared: true, sharingInfo: info),
                                              .init(id: 55, name: "Other", itemCount: 0, type: "normal", ownerUserID: 12)])
        let repository = try makeRepository(root: root, transport: transport)
        do { try await repository.renameAlbum(id: 55, name: "Denied"); XCTFail("Non-owner rename accepted") } catch {}
        try await repository.renameAlbum(id: 54, name: " Updated ")
        var verified: [AlbumSummary]?
        for await event in await repository.albums() { if case .value(let albums, true) = event { verified = albums } }
        let renamed = verified?.first { $0.id == 54 }
        XCTAssertEqual(renamed?.name, "Updated")
        XCTAssertEqual(renamed?.shared, true)
        XCTAssertEqual(renamed?.sharingInfo?.privacyType, "private")
        let writes = await transport.mutationWrites
        XCTAssertEqual(writes, 1)
    }

    func testFailedAlbumDeletionRetainsVerifiedAlbumAndLibraryItems() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let photo = try item(1)
        let album = AlbumSummary(id: 54, name: "Owned", itemCount: 1, type: "normal", ownerUserID: 11)
        await transport.configure(albumList: [album], pageItems: [photo])
        await transport.configureMutation(entries: [], list: [album], fails: true)
        let repository = try makeRepository(root: root, transport: transport)
        do { try await repository.deleteAlbum(id: 54); XCTFail("Expected deletion failure") } catch {}
        var verified: [AlbumSummary]?
        for await event in await repository.albums() { if case .value(let albums, true) = event { verified = albums } }
        XCTAssertEqual(verified?.map(\.id), [54])
        let items = try await transport.items(ids: [photo.id], space: .personal)
        XCTAssertEqual(items.map(\.id), [photo.id])
    }

    func testSharingCancellationStillReconcilesDispatchedWrite() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, sharingInfo: .init(privacyType: "private", expiration: 0, permission: []))])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        await transport.pauseSharing()
        let task = Task { try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false) }
        while !(await transport.sharingStarted) { await Task.yield() }
        task.cancel()
        await transport.releaseSharing()
        _ = try? await task.value
        let after = try await repository.albumSharing(id: 54)
        XCTAssertTrue(after.album.shared)
    }

    func testSharingPreservesOtherMembersAndSettingsAndDisableClearsGrants() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let other = AlbumSharingPermission(photosUserID: 12, principalID: 1035, name: "Other", role: "view", type: "user")
        let info = AlbumSharingInfo(privacyType: "private", expiration: 12345, enablePassword: true, permission: [other], reference: "fixture-reference", sharingLink: "https://example.test/share")
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 3, type: "normal", ownerUserID: 11, shared: true, sharingInfo: info)])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        let change = SharingPermissionChange(action: "update", role: "download", member: .init(type: "user", id: 1036))
        let saved = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [change], disable: false)
        XCTAssertEqual(saved.sharingInfo?.expiration, 12345)
        XCTAssertEqual(saved.sharingInfo?.enablePassword, true)
        XCTAssertTrue(saved.sharingInfo?.permission?.contains(other) == true)
        let next = try await repository.albumSharing(id: 54)
        let disabled = try await repository.saveAlbumSharing(snapshot: next, changes: [], disable: true)
        XCTAssertFalse(disabled.shared)
        XCTAssertEqual(disabled.sharingInfo?.permission, [])
        XCTAssertNotNil(disabled.sharingInfo?.reference)
        let disabledSnapshot = try await repository.albumSharing(id: 54)
        let enabled = try await repository.saveAlbumSharing(snapshot: disabledSnapshot, changes: [], disable: false)
        XCTAssertTrue(enabled.shared)
        XCTAssertEqual(enabled.sharingInfo?.permission, [])
        XCTAssertEqual(enabled.itemCount, 3)
    }

    func testFailedPublicUpdateRefreshesRepresentation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let info = AlbumSharingInfo(privacyType: "private", expiration: 0, enablePassword: false, permission: [], reference: "fixture-reference")
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, shared: true, sharingInfo: info)])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        let events = await repository.albumSharingChanges()
        let notification = Task { for await _ in events { return true }; return false }
        await transport.configureSharingFailure(true)
        do {
            _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false, access: .publicView, password: .set("fixture-password"))
            XCTFail("Expected failure")
        } catch {}
        let notified = await notification.value
        XCTAssertTrue(notified)
        var listed: [AlbumSummary]?
        for await event in await repository.albums() { if case .value(let albums, true) = event { listed = albums } }
        XCTAssertEqual(listed?.first?.sharingInfo?.privacyType, "private")
    }

    func testPublicSettingsPreserveAndDeleteNamedGrantsAndRefreshList() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let member = AlbumSharingPermission(photosUserID: 12, principalID: 1035, name: "Other", role: "view", type: "user")
        let info = AlbumSharingInfo(privacyType: "private", expiration: 0, enablePassword: false, permission: [member], reference: "fixture-reference", sharingLink: "https://example.test/share")
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, shared: true, sharingInfo: info)])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        let publicAlbum = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false, access: .publicView, password: .set("fixture-password"), expiration: 1794956399)
        XCTAssertEqual(publicAlbum.sharingInfo?.privacyType, "public-view")
        XCTAssertEqual(publicAlbum.sharingInfo?.permission, [member])
        XCTAssertEqual(publicAlbum.sharingInfo?.enablePassword, true)
        XCTAssertEqual(publicAlbum.sharingInfo?.expiration, 1794956399)
        var listed: [AlbumSummary]?
        for await event in await repository.albums() { if case .value(let albums, true) = event { listed = albums } }
        XCTAssertEqual(listed?.first?.sharingInfo?.privacyType, "public-view")
        let next = try await repository.albumSharing(id: 54)
        let remove = SharingPermissionChange(action: "delete", member: .init(type: "user", id: 1035))
        let privateAlbum = try await repository.saveAlbumSharing(snapshot: next, changes: [remove], disable: false, access: .private, password: .clear, expiration: 0)
        XCTAssertEqual(privateAlbum.sharingInfo?.privacyType, "private")
        XCTAssertEqual(privateAlbum.sharingInfo?.permission, [])
        XCTAssertEqual(privateAlbum.sharingInfo?.enablePassword, false)
        XCTAssertEqual(privateAlbum.sharingInfo?.expiration, 0)
    }

    func testSharingRejectsAlbumListReadAdmittedBeforeWrite() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11, sharingInfo: .init(privacyType: "private", expiration: 0, permission: []))])
        let repository = try makeRepository(root: root, transport: transport)
        let snapshot = try await repository.albumSharing(id: 54)
        await transport.pauseNextAlbumList()
        let read = Task { () -> [ResourceEvent<[AlbumSummary]>] in
            var events: [ResourceEvent<[AlbumSummary]>] = []
            for await event in await repository.albums() { events.append(event) }
            return events
        }
        while !(await transport.albumListStarted) { await Task.yield() }
        _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false)
        await transport.releaseAlbumList()
        let events = await read.value
        XCTAssertFalse(events.contains { if case .value(let list, true) = $0 { return list.contains { !$0.shared } }; return false })
        var verified: [AlbumSummary]?
        for await event in await repository.albums() { if case .value(let list, true) = event { verified = list } }
        XCTAssertEqual(verified?.first?.shared, true)
    }

    func testSharingRejectsNonOwnerAndUnknownPrivacy() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 12, sharingInfo: .init(privacyType: "private"))])
        let repository = try makeRepository(root: root, transport: transport)
        do { _ = try await repository.albumSharing(id: 54); XCTFail("Non-owner was accepted") } catch {}
        await transport.configure(albumList: [.init(id: 54, name: "Album", itemCount: 0, type: "normal", ownerUserID: 11)])
        let snapshot = try await repository.albumSharing(id: 54)
        do { _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: [], disable: false); XCTFail("Unknown privacy was accepted") } catch {}
        let writes = await transport.sharingWrites
        XCTAssertTrue(writes.isEmpty)
    }

    func testWholeAlbumResolverReadsEveryPageAndSkipsVideos() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        var items = try (1...251).map { try item($0) }
        items.append(try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":252,\"time\":1711929600,\"type\":\"video\"}".utf8)))
        await transport.configure(pageItems: items)
        let repository = try makeRepository(root: root, transport: transport)
        let result = await AlbumSelectionResolver(repository: repository).resolve(albumID: 54)
        XCTAssertEqual(result?.count, 251)
        XCTAssertEqual(Set(result?.map(\.id) ?? []), Set((1...251).map(Int64.init)))
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .album(54))
        XCTAssertEqual(timeline.sections.count, 2)
    }

    func testWholeAlbumResolverHandlesEmptyAndVideoOnlyAlbums() async throws {
        for video in [false, true] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = AlbumFakeTransport()
            let items = video ? [try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":1711929600,\"type\":\"video\"}".utf8))] : []
            await transport.configure(pageItems: items)
            let repository = try makeRepository(root: root, transport: transport)
            let result = await AlbumSelectionResolver(repository: repository).resolve(albumID: 54)
            XCTAssertEqual(result?.count, 0)
        }
    }

    func testWholeAlbumResolverIncludesSingletonLivePhoto() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let live = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":1711929600,\"type\":\"photo\",\"live_type\":\"live\"}".utf8))
        await transport.configure(pageItems: [live])
        let repository = try makeRepository(root: root, transport: transport)
        let result = await AlbumSelectionResolver(repository: repository).resolve(albumID: 54)
        XCTAssertEqual(result?.map(\.id), [1])
        XCTAssertEqual(result?.first?.mediaKind, .livePhoto)
    }

    func testWholeAlbumResolverCancellation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(pageItems: [try item(1)])
        await transport.pauseNextCatalog()
        let repository = try makeRepository(root: root, transport: transport)
        let task = Task { await AlbumSelectionResolver(repository: repository).resolve(albumID: 54) }
        while !(await transport.catalogStarted) { await Task.yield() }
        task.cancel()
        await transport.releaseCatalog()
        let result = await task.value
        XCTAssertNil(result)
    }

    func testWholeAlbumResolverRejectsMembershipMutationDuringResolution() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [AlbumSummary(id: 54, name: "Album", itemCount: 1)], pageItems: [try item(1)])
        await transport.configureMutation(entries: [DayTimelineEntry(id: 2, time: 1711929600)],
                                          list: [AlbumSummary(id: 54, name: "Album", itemCount: 1)])
        await transport.pauseNextPage()
        await transport.pauseNextMutation()
        let repository = try makeRepository(root: root, transport: transport)
        let task = Task { await AlbumSelectionResolver(repository: repository).resolve(albumID: 54) }
        while !(await transport.pageStarted) { await Task.yield() }
        let mutation = Task { try await repository.addItems([2], toAlbum: 54) }
        while !(await transport.mutationStarted) { await Task.yield() }
        await transport.releasePage()
        await transport.releaseMutation()
        _ = try await mutation.value
        let result = await task.value
        XCTAssertNil(result)
    }

    func testDisplayedSelectionSourcesWriteOnlyDisplayedIDs() async throws {
        for kind in 0..<8 {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = AlbumFakeTransport()
            let day = Int64(1711929600)
            let photos = try (1...2).map { id in
                try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":1711929600,\"type\":\"photo\",\"additional\":{\"thumbnail\":{\"unit_id\":\(id),\"cache_key\":\"\(id)_rev\"},\"gps\":{\"latitude\":10,\"longitude\":20}}}".utf8))
            }
            let sourceAlbum = AlbumSummary(id: 54, name: "Source", itemCount: 2)
            let target = AlbumSummary(id: 55, name: "Target", itemCount: 0)
            let original = TimelineSnapshot(sections: [section(1, limit: 2, count: 2)])
            await transport.configure(albumList: [sourceAlbum, target],
                albumEntriesByID: [54: [.init(id: 1, time: day), .init(id: 2, time: day)], 55: []],
                timelineSnapshot: original, pageItems: photos)
            await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [sourceAlbum, target])
            let repository = try makeRepository(root: root, transport: transport)
            let underlying: PhotoCollectionDescriptor
            let timeline: TimelineSnapshot
            if kind == 3 || kind == 7 {
                try await repository.initializeMetadataEngine()
                let namespace = await repository.personalMetadataNamespace
                _ = try await repository.store.storeMetadataDetails(photos, namespace: namespace, currentRun: repository.runID,
                    admission: repository.store.metadataAdmission(namespace))
                let records = try await repository.store.metadataCachedLocations(namespace)
                let locations = await repository.acceptLocationRecords(records, space: .personal)
                let map = try await repository.registerMapFilter(itemIDs: [1, 2], locationRevision: locations.revision)
                underlying = map.descriptor; timeline = map.snapshot
            } else {
                underlying = [PhotoCollectionDescriptor.library(.personal), .favorites(.personal), .album(54)][kind % 4]
                timeline = try await repository.verifiedTimelineSnapshot(collection: underlying)
            }
            // Materialize the source page so filter references have authoritative slots.
            for await _ in await repository.page(timeline.sections[0], collection: underlying) { }
            let collection: PhotoCollectionDescriptor
            let displayed: TimelineSnapshot
            let authority: PhotoSelectionAuthority?
            if kind >= 4 {
                collection = .libraryFilter(UUID(), scope: underlying.contentScope)
                displayed = TimelineSnapshot(sections: [section(1)])
                let registration = LibraryFilterRegistration(descriptor: collection, snapshot: displayed,
                    referencesBySection: [[.init(sourceSectionIndex: 0, sourcePageOffset: 1, itemID: 2)]],
                    filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
                    sourceCollection: underlying)
                authority = try await repository.registerLibraryFilter(registration)
            } else {
                collection = underlying; displayed = timeline
                authority = await repository.selectionAuthority(collection: collection, snapshot: displayed)
            }
            let ordinal = kind >= 4 ? 0 : 1
            let captured = PhotoSelectionSnapshot(collection: collection, timeline: displayed,
                timelineFingerprint: LibraryIndex(snapshot: displayed).fingerprint,
                selectedOrdinals: IndexSet(integer: ordinal), knownItemIDsByOrdinal: [ordinal: 2], authority: authority)
            let receipt = await SelectionItemResolver(repository: repository).resolveWithReceipt(captured)
            try await repository.addMissingItems(try XCTUnwrap(receipt, "source \(kind)"), toAlbum: 55)
            let written = await transport.writtenIDs
            XCTAssertEqual(written, [2], "source \(kind)")
        }
    }

    func testUnloadedSelectedAlbumPageReachesMutation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1711929600)
        let photos = try (1...251).map { try item($0) }
        let source = AlbumSummary(id: 54, name: "Source", itemCount: 251)
        let target = AlbumSummary(id: 55, name: "Target", itemCount: 0)
        await transport.configure(albumList: [source, target],
            albumEntriesByID: [54: photos.map { .init(id: $0.id, time: day) }, 55: []], pageItems: photos)
        await transport.configureMutation(entries: [.init(id: 251, time: day)], list: [source, target])
        let repository = try makeRepository(root: root, transport: transport)
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .album(54))
        let authority = await repository.selectionAuthority(collection: .album(54), snapshot: timeline)
        let snapshot = PhotoSelectionSnapshot(collection: .album(54), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 250), knownItemIDsByOrdinal: [:], authority: authority)
        let receipt = await SelectionItemResolver(repository: repository).resolveWithReceipt(snapshot)
        try await repository.addMissingItems(try XCTUnwrap(receipt), toAlbum: 55)
        let written = await transport.writtenIDs
        XCTAssertEqual(written, [251])
    }

    func testAddingMissingItemsSkipsExistingDestinationMembers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1711929600)
        let source = AlbumSummary(id: 54, name: "Source", itemCount: 2)
        let target = AlbumSummary(id: 55, name: "Target", itemCount: 1)
        await transport.configure(albumList: [source, target],
            albumEntriesByID: [54: [.init(id: 1, time: day), .init(id: 2, time: day)],
                               55: [.init(id: 1, time: day)]], pageItems: [try item(1), try item(2)])
        await transport.configureMutation(entries: [.init(id: 1, time: day), .init(id: 2, time: day)], list: [source, target])
        let repository = try makeRepository(root: root, transport: transport)
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .album(54))
        let authority = await repository.selectionAuthority(collection: .album(54), snapshot: timeline)
        let snapshot = PhotoSelectionSnapshot(collection: .album(54), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integersIn: 0..<2), knownItemIDsByOrdinal: [:], authority: authority)
        let receipt = await SelectionItemResolver(repository: repository).resolveWithReceipt(snapshot)
        try await repository.addMissingItems(try XCTUnwrap(receipt), toAlbum: 55)
        let written = await transport.writtenIDs
        XCTAssertEqual(written, [2])
    }

    func testAlbumWriteAcceptsUnchangedResolvedSelection() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1711929600)
        let source = AlbumSummary(id: 54, name: "Source", itemCount: 1)
        let target = AlbumSummary(id: 55, name: "Target", itemCount: 1)
        await transport.configure(albumList: [source, target],
            albumEntriesByID: [54: [.init(id: 1, time: day)]], pageItems: [try item(1)])
        await transport.configureMutation(entries: [.init(id: 1, time: day)], list: [source, target])
        let repository = try makeRepository(root: root, transport: transport)
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .album(54))
        let captured = await repository.selectionAuthority(collection: .album(54), snapshot: timeline)
        let authority = try XCTUnwrap(captured)
        let snapshot = PhotoSelectionSnapshot(collection: .album(54), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [0: 1], authority: authority)
        let result = await SelectionItemResolver(repository: repository).resolveWithReceipt(snapshot)
        let resolved = try XCTUnwrap(result)
        try await repository.addItems(resolved, toAlbum: 55)
        let writes = await transport.mutationWrites
        XCTAssertEqual(writes, 1)
    }

    func testAlbumWriteAcceptsSelectionFromDestinationAlbum() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1711929600)
        let source = AlbumSummary(id: 54, name: "Source", itemCount: 1)
        let target = AlbumSummary(id: 55, name: "Target", itemCount: 1)
        await transport.configure(albumList: [source, target],
            albumEntriesByID: [54: [.init(id: 1, time: day)]], pageItems: [try item(1)])
        await transport.configureMutation(entries: [.init(id: 1, time: day)], list: [source, target])
        let repository = try makeRepository(root: root, transport: transport)
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .album(54))
        let captured = await repository.selectionAuthority(collection: .album(54), snapshot: timeline)
        let authority = try XCTUnwrap(captured)
        let snapshot = PhotoSelectionSnapshot(collection: .album(54), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [0: 1], authority: authority)
        let result = await SelectionItemResolver(repository: repository).resolveWithReceipt(snapshot)
        let resolved = try XCTUnwrap(result)
        try await repository.removeItems(resolved, fromAlbum: 54)
        let writes = await transport.mutationWrites
        XCTAssertEqual(writes, 1)
    }

    func testAlbumWriteRejectsSelectionChangedWhileChooserIsOpen() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1711929600)
        let source = AlbumSummary(id: 54, name: "Source", itemCount: 1)
        let target = AlbumSummary(id: 55, name: "Target", itemCount: 0)
        await transport.configure(albumList: [source, target],
            albumEntriesByID: [54: [.init(id: 1, time: day)]], pageItems: [try item(1)])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [source, target])
        let repository = try makeRepository(root: root, transport: transport)
        let timeline = try await repository.verifiedTimelineSnapshot(collection: .album(54))
        let captured = await repository.selectionAuthority(collection: .album(54), snapshot: timeline)
        let authority = try XCTUnwrap(captured)
        let snapshot = PhotoSelectionSnapshot(collection: .album(54), timeline: timeline,
            timelineFingerprint: LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: IndexSet(integer: 0), knownItemIDsByOrdinal: [0: 1], authority: authority)
        let result = await SelectionItemResolver(repository: repository).resolveWithReceipt(snapshot)
        let resolved = try XCTUnwrap(result)
        try await repository.addItems([2], toAlbum: 54)
        do {
            try await repository.addItems(resolved, toAlbum: 55)
            XCTFail("Stale selection must not be written")
        } catch { }
        let writes = await transport.mutationWrites
        XCTAssertEqual(writes, 1)
    }

    func testWholeAlbumResolverRequiresOnlineVerification() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(pageItems: [try item(1)])
        let first = try makeRepository(root: root, transport: transport)
        let firstResult = await AlbumSelectionResolver(repository: first).resolve(albumID: 54)
        XCTAssertEqual(firstResult?.count, 1)
        let offline = AlbumFakeTransport()
        await offline.failCatalog()
        let second = try makeRepository(root: root, transport: offline)
        let result = await AlbumSelectionResolver(repository: second).resolve(albumID: 54)
        XCTAssertNil(result)
    }

    func testAlbumListIsPersistedAndRevalidatedOnce() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumList: [
            AlbumSummary(id: 54, name: "Trip", itemCount: 12, thumbnail: thumbnail(77607)),
            AlbumSummary(id: 55, name: "Family", itemCount: 3),
        ])
        let repository = try makeRepository(root: root, transport: transport)
        var values: [[AlbumSummary]] = []
        for await event in await repository.albums() {
            if case .value(let list, _) = event { values.append(list) }
        }
        XCTAssertEqual(values.last?.map(\.id), [54, 55])
        let firstCalls = await transport.albumListCalls
        XCTAssertEqual(firstCalls, 1)

        let secondTransport = AlbumFakeTransport()
        await secondTransport.configure(albumList: [
            AlbumSummary(id: 54, name: "Trip", itemCount: 12, thumbnail: thumbnail(77607)),
            AlbumSummary(id: 55, name: "Family", itemCount: 3),
        ])
        let secondRepository = try makeRepository(root: root, transport: secondTransport)
        var cachedFirst = false
        var verifiedFinal = false
        for await event in await secondRepository.albums() {
            if case .value(let list, let verified) = event {
                XCTAssertEqual(list.map(\.id), [54, 55])
                if !verified { cachedFirst = true }
                if verified { verifiedFinal = true }
            }
        }
        XCTAssertTrue(cachedFirst, "The cached album list must arrive before validation")
        XCTAssertTrue(verifiedFinal)
        let secondCalls = await secondTransport.albumListCalls
        XCTAssertEqual(secondCalls, 1, "The list validates once per run")
    }

    func testAlbumTimelineScansAndCachesWithoutBrowseTimeline() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        await transport.configure(albumEntriesByID: [54: [
            DayTimelineEntry(id: 1, time: day + 10),
            DayTimelineEntry(id: 2, time: day + 20),
            DayTimelineEntry(id: 3, time: day - 86_400),
        ]])
        let repository = try makeRepository(root: root, transport: transport)
        var finalSnapshot: TimelineSnapshot?
        for await event in await repository.timeline(collection: .album(54)) {
            if case .value(let snapshot, true) = event { finalSnapshot = snapshot }
        }
        let snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.timeline.days.map(\.id), ["2024-01-01", "2023-12-31"])
        XCTAssertEqual(snapshot.sections.count, 2)
        let albumCalls = await transport.albumTimelineCalls
        XCTAssertEqual(albumCalls, [54])
        let timelineCalls = await transport.collectionTimelineCalls
        XCTAssertTrue(timelineCalls.isEmpty, "Albums must never call Browse.Timeline")

        let namespace = await repository.metadataNamespace(for: .album(54))
        let cached = try await repository.store.metadataCatalog(.init(namespace: namespace, collection: .album(54)))
        XCTAssertEqual(cached?.catalog.days.map(\.day.id), ["2024-01-01", "2023-12-31"])

    }

    func testFolderDirectoryIsCachedAndSurvivesFailedRefresh() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let firstTransport = AlbumFakeTransport()
        let first = try makeRepository(root: root, transport: firstTransport)
        var verified = false
        for await event in await first.folderDirectory(id: 0, space: .personal) {
            if case .value(let directory, true) = event { verified = directory.children.map(\.id) == [3] }
        }
        XCTAssertTrue(verified)
        let offline = AlbumFakeTransport()
        await offline.setFolderFailure()
        let second = try makeRepository(root: root, transport: offline)
        var cached = false; var failed = false
        for await event in await second.folderDirectory(id: 0, space: .personal) {
            switch event {
            case .value(let directory, false): cached = directory.children.map(\.id) == [3]
            case .failure: failed = true
            default: break
            }
        }
        XCTAssertTrue(cached)
        XCTAssertTrue(failed)
    }

    func testFolderTimelineUsesScopedCatalog() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        await transport.configure(albumEntriesByID: [8: [DayTimelineEntry(id: 11, time: 1_704_067_200)]])
        let repository = try makeRepository(root: root, transport: transport)
        var result: TimelineSnapshot?
        for await event in await repository.timeline(collection: .folder(8, space: .personal)) {
            if case .value(let snapshot, true) = event { result = snapshot }
        }
        XCTAssertEqual(result?.sections.first?.limit, 1)
        let folderCalls = await transport.folderCatalogCalls
        let albumCalls = await transport.albumTimelineCalls
        let timelineCalls = await transport.collectionTimelineCalls
        XCTAssertEqual(folderCalls, [8])
        XCTAssertTrue(albumCalls.isEmpty)
        XCTAssertTrue(timelineCalls.isEmpty)
    }

    func testEmptyAlbumScanProducesNoSections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let repository = try makeRepository(root: root, transport: transport)
        for await event in await repository.timeline(collection: .album(9)) {
            if case .value(let snapshot, true) = event {
                XCTAssertTrue(snapshot.sections.isEmpty)
            }
        }
    }

    func testAlbumPageUsesAlbumCollectionAndCachesUnderAlbumKey() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let descriptor = section(1)
        await transport.configure(pageItems: [try item(7)])
        let repository = try makeRepository(root: root, transport: transport)
        var verifiedItems: [PhotoItem] = []
        for await event in await repository.page(descriptor, collection: .album(54)) {
            if case .value(let items, true) = event { let items = items.completeItems ?? []; verifiedItems = items }
        }
        XCTAssertEqual(verifiedItems.map(\.id), [7])
        let requests = await transport.itemRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.1, .album(54))
        XCTAssertEqual(requests.first?.0, descriptor)

        let cached = try await repository.store.metadataPage(try XCTUnwrap(DayPageAddress(section: descriptor, collection: .album(54))), namespace: await repository.metadataNamespace(for: .album(54)), currentRun: repository.runID)
        XCTAssertEqual(cached?.slots.map(\.itemID), [7])

    }

    func testAlbumAndPersonalPageKeysAreIsolated() {
        let namespace = CacheKey.namespace(server: server, account: credentials.username)
        let descriptor = section(1)
        XCTAssertNotEqual(CacheKey.page(scope: .space(.personal), namespace: namespace, section: descriptor, collection: .library(.personal)),
                          CacheKey.page(scope: .space(.personal), namespace: namespace, section: descriptor, collection: .album(54)))
        XCTAssertNotEqual(CacheKey.page(scope: .space(.personal), namespace: namespace, section: descriptor, collection: .album(54)),
                          CacheKey.page(scope: .space(.personal), namespace: namespace, section: descriptor, collection: .album(55)))
    }

    func testConfirmedFavoriteSharesCanonicalDetailsAcrossCollections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let descriptor = section(1)
        let photo = try item(7)
        let repository = try makeRepository(root: root, transport: transport)
        for collection: PhotoCollectionDescriptor in [.album(54), .library(.personal)] {
            try await seedMetadataPage([photo], section: descriptor, repository: repository, collection: collection)
        }
        await transport.configure(pageItems: [photo])
        let action = SelectionFavoriteAction(affectedIDs: [photo.id], targetFavorite: true,
            sectionsByID: [photo.id: descriptor], collection: .album(54), itemsByID: [photo.id: photo])
        try await repository.setFavoritesBatch(action: action)
        for collection: PhotoCollectionDescriptor in [.album(54), .library(.personal)] {
            let cached = try await repository.store.metadataPage(try XCTUnwrap(DayPageAddress(section: descriptor, collection: collection)), namespace: await repository.metadataNamespace(for: collection), currentRun: repository.runID)
            XCTAssertEqual(cached?.slots.first?.item?.isFavorite, true)
        }
        let writes = await transport.favoriteWrites
        XCTAssertEqual(writes.map(\.0), [photo.id])
    }
    func testMembershipMutationRefreshesSameCountAndPreservesLibrary() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let old = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(1))
        let updated = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(2))
        await transport.configure(albumList: [old], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [updated])
        let repository = try makeRepository(root: root, transport: transport)
        let descriptor = section(1)
        try await seedMetadataPage([try item(1)], section: descriptor, repository: repository, collection: .library(.personal))
        for await _ in await repository.albums() { }
        var albumSection: TimelineSection?
        var albumSnapshot: TimelineSnapshot?
        for await event in await repository.timeline(collection: .album(54)) {
            if case .value(let snapshot, true) = event { albumSection = snapshot.sections.first; albumSnapshot = snapshot }
        }
        let snapshot = try XCTUnwrap(albumSnapshot)
        let filter = PhotoCollectionDescriptor.libraryFilter(UUID(), scope: .album(54))
        try await repository.registerLibraryFilter(.init(descriptor: filter, snapshot: snapshot,
            referencesBySection: [[.init(sourceSectionIndex: 0, sourcePageOffset: 0, itemID: 1)]],
            filter: LibraryFilter(), revision: 1, sourceFingerprint: LibraryIndex(snapshot: snapshot).fingerprint,
            sourceCollection: .album(54)))
        try await repository.addItems([2], toAlbum: 54)
        var filterFailed = false
        for await event in await repository.page(try XCTUnwrap(albumSection), collection: filter) {
            if case .failure = event { filterFailed = true }
        }
        XCTAssertTrue(filterFailed)
        let summaries = try await repository.store.metadataAlbumSummaries(repository.personalMetadataNamespace)
        XCTAssertEqual(summaries?.albums.first?.thumbnail?.unitID, 2)
        let address = try DayPageAddress(section: XCTUnwrap(albumSection), collection: .album(54))
        let albumPage = try await repository.store.metadataPage(address, namespace: await repository.metadataNamespace(for: .album(54)), currentRun: repository.runID)
        XCTAssertEqual(albumPage?.slots.map(\.itemID), [2])
        let personalAddress = try DayPageAddress(section: descriptor, collection: .library(.personal))
        let personal = try await repository.store.metadataPage(personalAddress, namespace: repository.personalMetadataNamespace, currentRun: repository.runID)
        XCTAssertEqual(personal?.slots.map(\.itemID), [1])
    }

    func testAmbiguousFailureStillRefreshesMembership() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let old = AlbumSummary(id: 54, name: "Trip", itemCount: 1)
        let updated = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(2))
        await transport.configure(albumList: [old], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [updated], fails: true)
        let repository = try makeRepository(root: root, transport: transport)
        do { try await repository.addItems([2], toAlbum: 54); XCTFail("Expected failure") } catch { }
        let summaries = try await repository.store.metadataAlbumSummaries(repository.personalMetadataNamespace)
        XCTAssertEqual(summaries?.albums.first?.thumbnail?.unitID, 2)
        let calls = await transport.albumTimelineCalls
        XCTAssertEqual(calls, [54])
    }

    func testCancelledMutationReconcilesWithoutClaimingSuccess() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let old = AlbumSummary(id: 54, name: "Trip", itemCount: 1)
        let updated = AlbumSummary(id: 54, name: "Trip", itemCount: 1, thumbnail: thumbnail(2))
        await transport.configure(albumList: [old], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [updated])
        await transport.pauseNextMutation()
        let repository = try makeRepository(root: root, transport: transport)
        let mutation = Task { try await repository.addItems([2], toAlbum: 54) }
        while !(await transport.mutationStarted) { await Task.yield() }
        mutation.cancel()
        await transport.releaseMutation()
        do { try await mutation.value; XCTFail("Expected cancellation") } catch { }
        let summaries = try await repository.store.metadataAlbumSummaries(repository.personalMetadataNamespace)
        XCTAssertEqual(summaries?.albums.first?.thumbnail?.unitID, 2)
    }

    func testAdmittedOldCatalogCannotOverwriteMutation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = AlbumFakeTransport()
        let day = Int64(1_704_067_200)
        let album = AlbumSummary(id: 54, name: "Trip", itemCount: 1)
        await transport.configure(albumList: [album], albumEntriesByID: [54: [.init(id: 1, time: day)]])
        await transport.configureMutation(entries: [.init(id: 2, time: day)], list: [album])
        await transport.pauseNextCatalog()
        let repository = try makeRepository(root: root, transport: transport)
        let oldRead = Task { for await _ in await repository.timeline(collection: .album(54)) { } }
        while !(await transport.catalogStarted) { await Task.yield() }
        try await repository.addItems([2], toAlbum: 54)
        await transport.releaseCatalog()
        await oldRead.value
        let catalog = try await repository.store.metadataCatalog(CollectionKey(namespace: await repository.metadataNamespace(for: .album(54)), collection: .album(54)))
        let snapshot = try CollectionDayPager.snapshot(catalog: XCTUnwrap(catalog).catalog)
        let address = try DayPageAddress(section: XCTUnwrap(snapshot.sections.first), collection: .album(54))
        let page = try await repository.store.metadataPage(address, namespace: await repository.metadataNamespace(for: .album(54)), currentRun: repository.runID)
        XCTAssertEqual(page?.slots.map(\.itemID), [2])
    }

}
