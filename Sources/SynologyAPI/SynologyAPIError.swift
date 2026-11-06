import Foundation

public enum SynologyAPIError: LocalizedError, Sendable, Equatable {
    case configuration(String)
    case transport(String)
    case invalidResponse
    case http(Int)
    case api(Int)
    case unsupported(String)
    case responseTooLarge(Int)
    /// DSM requires a six-digit code (login error 403 without a usable code or trusted device).
    case secondFactorRequired
    /// The server certificate failed validation; the fingerprint is the SHA-256 of the leaf
    /// certificate, so the user can decide whether to trust it.
    case untrustedCertificate(sha256: String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .transport(let message): "Could not reach the NAS: \(message)"
        case .invalidResponse: "The NAS returned an unexpected response."
        case .http(let status): "The NAS returned HTTP \(status)."
        case .api(let code):
            switch code {
            case 400: "The username or password was rejected."
            case 401: "This account is disabled."
            case 402: "The NAS denied this request (Synology API error 402)."
            case 403, 404: "The verification code was rejected. Check the code, or the NAS and Mac clocks."
            case 406: "The NAS requires two-factor authentication. Complete its setup in DSM before signing in."
            case 407: "The NAS temporarily blocked login attempts from this address."
            case 408, 409, 410: "The password has expired or must be changed. Change it in DSM, then sign in again."
            case 106, 107, 119: "The Synology session expired."
            default: "Synology API error \(code)."
            }
        case .unsupported(let message): message
        case .responseTooLarge(let limit): "The NAS returned more than the \(limit)-byte safety limit."
        case .secondFactorRequired: "Enter the 6-digit code from your authenticator app."
        case .untrustedCertificate: "The NAS certificate could not be verified."
        }
    }

    /// The case and code without server text, for copied error reports.
    public var diagnosticCode: String {
        switch self {
        case .configuration: "configuration"
        case .transport: "transport"
        case .invalidResponse: "invalidResponse"
        case .http(let status): "http(\(status))"
        case .api(let code): "api(\(code))"
        case .unsupported: "unsupported"
        case .responseTooLarge(let limit): "responseTooLarge(\(limit))"
        case .secondFactorRequired: "secondFactorRequired"
        case .untrustedCertificate: "untrustedCertificate"
        }
    }

    /// Whether this failure means the client and server disagree about the protocol,
    /// rather than an ordinary offline, authentication or permission condition.
    public var isUnexpected: Bool {
        switch self {
        case .configuration, .transport, .unsupported, .secondFactorRequired, .untrustedCertificate: false
        case .invalidResponse, .responseTooLarge: true
        case .http(let status): status >= 500 || status == 400
        case .api(let code): !(Self.sessionCodes + [105, 400, 401, 402, 403, 404, 406, 407, 408, 409, 410]).contains(code)
        }
    }

    /// Codes meaning the session is gone: timed out, replaced by another login, or unknown.
    public static let sessionCodes = [106, 107, 119]

    public var isSessionExpired: Bool {
        if case .api(let code) = self { return Self.sessionCodes.contains(code) }
        return false
    }
}
