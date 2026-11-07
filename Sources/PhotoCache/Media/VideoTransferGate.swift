import Foundation

actor VideoTransferGate {
    private let limit = 2
    private var active: Set<UUID> = []
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < limit { active.insert(id); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
    }

    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiters.isEmpty {
            let (next, continuation) = waiters.removeFirst()
            active.insert(next)
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        } else { release(id) }
    }
}
