import CryptoKit
import Foundation
import GRDB
import SynologyAPI

public enum CacheKind: Int, Sendable {
    case previewThumbnail = 0, fullImage = 1, thumbnail = 2, videoSegment = 7
}

public struct CacheEntry: Sendable {
    public let data: Data
    public let kind: CacheKind
    public let etag: String?
    public let lastModified: String?
    public let validatedRun: String?
    /// Monotonic identity for this row version. Unlike the content digest, this
    /// changes even when a row briefly changes and is restored to identical bytes.
    public let revision: Int64
}

public enum CacheBudget {
    public static let minimum = 200.0 * 1_000_000
    public static let maximum = 100.0 * 1_000_000_000
    public static func bytes(at fraction: Double) -> Int64 {
        let clamped = min(1, max(0, fraction))
        return Int64((minimum * pow(maximum / minimum, clamped)).rounded())
    }
    public static func fraction(for bytes: Int64) -> Double {
        min(1, max(0, log(Double(max(1, bytes)) / minimum) / log(maximum / minimum)))
    }
}

public actor DiskCache {
    /// Bumping this discards media files too. Metadata-only format changes bump
    /// `metadataFormatVersion`, which keeps downloaded media.
    private static let schemaVersion = 4
    private let root: URL
    private let images: URL
    let database: DatabaseQueue
    private var budget: Int64
    var generation = 0
    var metadataGeneration = 0
    /// Metadata rows are decoded only after `initializeMetadataStore` discarded any superseded format.
    var metadataInitialized = false
    private var configuredThumbnailSize: ThumbnailSize = .m
    /// Usage from the last full scan, adjusted by media writes and evictions since then.
    /// Measuring metadata cost reads every stored payload, so it is not repeated per write.
    private(set) var estimatedUsage: Int64?
    private var metadataWritesSinceUsageCheck = 0
    private var lastUsageCheck = ContinuousClock.now
    /// Metadata growth is not tracked per write; it is re-measured at most this often.
    private static let metadataUsageCheckInterval: Duration = .seconds(15)
    /// Read-recency updates are batched so a cache hit does not cost a write transaction.
    /// They are flushed before eviction, so eviction order still follows read recency.
    private var pendingTouches: [String: Double] = [:]
    private var touchFlushScheduled = false

    public init(root: URL, budget: Int64) throws {
        self.root = root
        images = root.appendingPathComponent("images", isDirectory: true)
        self.budget = budget
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("index.sqlite").path
        if FileManager.default.fileExists(atPath: path) {
            let existing = try? Self.open(path)
            let current = (try? existing?.read(Self.isCurrentSchema)) ?? false
            try? existing?.close()
            if !current { try Self.discardCacheFiles(at: root) }
        } else {
            // Image files without an index have no recoverable keys or retention records.
            try Self.discardCacheFiles(at: root)
        }
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let needsSchema = !FileManager.default.fileExists(atPath: path)
        database = try Self.open(path)
        try database.write { db in
            try CacheSchema.createMediaTables(db)
            if needsSchema { try db.execute(sql: "PRAGMA user_version=\(Self.schemaVersion)") }
        }
    }

    private static func open(_ path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.foreignKeysEnabled = false
        // A rebuildable cache does not need a sync per WAL commit.
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=NORMAL") }
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    private static func isCurrentSchema(_ db: Database) throws -> Bool {
        guard try Int.fetchOne(db, sql: "PRAGMA user_version") == schemaVersion,
              try db.tableExists(CacheEntryRecord.databaseTableName) else { return false }
        let columns = Set(try db.columns(in: CacheEntryRecord.databaseTableName).map(\.name))
        return columns.isSuperset(of: CacheEntryRecord.CodingKeys.allCases.map(\.name))
    }

    private static func discardCacheFiles(at root: URL) throws {
        let manager = FileManager.default
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "images"] {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
    }

    public func get(_ key: String) throws -> CacheEntry? {
        let started = ContinuousClock.now
        let signposter = SynologyDiagnostics.browserSignposts
        let interval = signposter.beginInterval("Cache read", id: signposter.makeSignpostID())
        defer {
            signposter.endInterval("Cache read", interval)
            let elapsed = ContinuousClock.now - started
            if elapsed > .milliseconds(100) {
                SynologyDiagnostics.originals.info(
                    "Slow cache get duration=\(String(describing: elapsed), privacy: .public)"
                )
            }
        }
        guard let record = try database.read({ try CacheEntryRecord.fetchOne($0, key: key) }) else { return nil }
        guard let filename = record.file,
              let data = try? Data(contentsOf: images.appendingPathComponent(filename)) else {
            try? remove(key)
            return nil
        }
        if let expected = record.digest, expected != digest(data) {
            try? remove(key)
            return nil
        }
        guard let kind = CacheKind(rawValue: record.kind) else {
            try? remove(key)
            return nil
        }
        try touch(key)
        return CacheEntry(data: data, kind: kind, etag: record.etag, lastModified: record.lastModified,
                          validatedRun: record.validatedRun, revision: record.rowRevision)
    }

    public func currentGeneration() -> Int { generation }

    public func currentMetadataGeneration() -> Int { metadataGeneration }

    public func setConfiguredThumbnailSize(_ size: ThumbnailSize) throws {
        guard configuredThumbnailSize != size else { return }
        configuredThumbnailSize = size
        try database.write { try reclassifyAllThumbnailFamilies($0) }
        try trim()
    }

    public func getThumbnail(_ identity: ThumbnailCacheIdentity) throws -> CacheEntry? {
        return try get(identity.key)
    }

    /// Checks an indexed thumbnail without reading or hashing its image bytes.
    /// Bulk cache warming uses this to avoid network validation and full-file I/O for exact hits.
    public func hasThumbnail(_ identity: ThumbnailCacheIdentity) throws -> Bool {
        let thumbnailKinds = [CacheKind.thumbnail, .previewThumbnail].map(\.rawValue)
        let record = try database.read {
            try CacheEntryRecord.filter { $0.key == identity.key && thumbnailKinds.contains($0.kind) }.fetchOne($0)
        }
        guard let filename = record?.file else { return false }
        guard FileManager.default.fileExists(atPath: images.appendingPathComponent(filename).path) else {
            try? remove(identity.key)
            return false
        }
        try touch(identity.key)
        return true
    }

    public func put(_ key: String, kind: CacheKind, data: Data, validatedRun: String?,
                    etag: String? = nil, lastModified: String? = nil, expectedGeneration: Int? = nil,
                    thumbnail identity: ThumbnailCacheIdentity? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        pendingTouches.removeValue(forKey: key)
        let replacedCost = try database.write { db -> Int64 in
            let existing = try CacheEntryRecord.fetchOne(db, key: key)
            let storedKind: CacheKind = kind == .previewThumbnail && existing?.kind == CacheKind.thumbnail.rawValue ? .thumbnail : kind
            let filename = switch storedKind {
            case .previewThumbnail, .thumbnail, .fullImage: key + ".img"
            case .videoSegment: key + ".video"
            }
            try data.write(to: images.appendingPathComponent(filename), options: .atomic)
            let retention = try identity.map { try retentionClass(for: $0, db) }
                ?? CachePriorityPolicy.defaultClass(for: storedKind)
            try CacheEntryRecord(key: key, kind: storedKind.rawValue, file: filename, cost: Int64(data.count),
                                 accessed: Date().timeIntervalSince1970, validatedRun: validatedRun, etag: etag,
                                 lastModified: lastModified, digest: digest(data), retentionClass: retention.rawValue,
                                 retentionRank: CachePriorityPolicy.evictionRank(for: retention),
                                 thumbnailFamily: identity?.family, thumbnailSize: identity?.size.rawValue,
                                 rowRevision: (existing?.rowRevision ?? 0) + 1).upsert(db)
            if let identity { try reclassifyThumbnailFamily(identity.family, db) }
            return existing?.cost ?? 0
        }
        estimatedUsage? += Int64(data.count) - replacedCost
        try trim()
    }

    public func markValidated(_ key: String, run: String, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        pendingTouches.removeValue(forKey: key)
        _ = try database.write { db in
            try CacheEntryRecord.filter(key: key).updateAll(db) { [
                $0.validatedRun.set(to: run), $0.accessed.set(to: Date().timeIntervalSince1970)
            ] }
        }
    }

    /// Promotes a viewer preview to an ordinary thumbnail without touching its image file.
    public func promotePreviewThumbnail(_ key: String, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        pendingTouches.removeValue(forKey: key)
        _ = try database.write { db in
            try CacheEntryRecord.filter { $0.key == key && $0.kind == CacheKind.previewThumbnail.rawValue }.updateAll(db) { [
                $0.kind.set(to: CacheKind.thumbnail.rawValue), $0.accessed.set(to: Date().timeIntervalSince1970)
            ] }
        }
    }

    public func usage() throws -> Int64 {
        try database.read { db in
            try (Int64.fetchOne(db, CacheEntryRecord.select(sum(CacheEntryRecord.Columns.cost) ?? 0)) ?? 0) + metadataStorageCost(db)
        }
    }

    func retentionClass(forKey key: String) throws -> CacheRetentionClass? {
        try database.read { try CacheEntryRecord.fetchOne($0, key: key) }?.retentionClass.flatMap(CacheRetentionClass.init(rawValue:))
    }

    public func setBudget(_ value: Int64) throws { budget = value; try trim(force: true) }

    public func clear() throws {
        generation += 1
        metadataGeneration += 1
        estimatedUsage = nil
        try database.write { db in
            for name in try String.fetchAll(db, CacheEntryRecord.filter { $0.file != nil }.select(CacheEntryRecord.Columns.file)) {
                try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
            }
            try CacheEntryRecord.deleteAll(db)
            try clearNormalizedMetadata(db)
        }
    }

    /// Supersedes admitted metadata work without discarding cached rows.
    @discardableResult
    public func advanceMetadataGeneration() -> Int {
        metadataGeneration += 1
        return metadataGeneration
    }

    /// Removes only semantic metadata. The generation advances before SQL work and
    /// is intentionally never rolled back, so pre-reset writers stay invalid even
    /// when the transaction fails.
    public func clearMetadata() throws -> Int {
        metadataGeneration += 1
        estimatedUsage = nil
        let imageKinds = [CacheKind.previewThumbnail, .fullImage, .thumbnail, .videoSegment].map(\.rawValue)
        try database.inTransaction(.immediate) { db in
            try clearNormalizedMetadata(db)
            try CacheEntryRecord.filter { !imageKinds.contains($0.kind) }.deleteAll(db)
            return .commit
        }
        return metadataGeneration
    }

    /// Keeps usage within the budget minus a reserve. Budgets with a reserve skip the full
    /// usage scan while the estimate fits and metadata was re-measured recently; the reserve
    /// absorbs metadata growth between scans. Budgets without a reserve always scan.
    func trim(metadataWrite: Bool = false, force: Bool = false) throws {
        try flushTouches()
        let reserve = budget >= 200_000_000 ? min(64_000_000, budget / 10) : 0
        let limit = budget - reserve
        if metadataWrite { metadataWritesSinceUsageCheck += 1 }
        if !force, reserve > 0, let estimate = estimatedUsage, estimate <= limit,
           metadataWritesSinceUsageCheck == 0 ||
               ContinuousClock.now - lastUsageCheck < Self.metadataUsageCheckInterval {
            return
        }
        let signposter = SynologyDiagnostics.browserSignposts
        let interval = signposter.beginInterval("Cache usage scan", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Cache usage scan", interval) }
        var current = try usage()
        metadataWritesSinceUsageCheck = 0
        lastUsageCheck = .now
        while current > limit {
            let candidate = try database.read {
                try CacheEntryRecord.order { [$0.retentionRank, $0.accessed] }.fetchOne($0)
            }
            if let freed = try trimNormalizedMetadata(throughRank: candidate?.retentionRank ?? Int.max) {
                current -= freed
                continue
            }
            guard let candidate else { break }
            try remove(candidate.key)
            current -= candidate.cost
        }
        estimatedUsage = current
    }

    func remove(_ key: String, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        pendingTouches.removeValue(forKey: key)
        let removed = try database.write { db -> CacheEntryRecord? in
            guard let record = try CacheEntryRecord.fetchOne(db, key: key) else { return nil }
            try record.delete(db)
            if let family = record.thumbnailFamily { try reclassifyThumbnailFamily(family, db) }
            return record
        }
        if let removed { estimatedUsage? -= removed.cost }
        if let filename = removed?.file { try? FileManager.default.removeItem(at: images.appendingPathComponent(filename)) }
    }

    private func touch(_ key: String) throws {
        pendingTouches[key] = Date().timeIntervalSince1970
        if pendingTouches.count >= 256 {
            try flushTouches()
        } else if !touchFlushScheduled {
            touchFlushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.scheduledTouchFlush()
            }
        }
    }

    private func scheduledTouchFlush() {
        touchFlushScheduled = false
        try? flushTouches()
    }

    func flushTouches() throws {
        guard !pendingTouches.isEmpty else { return }
        let touches = pendingTouches
        pendingTouches.removeAll(keepingCapacity: true)
        try database.write { db in
            for (key, accessed) in touches {
                try CacheEntryRecord.filter(key: key).updateAll(db) { $0.accessed.set(to: accessed) }
            }
        }
    }

    private func reclassifyAllThumbnailFamilies(_ db: Database) throws {
        let thumbnails = CacheEntryRecord.filter { $0.thumbnailFamily != nil }
        try thumbnails.updateAll(db) { classAssignments(.optionalThumbnail, $0) }
        try thumbnails.filter { $0.thumbnailSize == configuredThumbnailSize.rawValue }
            .updateAll(db) { classAssignments(.configuredThumbnail, $0) }
        let smallerSizes = ThumbnailSize.allCases.filter { $0.qualityRank < configuredThumbnailSize.qualityRank }.map(\.rawValue)
        guard !smallerSizes.isEmpty else { return }
        let configuredFamilies = thumbnails.filter { $0.thumbnailSize == configuredThumbnailSize.rawValue }
            .select(CacheEntryRecord.Columns.thumbnailFamily)
        try thumbnails.filter { smallerSizes.contains($0.thumbnailSize) && !configuredFamilies.contains($0.thumbnailFamily) }
            .updateAll(db) { classAssignments(.smallerFallbackThumbnail, $0) }
    }

    private func reclassifyThumbnailFamily(_ family: String, _ db: Database) throws {
        let exactExists = try thumbnailExists(family: family, size: configuredThumbnailSize, db)
        for var record in try CacheEntryRecord.filter({ $0.thumbnailFamily == family }).fetchAll(db) {
            guard let raw = record.thumbnailSize, let size = ThumbnailSize(rawValue: raw) else { continue }
            let retention: CacheRetentionClass
            if size == configuredThumbnailSize {
                retention = .configuredThumbnail
            } else if size.qualityRank < configuredThumbnailSize.qualityRank && !exactExists {
                retention = .smallerFallbackThumbnail
            } else {
                retention = .optionalThumbnail
            }
            record.retentionClass = retention.rawValue
            record.retentionRank = CachePriorityPolicy.evictionRank(for: retention)
            try record.update(db, columns: [CacheEntryRecord.Columns.retentionClass, CacheEntryRecord.Columns.retentionRank])
        }
    }

    private func thumbnailExists(family: String, size: ThumbnailSize, _ db: Database) throws -> Bool {
        try CacheEntryRecord.filter { $0.thumbnailFamily == family && $0.thumbnailSize == size.rawValue }.isEmpty(db) == false
    }

    private func retentionClass(for identity: ThumbnailCacheIdentity, _ db: Database) throws -> CacheRetentionClass {
        if identity.size == configuredThumbnailSize { return .configuredThumbnail }
        if identity.size.qualityRank < configuredThumbnailSize.qualityRank,
           !(try thumbnailExists(family: identity.family, size: configuredThumbnailSize, db)) {
            return .smallerFallbackThumbnail
        }
        return .optionalThumbnail
    }
}

private func classAssignments(_ retention: CacheRetentionClass, _ columns: CacheEntryRecord.Columns.Type) -> [ColumnAssignment] {
    [columns.retentionClass.set(to: retention.rawValue), columns.retentionRank.set(to: CachePriorityPolicy.evictionRank(for: retention))]
}

private extension ThumbnailSize {
    var qualityRank: Int {
        switch self { case .sm: 0; case .m: 1; case .xl: 2 }
    }
}

public enum CacheError: LocalizedError { case storage
    public var errorDescription: String? { "The local photo cache could not be used." }
}
private let hexDigits = Array("0123456789abcdef".utf8)
private func digest(_ data: Data) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(64)
    for byte in SHA256.hash(data: data) {
        bytes.append(hexDigits[Int(byte >> 4)])
        bytes.append(hexDigits[Int(byte & 0x0f)])
    }
    return String(decoding: bytes, as: UTF8.self)
}
