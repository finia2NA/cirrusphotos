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
