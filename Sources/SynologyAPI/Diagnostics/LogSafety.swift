import Foundation

/// Redaction for text that reaches logs or copied reports. Session IDs and tokens travel as URL
/// query items, so any message that quotes a request URL can carry them.
public enum LogRedaction {
    /// Removes session, token and credential values and whole URLs.
    public static func scrub(_ text: String) -> String {
        text.replacing(/(?i)(_sid|synotoken|passwd|password|otp_code|device_id|did|account)=[^&\s"]*/) { match in
            "\(match.output.1)=<removed>"
        }
        .replacing(/(?i)\bhttps?:\/\/[^\s"')>]+/) { _ in "<url>" }
    }
}

/// An error that knows how to describe itself without server text or request details.
public protocol LogSummaryProviding: Error {
    var safeLogSummary: String { get }
}

extension Error {
    /// A one-line description that is safe for `privacy: .public`: error type, domain and code,
    /// plus a scrubbed message. Never reads `userInfo` (failing URLs live there), and server
    /// text carried by `SynologyAPIError` is replaced by its case and code.
    public var logSummary: String {
        switch self {
        case let error as any LogSummaryProviding:
            return error.safeLogSummary
        case let error as SynologyAPIError:
            return "SynologyAPIError.\(error.diagnosticCode)"
        case let error as DecodingError:
            return "DecodingError \(LogRedaction.scrub(String(describing: error)))"
        default:
            let nsError = self as NSError
            let type = String(describing: Swift.type(of: self))
            return "\(type) \(nsError.domain)(\(nsError.code)): \(LogRedaction.scrub(localizedDescription))"
        }
    }
}
