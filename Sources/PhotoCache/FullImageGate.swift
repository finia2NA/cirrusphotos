import Foundation

/// Gives original-image transfers two total slots while allowing only one speculative transfer.
/// The reserved slot lets a current image start without waiting for adjacent prefetches.
actor FullImageGate {
    private struct Waiter {
        let id: UUID
        var priority: RequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private let totalLimit: Int
    private let speculativeLimit: Int
    private let queueLimit: Int
    private var active: [UUID: RequestPriority] = [:]
    private var waiting: [Waiter] = []
    private var pendingPromotions: [UUID] = []

    init(total: Int = 2, speculative: Int = 1, queue: Int = 16) {
        totalLimit = max(1, total)
        speculativeLimit = min(max(0, speculative), totalLimit)
        queueLimit = max(0, queue)
    }

    func acquire(priority: RequestPriority, id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let wasPromoted = pendingPromotions.contains(id)
                pendingPromotions.removeAll(where: { $0 == id })
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let effectivePriority: RequestPriority = wasPromoted ? .visible : priority
                if canStart(effectivePriority), !hasHigherPriorityWaiter(than: effectivePriority) {
                    active[id] = effectivePriority
                    continuation.resume()
                    return
                }
                if waiting.count >= queueLimit {
                    if effectivePriority == .visible,
                       let victim = waiting.lastIndex(where: { $0.priority == .prefetch }) {
                        waiting.remove(at: victim).continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: NetworkGateError.queueFull)
                        return
                    }
                }
                waiting.append(Waiter(id: id, priority: effectivePriority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func promote(_ id: UUID) {
        if active[id] != nil {
            active[id] = .visible
            drain()
            return
        }
        if let position = waiting.firstIndex(where: { $0.id == id }) {
            waiting[position].priority = .visible
            drain()
        } else {
            rememberPromotion(id)
        }
    }

    private func rememberPromotion(_ id: UUID) {
        guard !pendingPromotions.contains(id) else { return }
        pendingPromotions.append(id)
        let limit = totalLimit + queueLimit
        if pendingPromotions.count > limit { pendingPromotions.removeFirst() }
    }

    func release(_ id: UUID) {
        pendingPromotions.removeAll(where: { $0 == id })
        if active.removeValue(forKey: id) != nil { drain() }
    }

    func activePriority(_ id: UUID) -> RequestPriority? { active[id] }
    func pendingPromotionCount() -> Int { pendingPromotions.count }

    private func cancel(_ id: UUID) {
        pendingPromotions.removeAll(where: { $0 == id })
        guard let position = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: position).continuation.resume(throwing: CancellationError())
    }

    private func canStart(_ priority: RequestPriority) -> Bool {
        guard active.count < totalLimit else { return false }
        if priority == .visible { return true }
        return active.values.reduce(0) { $0 + ($1 == .prefetch ? 1 : 0) } < speculativeLimit
    }

    private func hasHigherPriorityWaiter(than priority: RequestPriority) -> Bool {
        priority == .prefetch && waiting.contains(where: { $0.priority == .visible })
    }

    private func drain() {
        while active.count < totalLimit {
            let candidates = waiting.indices.filter { canStart(waiting[$0].priority) }
            guard let position = candidates.max(by: {
                waiting[$0].priority.rawValue < waiting[$1].priority.rawValue ||
                    (waiting[$0].priority == waiting[$1].priority && $0 > $1)
            }) else { return }
            let waiter = waiting.remove(at: position)
            active[waiter.id] = waiter.priority
            waiter.continuation.resume()
        }
    }
}
