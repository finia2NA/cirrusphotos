import CryptoKit
import Foundation
import os
import Security

/// Applies a `ServerTrust` policy to the NAS host. Other hosts get default handling.
/// A rejected certificate's fingerprint is kept so the failed request can report it.
final class CirrusTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowedHost: String
    private let trust: ServerTrust
    private let rejected = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(allowedHost: String, trust: ServerTrust) {
        self.allowedHost = allowedHost.lowercased()
        self.trust = trust
    }

    /// The SHA-256 of the last certificate this delegate refused, cleared when read.
    func takeRejectedFingerprint() -> String? {
        rejected.withLock { value in
            defer { value = nil }
            return value
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == allowedHost,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch Self.decision(trust, serverTrust: serverTrust) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .reject(let fingerprint):
            rejected.withLock { $0 = fingerprint }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    enum Decision: Equatable { case accept, reject(String?) }

    static func decision(_ policy: ServerTrust, serverTrust: SecTrust) -> Decision {
        if SecTrustEvaluateWithError(serverTrust, nil) { return .accept }
        let fingerprint = leafFingerprint(serverTrust)
        if case .pinned(let expected) = policy, let fingerprint, fingerprint == expected.lowercased() {
            return .accept
        }
        return .reject(fingerprint)
    }

    static func leafFingerprint(_ serverTrust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return fingerprint(SecCertificateCopyData(leaf) as Data)
    }

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
