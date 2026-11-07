import Foundation
import Observation
import PhotoCache
import SynologyAPI

/// Everything that belongs to one signed-in account. Switching accounts replaces the
/// whole context, so no view or model keeps the previous account's state.
@MainActor
final class AccountContext: Identifiable {
    let id = UUID()
    /// Nil for `.env` credentials, which are not stored in the app.
    let account: StoredAccount?
    let title: String
    let model: LibraryModel
    let navigation = NavigationModel()
    let albumPresentation = AlbumPresentationStore()
    let infoPanel = InfoPanelModel()
    let libraryFilter = LibraryFilterModel()
    let timelineSectionLoad = TimelineSectionLoadModel()
    let metadataSync = MetadataSyncModel()
    let thumbnailPreload = ThumbnailPreloadModel()
    /// The NAS host, for certificate prompts.
    let host: String

    init(account: StoredAccount?, title: String, host: String, session: AppSession) {
        self.account = account
        self.title = title
        self.host = host
        model = LibraryModel(session: session)
        let signposts = ModelChangeSignposts.shared
        signposts.observe(albumPresentation, name: "AlbumPresentationStore")
        signposts.observe(navigation, name: "NavigationModel")
        signposts.observe(infoPanel, name: "InfoPanelModel")
        signposts.observe(libraryFilter, name: "LibraryFilterModel")
        signposts.observe(timelineSectionLoad, name: "TimelineSectionLoadModel")
        signposts.observe(metadataSync, name: "MetadataSyncModel")
    }

    /// Stops the account's work and ends its DSM session.
    func end() async {
        let repository = model.repository
        metadataSync.end()
        thumbnailPreload.suspend()
        timelineSectionLoad.cancel()
        libraryFilter.clear()
        infoPanel.clearBrowserContext()
        model.end()
        await repository?.shutdown()
    }
}

/// A certificate decision for the open account.
struct CertificatePrompt: Identifiable, Equatable {
    let id = UUID()
    let contextID: UUID
    let host: String
    let fingerprint: String
}

/// Owns the active account. A `.env` file beside the project wins, which keeps
/// development and `make switch-user` working; otherwise accounts come from the
/// sign-in window and are kept in `AccountStore`.
@MainActor
@Observable
final class AccountController {
    enum Phase: Equatable {
        /// No account is open; the window shows sign-in.
        case signedOut
        case open
        /// Opening or closing an account.
        case switching
    }

    let preferences: AppPreferences
    @ObservationIgnored let store: AccountStore
    private(set) var context: AccountContext?
    private(set) var phase: Phase = .signedOut
    /// A message for the sign-in window, such as why the previous account was closed.
    private(set) var notice: String?
    /// The account whose stored sign-in the NAS rejected; the sign-in window offers it.
    private(set) var reauthenticating: StoredAccount?
    /// After a new sign-in the sign-in window continues with setup before the library shows.
    enum SetupStep: Equatable {
        /// Thumbnail quality and cache size.
        case preferences
        /// What to download ahead for offline use.
        case download
    }

    /// The setup page shown after a new sign-in; nil once the library is shown.
    var setupStep: SetupStep?
    /// The open account's NAS presented a certificate macOS cannot verify.
    var certificatePrompt: CertificatePrompt?
    let usesEnvironmentFile: Bool
    @ObservationIgnored private let makeRepository: @MainActor (SynologyCredentials, AppPreferences) throws -> CachedPhotosRepository
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(preferences: AppPreferences, store: AccountStore = AccountStore(),
         environmentFile: URL? = CredentialStore.environmentFile(),
         makeRepository: @escaping @MainActor (SynologyCredentials, AppPreferences) throws -> CachedPhotosRepository = AccountController.liveRepository) {
        self.preferences = preferences
        self.store = store
        self.usesEnvironmentFile = environmentFile != nil
        self.makeRepository = makeRepository
    }

    static func liveRepository(_ credentials: SynologyCredentials, _ preferences: AppPreferences) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: credentials, budget: preferences.budgetBytes)
    }

    var accounts: [StoredAccount] { usesEnvironmentFile ? [] : store.accounts }

    /// Opens the `.env` account or the last used stored account.
    func start() {
        guard context == nil, phase != .switching else { return }
        if usesEnvironmentFile {
            open(account: nil, title: "Development account (.env)") { [store] in
                let loaded = try CredentialStore.load()
                guard let host = loaded.serverURL?.host, let pin = store.environmentPin(host: host) else { return loaded }
                return SynologyCredentials(username: loaded.username, password: loaded.password,
                                           secondFactor: loaded.secondFactor, serverURL: loaded.serverURL,
                                           serverTrust: .pinned(sha256: pin))
            }
        } else if let account = store.currentAccount {
            openStored(account)
        }
    }

    /// Stores a verified sign-in and opens it, replacing any open account.
    func completeSignIn(_ signedIn: SignedInAccount) async {
        do {
            try store.save(signedIn.account, password: signedIn.password, deviceToken: signedIn.deviceToken)
        } catch {
            notice = error.localizedDescription
            return
        }
        await close()
        reauthenticating = nil
        setupStep = .preferences
        openStored(signedIn.account)
    }

    func switchTo(_ account: StoredAccount) async {
        guard account.id != context?.account?.id else { return }
        await close()
        openStored(account)
    }

    /// Closes the account and forgets its stored sign-in.
    /// Signs out of a stored account: forgets its password and trusted device and deletes
    /// its cache. An open account is closed first, then another saved account opens, or
    /// the sign-in window when none is left.
    func signOut(_ account: StoredAccount) async {
        let wasOpen = context?.account?.id == account.id
        if wasOpen { await close() }
        store.remove(account)
        UserDefaults.standard.removeObject(forKey: ThumbnailPreloadModel.requestKey(namespace: Self.namespace(of: account)))
        try? CacheInventory.remove(namespace: Self.namespace(of: account))
        notice = nil
        if wasOpen, let next = store.accounts.first { openStored(next) }
    }

    static func namespace(of account: StoredAccount) -> String {
        CacheKey.namespace(server: account.serverURL, account: account.username)
    }

    private func openStored(_ account: StoredAccount) {
        store.setCurrent(account)
        open(account: account, title: account.displayName) { [store] in
            guard let credentials = store.credentials(for: account) else {
                throw SynologyAPIError.configuration("The saved sign-in for \(account.displayName) is missing. Sign in again.")
            }
            return credentials
        }
    }

    private func open(account: StoredAccount?, title: String, host: String? = nil,
                      credentials: @escaping @MainActor () throws -> SynologyCredentials) {
        let preferences = preferences
        let makeRepository = makeRepository
        let session = AppSession(preferences: preferences) { preferences in
            try makeRepository(try credentials(), preferences)
        }
        let host = host ?? account?.host ?? (try? CredentialStore.load())?.serverURL?.host ?? "the NAS"
        let context = AccountContext(account: account, title: title, host: host, session: session)
        self.context = context
        phase = .open
        notice = nil
        watchAuthentication(context)
    }

    private func close() async {
        certificatePrompt = nil
        setupStep = nil
        statusTask?.cancel()
        statusTask = nil
        guard let context else { phase = .signedOut; return }
        phase = .switching
        self.context = nil
        await context.end()
        DecodedImages.shared.clear()
        phase = .signedOut
    }

    /// Trusts the certificate the open account's NAS presented and reconnects with it pinned.
    func trustPresentedCertificate() async {
        guard let prompt = certificatePrompt, let context, context.id == prompt.contextID else { return }
        certificatePrompt = nil
        let account = context.account
        await close()
        if let account {
            openStored(store.pin(prompt.fingerprint, for: account))
        } else {
            store.setEnvironmentPin(prompt.fingerprint, host: prompt.host)
            start()
        }
    }

    /// Asks about an untrusted certificate for any account. When the NAS rejects a stored
    /// account's sign-in, close it and ask again; `.env` accounts keep their status display,
    /// since their fix is editing `.env`.
    private func watchAuthentication(_ context: AccountContext) {
        let account = context.account
        let host = context.host
        let contextID = context.id
        statusTask = Task { [weak self, weak model = context.model] in
            while !Task.isCancelled {
                guard let model else { return }
                let status = await withCheckedContinuation { continuation in
                    withObservationTracking { _ = model.authenticationStatus } onChange: {
                        Task { @MainActor in continuation.resume(returning: model.authenticationStatus) }
                    }
                }
                guard !Task.isCancelled else { return }
                switch status {
                case .untrustedCertificate(let fingerprint):
                    self?.certificatePrompt = CertificatePrompt(contextID: contextID, host: host, fingerprint: fingerprint)
                case .needsSignIn(let message):
                    if let account { await self?.requireSignIn(account, message: message); return }
                default:
                    break
                }
            }
        }
    }

    private func requireSignIn(_ account: StoredAccount, message: String) async {
        guard context?.account?.id == account.id else { return }
        await close()
        reauthenticating = account
        notice = message
    }
}
