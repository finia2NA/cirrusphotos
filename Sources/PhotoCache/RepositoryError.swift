import Foundation
import SynologyAPI

/// A failure the repository reports to the app. The case says what kind of
/// problem it is, so callers choose copy and retry behavior without parsing text.
public enum RepositoryError: LocalizedError, Sendable, Equatable {
    /// The NAS request failed: offline, signed out, rejected or malformed.
    case server(SynologyAPIError)
    /// Another change of the same kind is still running.
    case busy(String)
    /// The displayed content changed or could not be verified. Reloading may help.
    case stale(String)
    /// The action is not available for this content, space or account.
    case unavailable(String)
    /// The user's input is incomplete or invalid.
    case invalidInput(String)
    /// The NAS may or may not have applied a change.
    case unconfirmed(String)
    /// A broken internal invariant. Always logged.
    case unexpected(String)

    /// Normalizes any thrown error. Cancellation should be handled before calling this.
    public init(_ error: any Error) {
        switch error {
        case let error as RepositoryError: self = error
        case let error as SynologyAPIError: self = .server(error)
        case let error as MetadataAdmissionError:
            self = .stale(error.localizedDescription)
        case is CancellationError: self = .stale("The operation was cancelled.")
        case let error as URLError: self = .server(.transport(error.localizedDescription))
        default: self = .unexpected(error.localizedDescription)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .server(let error): error.localizedDescription
        case .busy(let message), .stale(let message), .unavailable(let message),
             .invalidInput(let message), .unconfirmed(let message), .unexpected(let message): message
        }
    }

    public var isUnexpected: Bool {
        switch self {
        case .server(let error): error.isUnexpected
        case .unconfirmed, .unexpected: true
        case .busy, .stale, .unavailable, .invalidInput: false
        }
    }

    private var caseName: String {
        switch self {
        case .server: "server"
        case .busy: "busy"
        case .stale: "stale"
        case .unavailable: "unavailable"
        case .invalidInput: "invalidInput"
        case .unconfirmed: "unconfirmed"
        case .unexpected: "unexpected"
        }
    }

    /// Records the failure in Console: unexpected failures as errors, the rest as info.
    /// Server text can contain request details, so it stays private in the log.
    @discardableResult
    public static func record(_ error: any Error, operation: String) -> RepositoryError {
        let normalized = RepositoryError(error)
        let kind = normalized.caseName
        let message = normalized.localizedDescription
        if normalized.isUnexpected {
            if case .server = normalized {
                SynologyDiagnostics.unexpected.error("\(operation, privacy: .public) failed kind=\(kind, privacy: .public) message=\(message, privacy: .private)")
            } else {
                SynologyDiagnostics.unexpected.error("\(operation, privacy: .public) failed kind=\(kind, privacy: .public) message=\(message, privacy: .public)")
            }
        } else {
            SynologyDiagnostics.failures.info("\(operation, privacy: .public) failed kind=\(kind, privacy: .public) message=\(message, privacy: .private)")
        }
        return normalized
    }
}
