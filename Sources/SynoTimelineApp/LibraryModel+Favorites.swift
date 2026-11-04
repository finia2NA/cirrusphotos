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
        guard canToggleBrowserFavorite, !browserFavoriteBusy,
              let repository else { return }
        browserFavoriteFailure = nil
        let snap = browserCommandSnapshot
        guard snap.active, !snap.selectedOrdinals.isEmpty else { return }
        browserFavoriteBusy = true
        updateBrowserFavoriteAvailability()
        Task { [weak self] in
            await self?.resolveThenMutateFavorites(snapshot: snap, repository: repository)
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
            !browserFavoriteBusy && pendingFavoriteConfirmation == nil &&
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
        browserFavoriteFailure = nil
        browserFavoriteBusy = true
        updateBrowserFavoriteAvailability()
        Task { [weak self] in
            await self?.resolveThenMutateFavorites(snapshot: snapshot, repository: repository)
        }
    }

    func resolveThenMutateFavorites(snapshot: BrowserCommandSnapshot,
                                             repository: CachedPhotosRepository) async {
        defer {
            browserFavoriteBusy = false
            updateBrowserFavoriteAvailability()
        }
        guard let selection = snapshot.captureSelection(timeline: snapshots[snapshot.collection]) else { return }
        let selectedEntireCollection = !snapshot.selectedOrdinals.isEmpty &&
            snapshot.selectedOrdinals.count == LibraryIndex(snapshot: selection.timeline).totalCount
        guard let action = await SelectionFavoriteResolver(repository: repository).resolve(selection) else {
            browserFavoriteFailure = "The selected photos could not be verified. Try again."
            return
        }

        guard !action.affectedIDs.isEmpty else { return }

        if selectedEntireCollection || action.affectedIDs.count > 5 {
            let confirmation = SelectionFavoriteConfirmation(action: action)
            pendingFavoriteConfirmation = confirmation
            return
        }
        await executeFavoriteAction(action, repository: repository)
    }

    func confirmBrowserFavorite() {
        guard let confirmation = pendingFavoriteConfirmation,
              let repository else {
            pendingFavoriteConfirmation = nil
            return
        }
        let action = confirmation.action
        pendingFavoriteConfirmation = nil
        browserFavoriteBusy = true
        updateBrowserFavoriteAvailability()
        Task { [weak self] in
            defer {
                self?.browserFavoriteBusy = false
                self?.updateBrowserFavoriteAvailability()
            }
            await self?.executeFavoriteAction(action, repository: repository)
        }
    }

    func cancelBrowserFavorite() {
        pendingFavoriteConfirmation = nil
        browserFavoriteBusy = false
        updateBrowserFavoriteAvailability()
    }

    func dismissBrowserFavoriteFailure() {
        browserFavoriteFailure = nil
    }

    func executeFavoriteAction(_ action: SelectionFavoriteAction,
                                       repository: CachedPhotosRepository) async {
        do {
            try await repository.setFavoritesBatch(action: action)
        } catch {
            browserFavoriteFailure = reportedFailure(error, operation: "Favorites")
        }
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
