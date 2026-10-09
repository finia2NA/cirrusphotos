import Foundation

actor VideoTransferGate {
    private let limit = 2
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            let continuation = waiters.remove(at: index).1
            continuation.resume(throwing: CancellationError())
            return
        }
        guard active > 0 else { return }
        if waiters.isEmpty {
            active -= 1
        } else {
            let continuation = waiters.removeFirst().1
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
