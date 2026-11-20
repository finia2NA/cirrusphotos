import Foundation

/// Order and retry bookkeeping for the downloads. Pure logic; the caller does the waiting.
///
/// An item that fails `attemptsPerRound` times in a row moves to the end of the queue so the
/// others can continue. After `maximumRounds` such rounds it is given up and reported.
/// Failures during a network outage are not recorded here at all; the caller waits instead.
struct RetryQueue<Item> {
    struct Entry {
        let item: Item
        var failures = 0
        var rounds = 0
        var lastError = ""
    }

    enum Decision: Equatable {
        /// Retry the same item after the delay.
        case retry(after: TimeInterval)
        /// The item moved to the end of the queue; wait this long before the next item.
        case deferred(pause: TimeInterval)
        /// The item will not be retried in this run.
        case gaveUp
    }

    static var attemptsPerRound: Int { 10 }
    static var maximumRounds: Int { 3 }
    /// Pause before retrying a deferred item that is the only one left.
    static var lonePause: TimeInterval { 120 }

    private(set) var pending: [Entry]
    private(set) var givenUp: [Entry] = []

    init(_ items: [Item]) {
        pending = items.map { Entry(item: $0) }
    }

    var current: Entry? { pending.first }

    mutating func succeeded() {
        pending.removeFirst()
    }

    mutating func failed(reason: String) -> Decision {
        var entry = pending.removeFirst()
        entry.failures += 1
        entry.lastError = reason
        if entry.failures < Self.attemptsPerRound {
            pending.insert(entry, at: 0)
            return .retry(after: Self.backoff(afterFailures: entry.failures))
        }
        entry.failures = 0
        entry.rounds += 1
        if entry.rounds >= Self.maximumRounds {
            givenUp.append(entry)
            return .gaveUp
        }
        pending.append(entry)
        return .deferred(pause: pending.count == 1 ? Self.lonePause : 0)
    }

    /// 2, 4, 8, 16, 32, then 60 seconds.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        min(60, 2 * pow(2, Double(max(0, failures - 1))))
    }
}
