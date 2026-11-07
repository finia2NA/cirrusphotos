import PhotoCache
import SynologyAPI

/// The signed-in account. It creates the repository through its factory and owns the
/// account's transfers, in-process drag handles and Activity panel. `AccountController`
/// replaces the whole `AccountContext`, including this object, on sign-out and switching.
@MainActor
final class AppSession {
    let preferences: AppPreferences
    let activity: ActivityCenter
    let downloads: PhotoDownloadManager
    let uploads: PhotoUploadManager
    let drags: LocalDragRegistry
    private(set) var repository: CachedPhotosRepository?
    private(set) var isEnded = false
    private let makeRepository: @MainActor (AppPreferences) throws -> CachedPhotosRepository

    init(preferences: AppPreferences, repository: CachedPhotosRepository? = nil, activity: ActivityCenter = ActivityCenter(),
         makeRepository: @escaping @MainActor (AppPreferences) throws -> CachedPhotosRepository = AppSession.noAccount) {
        self.preferences = preferences
        self.repository = repository
        self.activity = activity
        self.downloads = PhotoDownloadManager(activity: activity)
        self.uploads = PhotoUploadManager(activity: activity)
        self.drags = LocalDragRegistry()
        self.makeRepository = makeRepository
    }

    static func noAccount(_ preferences: AppPreferences) throws -> CachedPhotosRepository {
        throw SynologyAPIError.configuration("No account is signed in.")
    }

    /// Opens the account's repository on first use. An ended session does not reopen it.
    func start() throws -> CachedPhotosRepository {
        if let repository { return repository }
        guard !isEnded else { throw CancellationError() }
        let repository = try makeRepository(preferences)
        self.repository = repository
        return repository
    }

    var hasActiveTransfers: Bool { downloads.hasActiveJobs || uploads.active }

    /// Cancels uploads and downloads; each settles as cancelled in the Activity panel.
    func cancelTransfers() {
        downloads.cancelAll()
        uploads.cancel()
    }

    /// Stops the account's work for sign-out. Transfers, editor handoffs, file promises and
    /// upload thumbnail polls are cancelled, drag handles are dropped so a late drop finds
    /// nothing, and running activities settle as cancelled without cancel or retry closures,
    /// since those would act on this account's repository. The managers refuse new work, and
    /// a file promise that Finder fulfils afterwards fails. Idempotent.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        downloads.end()
        uploads.end()
        drags.end()
        activity.end()
        repository = nil
    }
}
