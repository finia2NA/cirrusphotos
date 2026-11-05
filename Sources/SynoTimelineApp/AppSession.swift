import PhotoCache
import SynologyAPI

/// The signed-in account. It creates the repository from the stored credentials and owns the
/// account's transfers, in-process drag handles and Activity panel, so sign-in, sign-out and
/// account switching (#83) replace this object rather than reaching into models.
///
/// Signing out calls `end()` and then builds a new session and a new `LibraryModel`:
/// the model keeps its own tracked repository reference, so it is replaced, not cleared.
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
         makeRepository: @escaping @MainActor (AppPreferences) throws -> CachedPhotosRepository = AppSession.storedAccountRepository) {
        self.preferences = preferences
        self.repository = repository
        self.activity = activity
        self.downloads = PhotoDownloadManager(activity: activity)
        self.uploads = PhotoUploadManager(activity: activity)
        self.drags = LocalDragRegistry()
        self.makeRepository = makeRepository
    }

    static func storedAccountRepository(_ preferences: AppPreferences) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: CredentialStore.load(), budget: preferences.budgetBytes)
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
