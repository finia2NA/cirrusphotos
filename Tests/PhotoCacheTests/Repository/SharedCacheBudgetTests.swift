import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

final class SharedCacheBudgetTests: XCTestCase {
    private func account(_ name: String, _ bytes: Int64, opened: TimeInterval) -> CachedAccount {
        CachedAccount(namespace: name, server: "nas", username: name,
                      usage: CacheUsageBreakdown(bytes: [.thumbnails: bytes]), lastOpened: Date(timeIntervalSince1970: opened))
    }

    func testOpenAccountGetsWhatOtherAccountsLeave() {
        let plan = SharedCacheBudget.plan(budget: 1_000, openNamespace: "open",
                                          accounts: [account("open", 100, opened: 3), account("a", 300, opened: 1)])
        XCTAssertEqual(plan.openAllowance, 700)
        XCTAssertTrue(plan.trims.isEmpty)
    }

    func testLeastRecentlyOpenedClosedAccountsMakeRoomForOpenAccountData() {
        let plan = SharedCacheBudget.plan(budget: 1_000, openNamespace: "open", accounts: [
            account("open", 500, opened: 3), account("older", 300, opened: 1), account("newer", 400, opened: 2),
        ])
        XCTAssertEqual(plan.trims, [SharedCacheBudget.Trim(account: account("older", 300, opened: 1), bytes: 100)])
        XCTAssertEqual(plan.openAllowance, 500)
    }

    func testClosedAccountsTrimmedToNothingAndOpenAccountCappedAtMaximum() {
        let plan = SharedCacheBudget.plan(budget: 1_000, openNamespace: "open", accounts: [
            account("open", 1_500, opened: 3), account("older", 300, opened: 1), account("newer", 400, opened: 2),
        ])
        XCTAssertEqual(plan.trims.map(\.bytes), [0, 0])
        XCTAssertEqual(plan.trims.map(\.account.namespace), ["older", "newer"])
        XCTAssertEqual(plan.openAllowance, 1_000)
    }

    func testLoweringTheMaximumTrimsClosedAccountsFirst() {
        let accounts = [account("open", 400, opened: 3), account("a", 400, opened: 1)]
        let plan = SharedCacheBudget.plan(budget: 600, openNamespace: "open", accounts: accounts)
        XCTAssertEqual(plan.trims.map(\.bytes), [200])
        XCTAssertEqual(plan.openAllowance, 400)
    }

    func testApplyShrinksAndRemovesClosedCaches() async throws {
        let root = temporaryTestRoot("SharedCacheBudget")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, opened) in [("older", 1.0), ("newer", 2.0)] {
            let directory = root.appendingPathComponent(name)
            let cache = try DiskCache(root: directory, budget: 100_000_000)
            for index in 0..<10 {
                try await cache.put("\(name)-\(index)", kind: .fullImage, data: Data(count: 10_000), validatedRun: nil)
            }
            CacheInventory.writeLabel(root: directory, server: URL(string: "https://nas.example.test")!, username: name)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: opened)],
                                                  ofItemAtPath: directory.appendingPathComponent(CacheInventory.labelFile).path)
        }
        let scanned = CacheInventory.scan(root: root)
        XCTAssertEqual(scanned.first { $0.namespace == "older" }?.lastOpened, Date(timeIntervalSince1970: 1))

        let plan = await SharedCacheBudget.apply(budget: 100_000, openNamespace: "open", root: root)
        let after = CacheInventory.scan(root: root)
        XCTAssertEqual(plan.trims.first?.account.namespace, "older")
        XCTAssertEqual(plan.trims.first?.bytes, 0)
        XCTAssertFalse(after.contains { $0.namespace == "older" })
        XCTAssertLessThanOrEqual(after.reduce(0) { $0 + $1.usage.total } + plan.openAllowance, 100_000)

        let lowered = await SharedCacheBudget.apply(budget: 50_000, openNamespace: "open", root: root)
        XCTAssertEqual(lowered.trims.map(\.account.namespace), ["newer"])
        XCTAssertLessThanOrEqual(CacheInventory.scan(root: root).first?.usage.total ?? 0, 50_000)
    }
}
