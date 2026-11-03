import PhotoCache
import SynologyAPI

/// The signed-in account. It creates the repository from a credential source and
/// is the one place account-specific state hangs from, so sign-in, sign-out and
/// account switching (#3) replace this object rather than reaching into models.
@MainActor
final class AppSession {
    let preferences: AppPreferences
    private(set) var repository: CachedPhotosRepository?
    private let credentials: () throws -> SynologyCredentials

    init(preferences: AppPreferences, repository: CachedPhotosRepository? = nil,
         credentials: @escaping () throws -> SynologyCredentials = CredentialStore.load) {
        self.preferences = preferences
        self.repository = repository
        self.credentials = credentials
    }

    /// Opens the account's repository on first use.
    func start() throws -> CachedPhotosRepository {
        if let repository { return repository }
        let repository = try CachedPhotosRepository(credentials: credentials(), budget: preferences.budgetBytes)
        self.repository = repository
        return repository
    }
}
