import Foundation

public enum RequestPriority: Int, Sendable { case prefetch = 0, visible = 1 }

enum NetworkGateError: Error { case queueFull }

/// Cancellation-safe admission for metadata and image transfers.
actor NetworkGate {
    enum Kind { case metadata, thumbnail }
    private struct Waiter {
        let id: UUID
        let kind: Kind
        var priority: RequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }
    private let metadataLimit: Int
    private let thumbnailLimit: Int
    private let metadataQueueLimit: Int
    private let thumbnailQueueLimit: Int
    private var metadataActive = 0
    private var thumbnailActive = 0
    private var waiting: [Waiter] = []

    init(metadata: Int = 5, thumbnails: Int = 6,
         metadataQueue: Int = 64, thumbnailQueue: Int = 256) {
        metadataLimit = max(1, metadata)
        thumbnailLimit = max(1, thumbnails)
        metadataQueueLimit = max(0, metadataQueue)
        thumbnailQueueLimit = max(0, thumbnailQueue)
    }

    func acquire(_ kind: Kind, priority: RequestPriority, id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if capacity(for: kind) > 0 && !waiting.contains(where: { $0.kind == kind }) {
                    increment(kind)
                    continuation.resume()
                    return
                }
                let limit = kind == .metadata ? metadataQueueLimit : thumbnailQueueLimit
                let queuedCount = waiting.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
                if queuedCount >= limit {
                    if priority == .visible,
                       let victim = waiting.lastIndex(where: { $0.kind == kind && $0.priority == .prefetch }) {
                        waiting.remove(at: victim).continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: NetworkGateError.queueFull)
                        return
                    }
                }
                waiting.append(Waiter(id: id, kind: kind, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func promote(_ id: UUID) {
        guard let position = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[position].priority = .visible
    }

    func queuedCount(_ kind: Kind) -> Int {
        waiting.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    func release(_ kind: Kind) {
        switch kind {
        case .metadata: metadataActive -= 1
        case .thumbnail: thumbnailActive -= 1
        }
        drain(kind)
    }

    private func cancel(_ id: UUID) {
        guard let position = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: position).continuation.resume(throwing: CancellationError())
    }
    private func capacity(for kind: Kind) -> Int {
        kind == .metadata ? metadataLimit - metadataActive : thumbnailLimit - thumbnailActive
    }
    private func increment(_ kind: Kind) {
        switch kind {
        case .metadata: metadataActive += 1
        case .thumbnail: thumbnailActive += 1
        }
    }
    private func drain(_ kind: Kind) {
        while capacity(for: kind) > 0 {
            guard let position = waiting.indices
                .filter({ waiting[$0].kind == kind })
                .max(by: { waiting[$0].priority.rawValue < waiting[$1].priority.rawValue ||
                    (waiting[$0].priority == waiting[$1].priority && $0 > $1) }) else { break }
            let waiter = waiting.remove(at: position)
            increment(kind)
            waiter.continuation.resume()
        }
    }
}
