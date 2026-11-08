import Foundation
import SynologyAPI
import XCTest
@testable import PhotoCache

final class CacheInventoryTests: XCTestCase {
    func testScanReportsUsageByCategoryAndAccountLabel() async throws {
        let root = temporaryTestRoot("CacheInventory")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = CacheKey.namespace(server: URL(string: "https://nas.example.test")!, account: "alice")
        let directory = root.appendingPathComponent(namespace)
        let cache = try DiskCache(root: directory, budget: 100_000_000)
        try await cache.put("thumb", kind: .thumbnail, data: Data(count: 1_000), validatedRun: nil)
        try await cache.put("full", kind: .fullImage, data: Data(count: 4_000), validatedRun: nil)
        CacheInventory.writeLabel(root: directory, server: URL(string: "https://nas.example.test")!, username: "alice")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-cache"), withIntermediateDirectories: true)

        let accounts = CacheInventory.scan(root: root)
        XCTAssertEqual(accounts.count, 1)
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.namespace, namespace)
        XCTAssertEqual(account.username, "alice")
        XCTAssertEqual(account.server, "nas.example.test")
        XCTAssertGreaterThan(account.usage.bytes[.thumbnails] ?? 0, 0)
        XCTAssertGreaterThan(account.usage.bytes[.fullImages] ?? 0, account.usage.bytes[.thumbnails] ?? 0)
        let total = try await cache.usage()
        XCTAssertEqual(account.usage.total, total)

        try CacheInventory.remove(namespace: namespace, root: root)
        XCTAssertTrue(CacheInventory.scan(root: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("not-a-cache").path))
        try CacheInventory.remove(namespace: "..", root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRemoveAllExceptKeepsOnlyListedNamespaces() throws {
        let root = temporaryTestRoot("CacheInventoryPrune")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["kept", "orphan", "other"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let removed = CacheInventory.removeAll(except: ["kept"], root: root)
        XCTAssertEqual(Set(removed), ["orphan", "other"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("kept").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan").path))
    }
}
