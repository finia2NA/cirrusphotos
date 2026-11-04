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
        case .failed, .unreachable: authenticationState.resetAttempt()
        case .notStarted, .loggingIn, .signedIn: break
        }
    }

    private func removeAuthenticationObserver(_ id: UUID) {
        authenticationState.observers.removeValue(forKey: id)
    }

    func connect() async throws {
        try Task.checkCancellation()
        if authenticationState.connected { return }
        if case .failed(let message) = authenticationState.status {
            throw AuthenticationAttemptError.previousFailure(message)
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
                if case SynologyAPIError.transport = error {
                    authenticationState.setStatus(.unreachable(error.localizedDescription))
                } else {
                    authenticationState.setStatus(.failed(error.localizedDescription))
                }
            }
            throw error
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
