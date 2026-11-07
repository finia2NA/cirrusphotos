import Foundation
import Security
import SynologyAPI

/// An account signed in from the app. Secrets live in the Keychain, not here.
struct StoredAccount: Codable, Hashable, Identifiable, Sendable {
    let serverURL: URL
    let username: String
    /// SHA-256 of a NAS certificate the user chose to trust after system validation failed.
    var pinnedCertificate: String?

    var id: String { "\(username)@\(serverURL.absoluteString)" }
    var host: String { serverURL.host ?? serverURL.absoluteString }
    var displayName: String { "\(username) on \(host)" }
}

/// Secret storage keyed by account and item, so tests can avoid the Keychain.
protocol AccountSecrets: Sendable {
    func read(account: String, item: String) -> String?
    func write(_ value: String, account: String, item: String) throws
    func delete(account: String, item: String)
}

/// Generic-password items under one service. The account attribute is
/// `<account id>|<item>`, so each account has a password and an optional device token.
struct KeychainSecrets: AccountSecrets {
    let service: String

    init(service: String = AppIdentity.bundleIdentifier) { self.service = service }

    private func query(account: String, item: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(account)|\(item)"]
    }

    func read(account: String, item: String) -> String? {
        var query = query(account: account, item: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String, item: String) throws {
        let query = query(account: account, item: item)
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrLabel as String] = "Cirrus Photos (\(account))"
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SynologyAPIError.configuration("The Keychain refused to store the sign-in (status \(status)).")
        }
    }

    func delete(account: String, item: String) {
        SecItemDelete(query(account: account, item: item) as CFDictionary)
    }
}

/// The accounts signed in from the app and which one opens at launch.
/// The list is in user defaults; passwords and trusted-device tokens are in `AccountSecrets`.
@MainActor
final class AccountStore {
    /// Password and device token share one Keychain item, so opening an account reads
    /// the Keychain once and macOS asks for access at most once.
    private static let signInItem = "sign-in"
    private struct SignInSecret: Codable {
        let password: String
        let deviceToken: String?
    }
    static let accountsKey = "accounts.v1"
    static let currentKey = "accounts.current.v1"
    /// Server addresses that answered a sign-in, most recent first.
    static let recentServersKey = "accounts.recentServers.v1"
    static let recentServerLimit = 10
    /// Certificates trusted for `.env` hosts, by host. Fingerprints are not secret.
    static let environmentPinsKey = "accounts.environmentCertificates.v1"

    private let defaults: UserDefaults
    private let secrets: any AccountSecrets
    private(set) var accounts: [StoredAccount]

    init(defaults: UserDefaults = .standard, secrets: any AccountSecrets = KeychainSecrets()) {
        self.defaults = defaults
        self.secrets = secrets
        accounts = defaults.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([StoredAccount].self, from: $0) } ?? []
    }

    var currentAccount: StoredAccount? {
        let id = defaults.string(forKey: Self.currentKey)
        return accounts.first { $0.id == id }
    }

    func setCurrent(_ account: StoredAccount?) {
        defaults.set(account?.id, forKey: Self.currentKey)
    }

    /// Adds or replaces an account and its secrets. A nil token removes an older one.
    func save(_ account: StoredAccount, password: String, deviceToken: String?) throws {
        let secret = SignInSecret(password: password, deviceToken: deviceToken)
        let encoded = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
        try secrets.write(encoded, account: account.id, item: Self.signInItem)
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        persist()
    }

    /// Pins a certificate the user trusted for a stored account.
    func pin(_ fingerprint: String, for account: StoredAccount) -> StoredAccount {
        var pinned = account
        pinned.pinnedCertificate = fingerprint
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = pinned
            persist()
        }
        return pinned
    }

    /// Addresses to suggest in the sign-in form: recently answered servers, then the
    /// servers of stored accounts, without duplicates.
    var serverSuggestions: [String] {
        let recent = defaults.stringArray(forKey: Self.recentServersKey) ?? []
        var seen = Set<String>()
        return (recent + accounts.map(\.serverURL.absoluteString)).filter { seen.insert($0).inserted }
    }

    func rememberServer(_ url: URL) {
        let address = url.absoluteString
        var recent = defaults.stringArray(forKey: Self.recentServersKey) ?? []
        recent.removeAll { $0 == address }
        recent.insert(address, at: 0)
        defaults.set(Array(recent.prefix(Self.recentServerLimit)), forKey: Self.recentServersKey)
    }

    func environmentPin(host: String) -> String? {
        (defaults.dictionary(forKey: Self.environmentPinsKey) as? [String: String])?[host.lowercased()]
    }

    func setEnvironmentPin(_ fingerprint: String, host: String) {
        var pins = (defaults.dictionary(forKey: Self.environmentPinsKey) as? [String: String]) ?? [:]
        pins[host.lowercased()] = fingerprint
        defaults.set(pins, forKey: Self.environmentPinsKey)
    }

    func remove(_ account: StoredAccount) {
        secrets.delete(account: account.id, item: Self.signInItem)
        accounts.removeAll { $0.id == account.id }
        if defaults.string(forKey: Self.currentKey) == account.id { setCurrent(nil) }
        persist()
    }

    /// Credentials for opening the account's repository, or nil when its password is gone.
    func credentials(for account: StoredAccount) -> SynologyCredentials? {
        guard let stored = secrets.read(account: account.id, item: Self.signInItem),
              let secret = try? JSONDecoder().decode(SignInSecret.self, from: Data(stored.utf8)) else { return nil }
        return SynologyCredentials(
            username: account.username, password: secret.password,
            secondFactor: secret.deviceToken.map { .deviceToken($0) } ?? .none,
            serverURL: account.serverURL,
            serverTrust: account.pinnedCertificate.map { .pinned(sha256: $0) } ?? .system)
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
    }
}
