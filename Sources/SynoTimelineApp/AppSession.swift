import PhotoCache
import SynologyAPI

/// The signed-in account. It creates the repository from the stored credentials and
/// is the one place account-specific state hangs from, so sign-in, sign-out and
/// account switching (#3) replace this object rather than reaching into models.
@MainActor
final class AppSession {
    let preferences: AppPreferences
    private(set) var repository: CachedPhotosRepository?
    private let makeRepository: @MainActor (AppPreferences) throws -> CachedPhotosRepository

    init(preferences: AppPreferences, repository: CachedPhotosRepository? = nil,
         makeRepository: @escaping @MainActor (AppPreferences) throws -> CachedPhotosRepository = AppSession.storedAccountRepository) {
        self.preferences = preferences
        self.repository = repository
        self.makeRepository = makeRepository
    }

    static func storedAccountRepository(_ preferences: AppPreferences) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: CredentialStore.load(), budget: preferences.budgetBytes)
    }

    /// Opens the account's repository on first use.
    func start() throws -> CachedPhotosRepository {
        if let repository { return repository }
        let repository = try makeRepository(preferences)
        self.repository = repository
        return repository
    }
}
