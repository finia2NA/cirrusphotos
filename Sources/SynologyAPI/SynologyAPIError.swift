import Foundation

public enum SynologyAPIError: LocalizedError, Sendable, Equatable {
    case configuration(String)
    case transport(String)
    case invalidResponse
    case http(Int)
    case api(Int)
    case unsupported(String)
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .transport(let message): "Could not reach the NAS: \(message)"
        case .invalidResponse: "The NAS returned an unexpected response."
        case .http(let status): "The NAS returned HTTP \(status)."
        case .api(let code):
            switch code {
            case 400: "The username or password was rejected."
            case 402: "The NAS denied this request (Synology API error 402)."
            case 403, 404: "Two-factor authentication was rejected. Check the NAS and Mac clocks."
            case 406: "The NAS requires two-factor authentication. Complete its setup in DSM before signing in."
            case 407: "The NAS temporarily blocked login attempts."
            case 119: "The Synology session expired."
            default: "Synology API error \(code)."
            }
        case .unsupported(let message): message
        case .responseTooLarge(let limit): "The NAS returned more than the \(limit)-byte safety limit."
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
        }
    }

    /// Whether this failure means the client and server disagree about the protocol,
    /// rather than an ordinary offline, authentication or permission condition.
    public var isUnexpected: Bool {
        switch self {
        case .configuration, .transport, .unsupported: false
        case .invalidResponse, .responseTooLarge: true
        case .http(let status): status >= 500 || status == 400
        case .api(let code): ![105, 119, 400, 402, 403, 404, 406, 407].contains(code)
        }
    }
}
