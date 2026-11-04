import Foundation
import PhotoCache
import SynologyAPI

/// Runs a favorite change as a tracked activity: counts down per confirmed chunk, lists the
/// photos that failed, and retries only those.
@MainActor
enum FavoriteActivity {
    static func run(_ action: SelectionFavoriteAction, repository: CachedPhotosRepository,
                    activity: ActivityCenter) async {
        let items = action.affectedIDs.compactMap { id in
            action.itemsByID[id].map { ActivityItem(photo: $0, collection: action.collection) }
        }
        let handle = activity.begin(.favorite(action.targetFavorite), items: items,
                                    totalCount: action.affectedIDs.count,
                                    retry: retry(action, repository: repository, activity: activity))
        let confirmed = ActivityCounter()
        do {
            try await repository.setFavoritesBatch(action: action) { ids in
                Task { @MainActor in
                    confirmed.value += ids.count
                    handle.progress(completed: confirmed.value)
                }
            }
            handle.succeed()
        } catch let error as BatchFavoriteError {
            let failed = Set(error.outcome.failedIDs)
            handle.fail(error.underlyingError, operation: "Favorites",
                        failedItems: items.filter { $0.photoID.map(failed.contains) ?? false })
        } catch {
            handle.fail(error, operation: "Favorites")
        }
    }

    /// Repeats the change for the chosen failed photos. The target value is absolute, so a
    /// repeat is safe.
    static func retry(_ action: SelectionFavoriteAction, repository: CachedPhotosRepository,
                      activity: ActivityCenter) -> ActivityRetry {
        { [weak activity] items in
            let ids = Set(items.compactMap(\.photoID))
            guard let activity, !ids.isEmpty else { return false }
            Task { await run(action.restricted(to: ids), repository: repository, activity: activity) }
            return true
        }
    }
}

/// A main-actor counter shared with progress callbacks.
@MainActor
final class ActivityCounter {
    var value = 0
}

extension LibraryModel {
    /// Reports a selection that could not be verified before a change was sent.
    func reportUnverified(_ action: String, message: String = "The selected photos could not be verified. Try again.") {
        reportNotStarted(action, error: .stale(message))
    }

    /// Reports a change that stopped before anything was sent to the NAS.
    func reportNotStarted(_ action: String, error: RepositoryError) {
        activity.begin(.unverified(action: action)).fail(error, operation: action)
    }
}
