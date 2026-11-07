import PhotoCache
import SwiftUI
import SynologyAPI

/// Album creation, membership, rename and deletion started from the browser, menus and drags.
extension LibraryModel {
    var canManageAlbumSelection: Bool {
        browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsAlbumMembership && browserHasSelection &&
        browserCommandSnapshot.timeline != nil && browserCommandSnapshot.authority != nil &&
        albumOperation == nil && !canCloseViewer
    }

    var canRemoveAlbumSelection: Bool {
        canManageAlbumSelection && isNormalAlbum(browserCommandSnapshot.sourceAlbumID)
    }

    func beginAlbumOperation(_ kind: AlbumOperation.Kind) {
        guard canManageAlbumSelection else { return }
        beginAlbumOperation(kind, captured: browserCommandSnapshot)
    }

    func beginEmptyAlbumCreation() {
        guard albumOperation == nil, repository != nil else { return }
        var operation = AlbumOperation(kind: .create, sourceAlbumID: nil)
        operation.createsEmptyAlbum = true
        operation.loading = false
        albumOperation = operation
    }

    /// Deletes an owned album in the background as a tracked activity; never retried.
    func deleteAlbum(_ id: Int64) {
        guard let repository else { return }
        let handle = activity.begin(.deleteAlbum(name: albumName(id)), queued: true)
        enqueueAlbumWrite(handle) { [weak self] in
            do {
                try await repository.deleteAlbum(id: id)
                handle.succeed()
            } catch {
                handle.fail(error, operation: "Album deletion")
            }
            guard let self else { return }
            self.albumsTask?.cancel()
            self.albumsTask = nil
            self.ensureAlbumsLoaded()
        }
    }

    /// Renames in the album write queue. The rename sheet waits for the result and shows its own
    /// error, so only History records it.
    func renameAlbum(_ id: Int64, name: String) async throws {
        guard let repository else { throw RepositoryError.unavailable("The photo library is unavailable.") }
        let previousName = albumName(id)
        let kind = ActivityKind.renameAlbum(from: previousName, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try await serializedAlbumWrite { try await repository.renameAlbum(id: id, name: name) }
            activity.record(kind, outcome: .succeeded)
        } catch {
            let failure = ActivityFailure(error: error, operation: "Album rename")
            activity.record(kind, outcome: failure.unconfirmed ? .unconfirmed : .failed, failure: failure)
            throw error
        }
        albumsTask?.cancel()
        albumsTask = nil
        ensureAlbumsLoaded()
    }

    /// Runs album writes one after another: the repository rejects a second concurrent album
    /// mutation instead of waiting for it.
    func serializedAlbumWrite<Value: Sendable>(_ body: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = albumWriteTail
        let write = Task { @MainActor in
            await previous?.value
            return try await body()
        }
        albumWriteTail = Task { _ = try? await write.value }
        return try await write.value
    }

    /// Queues a tracked album write; its activity starts running when its turn comes.
    func enqueueAlbumWrite(_ handle: ActivityHandle, _ body: @escaping @MainActor () async -> Void) {
        Task { [weak self] in
            try? await self?.serializedAlbumWrite {
                handle.start()
                await body()
            }
        }
    }

    func albumName(_ id: Int64) -> String {
        albums.first { $0.id == id }?.name ?? "album"
    }

    func isNormalAlbum(_ id: Int64?) -> Bool {
        isKnownNormalAlbum(id, in: albums)
    }

    /// One-item selection of the viewer photo for album menus and drags; nil when the collection
    /// cannot contribute or the viewer's index no longer matches the collection's timeline.
    func viewerAlbumSnapshot(collection: PhotoCollectionDescriptor, fingerprint: String, ordinal: Int, itemID: Int64) -> BrowserCommandSnapshot? {
        guard capabilities(for: collection).allowsAlbumMembership, let timeline = snapshot(for: collection),
              LibraryIndex(snapshot: timeline).fingerprint == fingerprint,
              let authority = selectionAuthority(for: collection) else { return nil }
        return BrowserCommandSnapshot(owner: UUID(), active: true, canOpen: false,
            canToggleFavorite: false, collection: collection, indexFingerprint: fingerprint, selectionGeneration: nil,
            selectedOrdinals: IndexSet(integer: ordinal), knownItemIDsByOrdinal: [ordinal: itemID],
            timeline: timeline, authority: authority, sourceAlbumID: capabilities(for: collection).sourceAlbumID)
    }

    func beginAlbumOperation(_ kind: AlbumOperation.Kind, captured: BrowserCommandSnapshot) {
        guard capabilities(for: captured.collection).allowsAlbumMembership, albumOperation == nil, let timeline = captured.timeline,
              let fingerprint = captured.indexFingerprint, let authority = captured.authority,
              repository != nil else { return }
        if kind == .remove && !isNormalAlbum(captured.sourceAlbumID) { return }
        let selection = PhotoSelectionSnapshot(collection: captured.collection, timeline: timeline,
            timelineFingerprint: fingerprint, selectedOrdinals: captured.selectedOrdinals,
            knownItemIDsByOrdinal: captured.knownItemIDsByOrdinal, authority: authority)
        beginAlbumOperation(kind, selection: selection, sourceAlbumID: captured.sourceAlbumID)
    }

    func beginAlbumOperation(_ kind: AlbumOperation.Kind, selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?) {
        guard capabilities(for: selection.collection).allowsAlbumMembership, albumOperation == nil, let repository, selection.authority != nil,
              !selection.selectedOrdinals.isEmpty else { return }
        if kind == .remove && !isNormalAlbum(sourceAlbumID) { return }
        var operation = AlbumOperation(kind: kind, sourceAlbumID: sourceAlbumID)
        operation.collection = selection.collection
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection)
            guard !Task.isCancelled, let self, self.albumOperation?.id == operation.id else { return }
            guard let resolved, !resolved.items.isEmpty else {
                self.albumOperation = nil
                self.reportUnverified(kind.actionName, message: "The selected items could not be verified. Try again.")
                return
            }
            self.albumOperation?.selection = resolved
            if kind == .add {
                do {
                    let albums = try await repository.addableAlbums()
                    guard !Task.isCancelled, self.albumOperation?.id == operation.id else { return }
                    self.albumOperation?.albums = albums
                } catch {
                    guard !Task.isCancelled, self.albumOperation?.id == operation.id else { return }
                    self.albumOperation?.loadError = error.localizedDescription
                }
            }
            self.albumOperation?.loading = false
        }
    }

    /// Adds a captured selection (menu or drag) independently of browser focus, without a sheet.
    @discardableResult
    func addCapturedSelection(_ selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?, to albumID: Int64) -> Bool {
        guard capabilities(for: selection.collection).allowsAlbumMembership, albumOperation == nil, let repository, selection.authority != nil,
              (sessionSources[selection.collection] ?? selection.collection).incomingAlbumIdentity == nil,
              !selection.selectedOrdinals.isEmpty else { return false }
        let name = albumName(albumID)
        let handle = activity.begin(.addToAlbum(id: albumID, name: name), totalCount: selection.selectedOrdinals.count, queued: true)
        enqueueAlbumWrite(handle) { [weak self] in
            var attempted = false
            do {
                let addable = try await repository.addableAlbums()
                guard addable.contains(where: { $0.id == albumID }) else {
                    throw RepositoryError.stale("This album is no longer available for adding items.")
                }
                guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
                      !resolved.items.isEmpty else {
                    throw RepositoryError.stale("The selected items could not be verified. Try again.")
                }
                if sourceAlbumID == albumID {
                    handle.discard()
                    return
                }
                handle.setItems(resolved.items.map { ActivityItem(photo: $0, collection: selection.collection) })
                attempted = true
                try await repository.addMissingItems(resolved, toAlbum: albumID)
                handle.succeed()
            } catch {
                handle.fail(error, operation: "Album operation")
            }
            if attempted { self?.refreshAfterAlbumWrite(kind: .add, albumID: albumID) }
        }
        return true
    }

    @discardableResult
    func addCapturedSelection(_ selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?, to collection: PhotoCollectionDescriptor) -> Bool {
        if let id = collection.albumID { return addCapturedSelection(selection, sourceAlbumID: sourceAlbumID, to: id) }
        guard collection.incomingAlbumIdentity != nil, capabilities(for: selection.collection).allowsPersonalActions, albumOperation == nil, let repository,
              (sessionSources[selection.collection] ?? selection.collection).incomingAlbumIdentity == nil,
              selection.authority != nil, !selection.selectedOrdinals.isEmpty else { return false }
        let identity = collection.incomingAlbumIdentity
        let name = receivedIncomingAlbums.first { $0.id == identity?.albumID && $0.ownerUserID == identity?.ownerID }?.name
            ?? "shared album"
        let handle = activity.begin(.addToIncomingAlbum(name: name), totalCount: selection.selectedOrdinals.count, queued: true)
        enqueueAlbumWrite(handle) { [weak self] in
            do {
                guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
                      !resolved.items.isEmpty else {
                    throw RepositoryError.stale("The selected items could not be verified. Try again.")
                }
                handle.setItems(resolved.items.map { ActivityItem(photo: $0, collection: selection.collection) })
                try await repository.addItems(resolved, toIncomingAlbum: collection)
                handle.succeed()
            } catch {
                handle.fail(error, operation: "Album operation")
                return
            }
            guard let self else { return }
            self.incomingAlbumsTask?.cancel()
            self.incomingAlbumsTask = nil
            self.startAlbumListFetchIfNeeded()
            self.collectionFetchTasks.removeValue(forKey: collection)?.cancel()
            if self.openedCollections.contains(collection) { self.startCollectionFetchIfNeeded(collection) }
        }
        return true
    }

    func cancelAlbumOperation() {
        albumOperationTask?.cancel()
        albumOperationTask = nil
        albumOperation = nil
    }

    /// Closes the sheet and runs the write in the album queue as a tracked activity. Album
    /// creation and removal are not retried.
    func submitAlbumOperation(name: String = "", albumID: Int64? = nil) {
        guard let operation = albumOperation, !operation.loading,
              operation.selection != nil || operation.createsEmptyAlbum,
              let repository else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation.kind == .create && trimmed.isEmpty { return }
        if operation.kind == .add && albumID == nil { return }
        albumOperation = nil
        albumOperationTask = nil
        let selection = operation.selection
        let items = (selection?.items ?? []).map { ActivityItem(photo: $0, collection: operation.collection ?? .library(.personal)) }
        let kind: ActivityKind
        switch operation.kind {
        case .create: kind = .createAlbum(name: trimmed)
        case .add:
            let id = albumID ?? 0
            kind = .addToAlbum(id: id, name: operation.albums.first { $0.id == id }?.name ?? albumName(id))
        case .remove:
            let id = operation.sourceAlbumID ?? 0
            kind = .removeFromAlbum(id: id, name: albumName(id))
        }
        let handle = activity.begin(kind, items: items, queued: true)
        enqueueAlbumWrite(handle) { [weak self] in
            do {
                switch operation.kind {
                case .create:
                    if operation.createsEmptyAlbum {
                        _ = try await repository.createEmptyAlbum(name: trimmed)
                    } else if let selection {
                        _ = try await repository.createAlbum(name: trimmed, selection: selection)
                    }
                case .add:
                    guard let albumID, let selection else { return }
                    try await repository.addItems(selection, toAlbum: albumID)
                case .remove:
                    guard let source = operation.sourceAlbumID, let selection else { return }
                    try await repository.removeItems(selection, fromAlbum: source)
                }
                handle.succeed()
            } catch {
                handle.fail(error, operation: "Album operation")
            }
            self?.refreshAfterAlbumWrite(kind: operation.kind,
                                         albumID: operation.kind == .remove ? operation.sourceAlbumID : albumID)
        }
    }

    func refreshAfterAlbumWrite(kind: AlbumOperation.Kind, albumID: Int64?) {
        albumsTask?.cancel()
        albumsTask = nil
        if albumListRequested { startAlbumListFetchIfNeeded() }
        guard let id = albumID else { return }
        let collection = PhotoCollectionDescriptor.album(id)
        changedAlbumID = id
        albumMembershipRevision &+= 1
        guard openedCollections.contains(collection) else { return }
        collectionFetchTasks.removeValue(forKey: collection)?.cancel()
        startCollectionFetchIfNeeded(collection, reason: .favoriteMutationRefresh)
    }
}

struct AlbumOperation: Identifiable {
    enum Kind {
        case create, add, remove

        var actionName: String {
            switch self {
            case .create: "New Album"
            case .add: "Add to Album"
            case .remove: "Remove from Album"
            }
        }
    }
    let id = UUID()
    let kind: Kind
    let sourceAlbumID: Int64?
    /// The collection the selection was captured from.
    var collection: PhotoCollectionDescriptor?
    var selection: ResolvedPhotoSelection?
    var createsEmptyAlbum = false
    var albums: [AlbumSummary] = []
    var loading = true
    /// Why the album list could not be read; the sheet stays open to show it.
    var loadError: String?
}
