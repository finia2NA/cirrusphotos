import Foundation

public enum SynologyAPIError: LocalizedError, Sendable {
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
        case .transport(let message): "Could not reach Cirrus: \(message)"
        case .invalidResponse: "Cirrus returned an unexpected response."
        case .http(let status): "Cirrus returned HTTP \(status)."
        case .api(let code):
            switch code {
            case 400: "The username or password was rejected."
            case 402: "The account is not permitted to use Synology Photos."
            case 403, 404: "Two-factor authentication was rejected. Check the NAS and Mac clocks."
            case 407: "The NAS temporarily blocked login attempts."
            case 119: "The Synology session expired."
            default: "Synology API error \(code)."
            }
        case .unsupported(let message): message
        case .responseTooLarge(let limit): "Cirrus returned more than the \(limit)-byte safety limit."
        }
    }
}
