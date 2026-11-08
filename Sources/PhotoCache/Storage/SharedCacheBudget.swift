import Foundation

/// One maximum cache size shared by every account on this Mac. Only the open account has
/// a live cache; it may use what the closed accounts leave of the maximum when it loads.
/// Its own data counts toward that share, and when closed accounts leave less than the open
/// account already holds, the least recently opened closed accounts are trimmed.
public enum SharedCacheBudget {
    public struct Plan: Sendable, Equatable {
        /// The open account's budget.
        public var openAllowance: Int64
        /// Closed accounts to shrink, with their new size; zero deletes the cache.
        public var trims: [Trim]
    }

    public struct Trim: Sendable, Equatable {
        public let account: CachedAccount
        public let bytes: Int64
    }

    public static func plan(budget: Int64, openNamespace: String, accounts: [CachedAccount]) -> Plan {
        let budget = max(0, budget)
        let openUsage = accounts.first { $0.namespace == openNamespace }?.usage.total ?? 0
        let closed = accounts.filter { $0.namespace != openNamespace }
        var others = closed.reduce(Int64(0)) { $0 + $1.usage.total }
        var excess = others - (budget - min(openUsage, budget))
        var trims: [Trim] = []
        for account in closed.sorted(by: { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }) where excess > 0 {
            let usage = account.usage.total
            guard usage > 0 else { continue }
            let removed = min(usage, excess)
            trims.append(Trim(account: account, bytes: usage - removed))
            others -= removed
            excess -= removed
        }
        return Plan(openAllowance: max(0, budget - others), trims: trims)
    }

    /// Scans the cache root, trims closed accounts as planned and returns the plan. A failed
    /// trim is skipped; the open account's allowance then assumes that account kept its size.
    public static func apply(budget: Int64, openNamespace: String, root: URL) async -> Plan {
        var plan = plan(budget: budget, openNamespace: openNamespace, accounts: CacheInventory.scan(root: root))
        var applied: [Trim] = []
        for trim in plan.trims {
            do {
                try await CacheInventory.trim(namespace: trim.account.namespace, to: trim.bytes, root: root)
                applied.append(trim)
            } catch {
                plan.openAllowance = max(0, plan.openAllowance - (trim.account.usage.total - trim.bytes))
            }
        }
        plan.trims = applied
        return plan
    }
}
