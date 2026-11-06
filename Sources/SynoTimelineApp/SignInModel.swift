import Foundation
import Observation
import SynologyAPI

/// A verified sign-in, ready to be stored and opened.
struct SignedInAccount: Sendable {
    let account: StoredAccount
    let password: String
    let deviceToken: String?
}

/// Drives the sign-in window: address, username and password; then a six-digit code
/// when DSM asks for one; or a certificate decision when the NAS certificate fails
/// validation. The login is verified with a short-lived client and logged out again;
/// the account's repository signs in itself with the stored password and device token.
@MainActor
@Observable
final class SignInModel {
    enum Step: Equatable {
        case credentials
        case code
        /// The SHA-256 of the certificate the NAS presented.
        case certificate(String)
    }

    typealias Authenticate = @Sendable (SynologyCredentials) async throws -> SignInResult

    var server = ""
    var username = ""
    var password = ""
    var code = ""
    private(set) var step: Step = .credentials
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// The address of the last attempt the server answered, worth suggesting again.
    private(set) var answeringServer: URL?
    private var pinnedCertificate: String?
    private let authenticate: Authenticate

    init(server: String = "", username: String = "", authenticate: @escaping Authenticate = SignInModel.liveAuthenticate) {
        self.server = server
        self.username = username
        self.authenticate = authenticate
    }

    static let liveAuthenticate: Authenticate = { credentials in
        let client = try SynologyClient(credentials: credentials)
        let result = try await client.signIn(credentials)
        await client.logout()
        return result
    }

    var serverURL: URL? { ServerAddress.url(from: server) }

    var canSubmit: Bool {
        guard !isWorking else { return false }
        switch step {
        case .credentials: return serverURL != nil && !username.isEmpty && !password.isEmpty
        case .code: return Self.isCode(code)
        case .certificate: return true
        }
    }

    static func isCode(_ value: String) -> Bool { value.count == 6 && value.allSatisfy(\.isASCIIDigit) }

    /// Keeps only digits, at most six, so pasted codes with spaces still work.
    func setCode(_ value: String) {
        code = String(value.filter(\.isASCIIDigit).prefix(6))
    }

    /// Returns the account when the NAS accepted the sign-in; otherwise moves to the
    /// step DSM asked for or reports why it failed.
    func submit() async -> SignedInAccount? {
        guard canSubmit, let url = serverURL else { return nil }
        if case .certificate(let fingerprint) = step { pinnedCertificate = fingerprint }
        let secondFactor: SecondFactor = step == .code ? .code(code) : .none
        let trust: ServerTrust = pinnedCertificate.map { .pinned(sha256: $0) } ?? .system
        let credentials = SynologyCredentials(username: username, password: password, secondFactor: secondFactor,
                                              serverURL: url, serverTrust: trust)
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await authenticate(credentials)
            answeringServer = url
            let account = StoredAccount(serverURL: url, username: username, pinnedCertificate: pinnedCertificate)
            // Only a login that proved a code earns a token worth keeping.
            let token = secondFactor == .none ? nil : result.deviceToken
            return SignedInAccount(account: account, password: password, deviceToken: token)
        } catch SynologyAPIError.secondFactorRequired {
            answeringServer = url
            step = .code
            code = ""
        } catch SynologyAPIError.untrustedCertificate(let fingerprint) {
            step = .certificate(fingerprint)
        } catch SynologyAPIError.api(let status) where status == 404 || status == 403 {
            answeringServer = url
            code = ""
            errorMessage = "That code didn’t work. Wait for the next one and try again."
        } catch let error as SynologyAPIError {
            if case .api = error { answeringServer = url }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        return nil
    }

    /// Returns to the address and password, keeping what was typed.
    func back() {
        step = .credentials
        code = ""
        errorMessage = nil
        pinnedCertificate = nil
    }

    /// Groups a fingerprint as `ab:cd:…` for comparison with DSM's certificate details.
    static func formatted(fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 2).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            return String(fingerprint[start..<fingerprint.index(start, offsetBy: min(2, fingerprint.count - offset))])
        }.joined(separator: ":").uppercased()
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
