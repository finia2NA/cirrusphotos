import PhotoCache
import SwiftUI
import SynologyAPI

/// Album creation, membership, rename and deletion started from the browser, menus and drags.
extension LibraryModel {
    var canManageAlbumSelection: Bool {
        browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsAlbumMembership && !browserCommandSnapshot.selectedOrdinals.isEmpty &&
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

    func deleteAlbum(_ id: Int64) {
        guard deletingAlbumID == nil, albumOperation == nil, let repository else { return }
        deletingAlbumID = id
        Task { [weak self] in
            do { try await repository.deleteAlbum(id: id) }
            catch { self?.albumOperationError = reportedFailure(error, operation: "Album deletion") }
            guard let self else { return }
            self.deletingAlbumID = nil
            self.albumsTask?.cancel()
            self.albumsTask = nil
            self.ensureAlbumsLoaded()
        }
    }

    func renameAlbum(_ id: Int64, name: String) async throws {
        guard deletingAlbumID == nil, albumOperation == nil, let repository else {
            throw RepositoryError.busy("Another album change is in progress. Try again.")
        }
        deletingAlbumID = id
        defer {
            deletingAlbumID = nil
            albumsTask?.cancel()
            albumsTask = nil
            ensureAlbumsLoaded()
        }
        try await repository.renameAlbum(id: id, name: name)
    }

    func isNormalAlbum(_ id: Int64?) -> Bool {
        isKnownNormalAlbum(id, in: albums)
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
        let operation = AlbumOperation(kind: kind, sourceAlbumID: sourceAlbumID)
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection)
            guard !Task.isCancelled, let self, self.albumOperation?.id == operation.id else { return }
            guard let resolved, !resolved.items.isEmpty else {
                self.albumOperation = nil
                self.albumOperationError = "The selected items could not be verified. Try again."
                return
            }
            self.albumOperation?.selection = resolved
            if kind == .add {
                do {
                    let albums = try await repository.addableAlbums()
                    guard !Task.isCancelled, self.albumOperation?.id == operation.id else { return }
                    self.albumOperation?.albums = albums
                } catch {
                    guard !Task.isCancelled else { return }
                    self.albumOperation = nil
                    self.albumOperationError = reportedFailure(error, operation: "Album operation")
                }
            }
            self.albumOperation?.loading = false
        }
    }

    /// Adds a captured selection independently of browser focus.
    @discardableResult
    func addCapturedSelection(_ selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?, to albumID: Int64) -> Bool {
        guard capabilities(for: selection.collection).allowsAlbumMembership, albumOperation == nil, let repository, selection.authority != nil,
              (sessionSources[selection.collection] ?? selection.collection).incomingAlbumIdentity == nil,
              !selection.selectedOrdinals.isEmpty else { return false }
        let operation = AlbumOperation(kind: .add, sourceAlbumID: sourceAlbumID)
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            do {
                let addable = try await repository.addableAlbums()
                guard !Task.isCancelled, addable.contains(where: { $0.id == albumID }) else {
                    throw RepositoryError.stale("This album is no longer available for adding items.")
                }
                guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
                      !resolved.items.isEmpty, !Task.isCancelled else {
                    throw RepositoryError.stale("The selected items could not be verified. Try again.")
                }
                guard let self, self.albumOperation?.id == operation.id else { return }
                if sourceAlbumID == albumID {
                    self.albumOperation = nil
                    return
                }
                self.albumOperation?.writing = true
                try await repository.addMissingItems(resolved, toAlbum: albumID)
                guard self.albumOperation?.id == operation.id else { return }
                self.refreshAfterAlbumOperation(operation, destinationID: albumID)
                self.albumOperation = nil
            } catch {
                guard let self, self.albumOperation?.id == operation.id else { return }
                if self.albumOperation?.writing == true { self.refreshAfterAlbumOperation(operation, destinationID: albumID) }
                self.albumOperation = nil
                if !Task.isCancelled { self.albumOperationError = reportedFailure(error, operation: "Album operation") }
            }
        }
        return true
    }

    @discardableResult
    func addCapturedSelection(_ selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?, to collection: PhotoCollectionDescriptor) -> Bool {
        if let id = collection.albumID { return addCapturedSelection(selection, sourceAlbumID: sourceAlbumID, to: id) }
        guard collection.incomingAlbumIdentity != nil, capabilities(for: selection.collection).allowsPersonalActions, albumOperation == nil, let repository,
              (sessionSources[selection.collection] ?? selection.collection).incomingAlbumIdentity == nil,
              selection.authority != nil, !selection.selectedOrdinals.isEmpty else { return false }
        let operation = AlbumOperation(kind: .add, sourceAlbumID: sourceAlbumID)
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            do {
                guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
                      !resolved.items.isEmpty, !Task.isCancelled else {
                    throw RepositoryError.stale("The selected items could not be verified. Try again.")
                }
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.albumOperation?.writing = true
                try await repository.addItems(resolved, toIncomingAlbum: collection)
                guard self.albumOperation?.id == operation.id else { return }
                self.albumOperation = nil
                self.incomingAlbumsTask?.cancel()
                self.incomingAlbumsTask = nil
                self.startAlbumListFetchIfNeeded()
                self.collectionFetchTasks.removeValue(forKey: collection)?.cancel()
                if self.openedCollections.contains(collection) { self.startCollectionFetchIfNeeded(collection) }
            } catch {
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.albumOperation = nil
                if !Task.isCancelled { self.albumOperationError = reportedFailure(error, operation: "Album operation") }
            }
        }
        return true
    }

    func cancelAlbumOperation() {
        albumOperationTask?.cancel()
        albumOperationTask = nil
        albumOperation = nil
    }

    func submitAlbumOperation(name: String = "", albumID: Int64? = nil) {
        guard var operation = albumOperation, !operation.loading,
              operation.selection != nil || operation.createsEmptyAlbum,
              let repository else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation.kind == .create && trimmed.isEmpty { return }
        if operation.kind == .add && albumID == nil { return }
        operation.loading = true
        operation.writing = true
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            do {
                switch operation.kind {
                case .create:
                    if operation.createsEmptyAlbum {
                        _ = try await repository.createEmptyAlbum(name: trimmed)
                    } else if let selection = operation.selection {
                        _ = try await repository.createAlbum(name: trimmed, selection: selection)
                    }
                case .add:
                    guard let albumID, let selection = operation.selection else { return }
                    try await repository.addItems(selection, toAlbum: albumID)
                case .remove:
                    guard let source = operation.sourceAlbumID, let selection = operation.selection else { return }
                    try await repository.removeItems(selection, fromAlbum: source)
                }
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.refreshAfterAlbumOperation(operation, destinationID: albumID)
                self.albumOperation = nil
            } catch {
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.refreshAfterAlbumOperation(operation, destinationID: albumID)
                self.albumOperation = nil
                self.albumOperationError = reportedFailure(error, operation: "Album operation")
            }
        }
    }

    func refreshAfterAlbumOperation(_ operation: AlbumOperation, destinationID: Int64?) {
        albumsTask?.cancel()
        albumsTask = nil
        if albumListRequested { startAlbumListFetchIfNeeded() }
        let id = operation.kind == .remove ? operation.sourceAlbumID : destinationID
        guard let id else { return }
        let collection = PhotoCollectionDescriptor.album(id)
        changedAlbumID = id
        albumMembershipRevision &+= 1
        guard openedCollections.contains(collection) else { return }
        collectionFetchTasks.removeValue(forKey: collection)?.cancel()
        startCollectionFetchIfNeeded(collection, reason: .favoriteMutationRefresh)
    }
}

struct AlbumOperation: Identifiable {
    enum Kind { case create, add, remove }
    let id = UUID()
    let kind: Kind
    let sourceAlbumID: Int64?
    var selection: ResolvedPhotoSelection?
    var createsEmptyAlbum = false
    var albums: [AlbumSummary] = []
    var loading = true
    var writing = false
}
