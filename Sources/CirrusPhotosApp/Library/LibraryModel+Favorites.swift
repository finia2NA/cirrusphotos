import PhotoCache
import SwiftUI
import SynologyAPI

extension LibraryModel {
    // MARK: - Selection Favorites

    /// Begins a selection favorite operation for the active browser. Routes through
    /// the viewer if it is open; otherwise resolves the full browser selection.
    func toggleSelectionFavorite() {
        if activeViewer != nil {
            toggleViewerFavorite()
            return
        }
        guard canToggleBrowserFavorite, let repository else { return }
        let snap = browserCommandSnapshot
        guard snap.active, !snap.selectedOrdinals.isEmpty else { return }
        enqueueFavorite(snapshot: snap, repository: repository)
    }

    /// Captures the selection now and queues its favorite change. Presses never wait for or
    /// drop each other: each is resolved and sent after the previous one, so a toggle sees the
    /// result of the one before it.
    private func enqueueFavorite(snapshot: BrowserCommandSnapshot, repository: CachedPhotosRepository) {
        let selection = snapshot.captureSelection(timeline: snapshots[snapshot.collection])
        let previous = favoriteWriteTail
        favoriteWriteTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard let selection else {
                reportUnverified("Favorite")
                return
            }
            await resolveThenMutateFavorites(selection: selection, repository: repository)
        }
    }

    // MARK: - Selection favorite state

    private static let favoriteStateSelectionLimit = 50

    /// Resolves whether the whole browser selection is favorited. Larger selections are not
    /// resolved, since the heart then only toggles. Keeps the last value while the browser
    /// is not the key responder (for example while the Info panel is key).
    func refreshBrowserSelectionFavorite(force: Bool = false) {
        guard browserCommandSnapshot.active else { return }
        let snapshot = browserCommandSnapshot
        guard let repository, capabilities(for: snapshot.collection).allowsSpaceItemActions,
              (1...Self.favoriteStateSelectionLimit).contains(snapshot.selectedOrdinals.count) else {
            favoriteStateKey = nil
            favoriteStateTask?.cancel()
            if browserSelectionFavorited { browserSelectionFavorited = false }
            return
        }
        observeFavoriteChanges(of: repository)
        let key = "\(snapshot.collection.rawValue)|\(snapshot.indexFingerprint ?? "")|" +
            snapshot.selectedOrdinals.map(String.init).joined(separator: ",")
        guard force || key != favoriteStateKey else { return }
        favoriteStateKey = key
        favoriteStateTask?.cancel()
        favoriteStateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self,
                  let selection = snapshot.captureSelection(timeline: snapshots[snapshot.collection]) else { return }
            let action = await SelectionFavoriteResolver(repository: repository).resolve(selection)
            guard !Task.isCancelled else { return }
            let value = action.map { !$0.targetFavorite } ?? false
            if browserSelectionFavorited != value { browserSelectionFavorited = value }
        }
    }

    /// Favorite writes from any surface (viewer, browser, Info panel) refresh the state.
    private func observeFavoriteChanges(of repository: CachedPhotosRepository) {
        let identifier = ObjectIdentifier(repository)
        guard identifier != favoriteObserverRepository else { return }
        favoriteObserverRepository = identifier
        favoriteObserverTasks.forEach { $0.cancel() }
        favoriteObserverTasks = [PhotoSpace.personal, .shared].map { space in
            Task { [weak self] in
                for await _ in await repository.favoriteChanges(space: space) {
                    guard !Task.isCancelled else { return }
                    self?.refreshBrowserSelectionFavorite(force: true)
                }
            }
        } + [Task { [weak self] in
            for await change in await repository.photoItemChanges() where !change.favoriteValues.isEmpty {
                guard !Task.isCancelled else { return }
                self?.refreshBrowserSelectionFavorite(force: true)
            }
        }]
    }

    func canFavoriteFromInfoPanel(viewerActive: Bool, collection: PhotoCollectionDescriptor, selection: IndexSet) -> Bool {
        if viewerActive { return canToggleViewerFavorite }
        return capabilities(for: collection).allowsSpaceItemActions && timelineVerified(for: collection) &&
            pendingFavoriteConfirmation == nil &&
            infoPanelSnapshot(collection: collection, selection: selection)?.canToggleFavorite == true
    }

    /// Toggles the Info panel's single item. The panel is its own key window, so the
    /// browser's menu-bar command state is not used.
    func toggleInfoPanelFavorite(viewerActive: Bool, collection: PhotoCollectionDescriptor, selection: IndexSet) {
        guard canFavoriteFromInfoPanel(viewerActive: viewerActive, collection: collection, selection: selection) else { return }
        if viewerActive {
            toggleViewerFavorite()
            return
        }
        guard let repository, let snapshot = infoPanelSnapshot(collection: collection, selection: selection) else { return }
        enqueueFavorite(snapshot: snapshot, repository: repository)
    }

    private func resolveThenMutateFavorites(selection: PhotoSelectionSnapshot,
                                            repository: CachedPhotosRepository) async {
        let selectedEntireCollection = !selection.selectedOrdinals.isEmpty &&
            selection.selectedOrdinals.count == LibraryIndex(snapshot: selection.timeline).totalCount
        guard let action = await SelectionFavoriteResolver(repository: repository).resolve(selection) else {
            reportUnverified("Favorite")
            return
        }

        guard !action.affectedIDs.isEmpty else { return }

        if selectedEntireCollection || action.affectedIDs.count > 5 {
            // The queue waits for the answer, so later presses see this change's result.
            let confirmed = await withCheckedContinuation { continuation in
                favoriteConfirmationReply = continuation
                pendingFavoriteConfirmation = SelectionFavoriteConfirmation(action: action)
                updateBrowserFavoriteAvailability()
            }
            guard confirmed else { return }
        }
        await executeFavoriteAction(action, repository: repository)
    }

    func confirmBrowserFavorite() {
        answerFavoriteConfirmation(true)
    }

    func cancelBrowserFavorite() {
        answerFavoriteConfirmation(false)
    }

    /// Clears the confirmation alert and lets the waiting favorite change continue or stop.
    func answerFavoriteConfirmation(_ confirmed: Bool) {
        pendingFavoriteConfirmation = nil
        updateBrowserFavoriteAvailability()
        let reply = favoriteConfirmationReply
        favoriteConfirmationReply = nil
        reply?.resume(returning: confirmed)
    }

    func executeFavoriteAction(_ action: SelectionFavoriteAction,
                                       repository: CachedPhotosRepository) async {
        await FavoriteActivity.run(action, repository: repository, activity: activity)
    }
}

/// Carries the resolved action while awaiting user confirmation.
struct SelectionFavoriteConfirmation: Identifiable, Sendable {
    var id: String { "\(action.targetFavorite):\(action.affectedIDs.count)" }
    let action: SelectionFavoriteAction

    var title: String {
        let count = action.affectedIDs.count
        let noun = count == 1 ? "Photo" : "Photos"
        if action.targetFavorite {
            return "Add \(count) \(noun) to Favorites?"
        } else {
            return "Remove \(count) \(noun) from Favorites?"
        }
    }

    var actionButtonTitle: String {
        if action.targetFavorite {
            return "Add to Favorites"
        } else {
            return "Remove from Favorites"
        }
    }
}
