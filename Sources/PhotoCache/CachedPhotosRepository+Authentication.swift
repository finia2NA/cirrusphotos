import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Each observer receives the latest status immediately, including a previous failure.
    public func authentication() -> AsyncStream<AuthenticationStatus> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            authenticationState.observers[id] = continuation
            continuation.yield(authenticationState.status)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeAuthenticationObserver(id) }
            }
        }
    }

    /// A rejected sign-in is sticky until the user explicitly retries it. Failing to reach
    /// the NAS is not: the next request starts a new attempt.
    public func retryAuthentication() {
        switch authenticationState.status {
        case .failed, .unreachable, .needsSignIn, .untrustedCertificate: authenticationState.resetAttempt()
        case .notStarted, .loggingIn, .signedIn: break
        }
    }

    private func removeAuthenticationObserver(_ id: UUID) {
        authenticationState.observers.removeValue(forKey: id)
    }

    func connect() async throws {
        try Task.checkCancellation()
        if authenticationState.shutDown { throw CancellationError() }
        if authenticationState.connected { return }
        switch authenticationState.status {
        case .failed(let message), .needsSignIn(let message):
            throw AuthenticationAttemptError.previousFailure(message)
        case .untrustedCertificate(let fingerprint):
            throw SynologyAPIError.untrustedCertificate(sha256: fingerprint)
        case .notStarted, .loggingIn, .signedIn, .unreachable:
            break
        }
        if !authenticationState.renewalHandlerInstalled {
            authenticationState.renewalHandlerInstalled = true
            await client.onSessionRenewalFailure { [weak self] error in
                Task { await self?.sessionRenewalFailed(error) }
            }
        }
        if authenticationState.task == nil {
            authenticationState.setStatus(.loggingIn)
            authenticationState.attempt = UUID()
            authenticationState.task = Task { try await client.login(credentials: credentials) }
        }
        guard let loginTask = authenticationState.task,
              let attempt = authenticationState.attempt else { throw CancellationError() }
        do {
            try await loginTask.value
            try Task.checkCancellation()
            guard authenticationState.attempt == attempt else { throw CancellationError() }
            authenticationState.connected = true
            authenticationState.setStatus(.signedIn)
        } catch {
            if !Task.isCancelled && !(error is CancellationError) &&
                authenticationState.attempt == attempt && !authenticationState.connected {
                authenticationState.task = nil
                authenticationState.attempt = nil
                authenticationState.setStatus(Self.status(after: error))
            }
            throw error
        }
    }
}

extension CachedPhotosRepository {
    /// Stops all work for sign-out or an account switch: no NAS request or cache write
    /// is admitted afterwards, running jobs are cancelled and the DSM session is ended.
    /// Observers finish. Idempotent; a new repository serves the next account.
    public func shutdown() async {
        guard !authenticationState.shutDown else { return }
        authenticationState.shutDown = true
        authenticationState.task?.cancel()
        authenticationState.task = nil
        authenticationState.attempt = nil
        authenticationState.connected = false
        for observer in authenticationState.observers.values { observer.finish() }
        authenticationState.observers.removeAll()
        await stopAllWork()
        await client.logout()
    }

    /// DSM refused to renew an expired session (for example a changed password or a
    /// removed trusted device). Later requests stop until the user signs in again.
    func sessionRenewalFailed(_ error: SynologyAPIError) {
        guard !authenticationState.shutDown else { return }
        authenticationState.connected = false
        authenticationState.task = nil
        authenticationState.attempt = nil
        authenticationState.setStatus(Self.status(after: error))
    }

    static func status(after error: Error) -> AuthenticationStatus {
        guard let error = error as? SynologyAPIError else { return .failed(error.localizedDescription) }
        switch error {
        case .transport:
            return .unreachable(error.localizedDescription)
        case .untrustedCertificate(let fingerprint):
            return .untrustedCertificate(sha256: fingerprint)
        case .secondFactorRequired:
            return .needsSignIn(error.localizedDescription)
        case .api(let code) where [400, 401, 403, 404, 408, 409, 410].contains(code):
            return .needsSignIn(error.localizedDescription)
        default:
            return .failed(error.localizedDescription)
        }
    }
}

private enum AuthenticationAttemptError: LocalizedError {
    case previousFailure(String)
    var errorDescription: String? {
        if case .previousFailure(let message) = self { return message }
        return nil
    }
}
