import CryptoKit
import Foundation
import SQLite3
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
    nonisolated(unsafe) var db: OpaquePointer?
    private var budget: Int64
    var generation = 0
    var metadataGeneration = 0
    private var configuredThumbnailSize: ThumbnailSize = .m

    public init(root: URL, budget: Int64) throws {
        self.root = root
        images = root.appendingPathComponent("images", isDirectory: true)
        self.budget = budget
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("index.sqlite").path
        if FileManager.default.fileExists(atPath: path) {
            let opened = sqlite3_open(path, &db) == SQLITE_OK
            if !opened || !Self.isCurrentSchema(db) {
                sqlite3_close(db)
                db = nil
                try Self.discardCacheFiles(at: root)
            }
        } else {
            // Image files without an index have no recoverable keys or retention records.
            try Self.discardCacheFiles(at: root)
        }
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let needsSchema = db == nil
        if db == nil {
            guard sqlite3_open(path, &db) == SQLITE_OK else { throw CacheError.storage }
        }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY, kind INTEGER NOT NULL, file TEXT, cost INTEGER NOT NULL, accessed REAL NOT NULL, validated_run TEXT, etag TEXT, last_modified TEXT, digest TEXT, retention_class TEXT, retention_rank INTEGER, thumbnail_family TEXT, thumbnail_size TEXT, row_revision INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS entries_retention ON entries(retention_rank,accessed); CREATE INDEX IF NOT EXISTS entries_thumbnail_family ON entries(thumbnail_family,thumbnail_size);", nil, nil, nil) == SQLITE_OK else {
            throw CacheError.storage
        }
        if needsSchema {
            guard sqlite3_exec(db, "PRAGMA user_version=\(Self.schemaVersion)", nil, nil, nil) == SQLITE_OK else {
                throw CacheError.storage
            }
        }
    }

    private static func isCurrentSchema(_ db: OpaquePointer?) -> Bool {
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW,
              sqlite3_column_int(version, 0) == schemaVersion else { return false }
        var entries: OpaquePointer?
        let query = "SELECT key,kind,file,cost,accessed,validated_run,etag,last_modified,digest,retention_class,retention_rank,thumbnail_family,thumbnail_size,row_revision FROM entries LIMIT 0"
        guard sqlite3_prepare_v2(db, query, -1, &entries, nil) == SQLITE_OK else { return false }
        sqlite3_finalize(entries)
        return true
    }

    private static func discardCacheFiles(at root: URL) throws {
        let manager = FileManager.default
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "images"] {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
    }

    deinit { sqlite3_close(db) }

    public func get(_ key: String) throws -> CacheEntry? {
        let sql = "SELECT file,etag,last_modified,validated_run,digest,kind,row_revision FROM entries WHERE key=?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let filename = columnString(statement, 0),
              let data = try? Data(contentsOf: images.appendingPathComponent(filename)) else {
            try? remove(key)
            return nil
        }
        if let expected = columnString(statement, 4), expected != digest(data) {
            try? remove(key)
            return nil
        }
        guard let kind = CacheKind(rawValue: Int(sqlite3_column_int(statement, 5))) else {
            try? remove(key)
            return nil
        }
        let revision = sqlite3_column_int64(statement, 6)
        let result = CacheEntry(data: data, kind: kind, etag: columnString(statement, 1),
                                lastModified: columnString(statement, 2),
                                validatedRun: columnString(statement, 3), revision: revision)
        let touch = try prepare("UPDATE entries SET accessed=? WHERE key=?")
        defer { sqlite3_finalize(touch) }
        sqlite3_bind_double(touch, 1, Date().timeIntervalSince1970)
        bind(key, at: 2, in: touch)
        guard sqlite3_step(touch) == SQLITE_DONE else { throw CacheError.storage }
        return result
    }

    public func currentGeneration() -> Int { generation }

    public func currentMetadataGeneration() -> Int { metadataGeneration }

    public func setConfiguredThumbnailSize(_ size: ThumbnailSize) throws {
        guard configuredThumbnailSize != size else { return }
        configuredThumbnailSize = size
        try reclassifyAllThumbnailFamilies()
        try trim()
    }

    public func getThumbnail(_ identity: ThumbnailCacheIdentity) throws -> CacheEntry? {
        return try get(identity.key)
    }

    /// Checks an indexed thumbnail without reading or hashing its image bytes.
    /// Bulk cache warming uses this to avoid network validation and full-file I/O for exact hits.
    public func hasThumbnail(_ identity: ThumbnailCacheIdentity) throws -> Bool {
        let statement = try prepare("SELECT file FROM entries WHERE key=? AND (kind=? OR kind=?)")
        bind(identity.key, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(CacheKind.thumbnail.rawValue))
        sqlite3_bind_int(statement, 3, Int32(CacheKind.previewThumbnail.rawValue))
        let found = sqlite3_step(statement) == SQLITE_ROW
        let filename = found ? columnString(statement, 0) : nil
        sqlite3_finalize(statement)
        guard let filename else { return false }
        guard FileManager.default.fileExists(atPath: images.appendingPathComponent(filename).path) else {
            try? remove(identity.key)
            return false
        }
        let touch = try prepare("UPDATE entries SET accessed=? WHERE key=?")
        defer { sqlite3_finalize(touch) }
        sqlite3_bind_double(touch, 1, Date().timeIntervalSince1970)
        bind(identity.key, at: 2, in: touch)
        guard sqlite3_step(touch) == SQLITE_DONE else { throw CacheError.storage }
        return true
    }

    public func put(_ key: String, kind: CacheKind, data: Data, validatedRun: String?,
                    etag: String? = nil, lastModified: String? = nil, expectedGeneration: Int? = nil,
                    thumbnail identity: ThumbnailCacheIdentity? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        let storedKind: CacheKind
        if kind == .previewThumbnail, try existingKind(for: key) == .thumbnail {
            storedKind = .thumbnail
        } else {
            storedKind = kind
        }
        let filename = switch storedKind {
        case .previewThumbnail, .thumbnail, .fullImage: key + ".img"
        case .videoSegment: key + ".video"
        }
        try data.write(to: images.appendingPathComponent(filename), options: .atomic)
        let retention = try identity.map { try retentionClass(for: $0) }
            ?? CachePriorityPolicy.defaultClass(for: storedKind)
        let statement = try prepare("""
            INSERT INTO entries
                (key,kind,file,cost,accessed,validated_run,etag,last_modified,digest,
                 retention_class,retention_rank,thumbnail_family,thumbnail_size,row_revision)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1)
            ON CONFLICT(key) DO UPDATE SET
                kind=excluded.kind, file=excluded.file,
                cost=excluded.cost, accessed=excluded.accessed,
                validated_run=excluded.validated_run, etag=excluded.etag,
                last_modified=excluded.last_modified, digest=excluded.digest,
                retention_class=excluded.retention_class,
                retention_rank=excluded.retention_rank,
                thumbnail_family=excluded.thumbnail_family,
                thumbnail_size=excluded.thumbnail_size,
                row_revision=entries.row_revision+1
            """)
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(storedKind.rawValue))
        bind(filename, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, Int64(data.count))
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        bind(validatedRun, at: 6, in: statement)
        bind(etag, at: 7, in: statement)
        bind(lastModified, at: 8, in: statement)
        bind(digest(data), at: 9, in: statement)
        bind(retention.rawValue, at: 10, in: statement)
        sqlite3_bind_int(statement, 11, Int32(CachePriorityPolicy.evictionRank(for: retention)))
        bind(identity?.family, at: 12, in: statement)
        bind(identity?.size.rawValue, at: 13, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
        if let identity { try reclassifyThumbnailFamily(identity.family) }
        try trim()
    }



    public func markValidated(_ key: String, run: String, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        let statement = try prepare("UPDATE entries SET validated_run=?, accessed=? WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(run, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bind(key, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
    }

    /// Promotes a viewer preview to an ordinary thumbnail without touching its image file.
    public func promotePreviewThumbnail(_ key: String, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        let statement = try prepare("UPDATE entries SET kind=?, accessed=? WHERE key=? AND kind=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(CacheKind.thumbnail.rawValue))
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bind(key, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, Int32(CacheKind.previewThumbnail.rawValue))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
    }

    public func usage() throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(SUM(cost),0) FROM entries")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CacheError.storage }
        return sqlite3_column_int64(statement, 0) + (try metadataStorageCost())
    }

    func retentionClass(forKey key: String) throws -> CacheRetentionClass? {
        let statement = try prepare("SELECT retention_class FROM entries WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = columnString(statement, 0) else { return nil }
        return CacheRetentionClass(rawValue: raw)
    }

    public func setBudget(_ value: Int64) throws { budget = value; try trim() }

    public func clear() throws {
        generation += 1
        metadataGeneration += 1
        let statement = try prepare("SELECT file FROM entries WHERE file IS NOT NULL")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnString(statement, 0) {
                try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
            }
        }
        guard sqlite3_exec(db, "DELETE FROM entries", nil, nil, nil) == SQLITE_OK else { throw CacheError.storage }
        try clearNormalizedMetadata()
    }

    /// Removes only semantic metadata. The generation advances before SQL work and
    /// is intentionally never rolled back, so pre-reset writers stay invalid even
    /// when the transaction fails.
    @discardableResult
    /// Supersedes admitted metadata work without discarding cached rows.
    public func advanceMetadataGeneration() -> Int {
        metadataGeneration += 1
        return metadataGeneration
    }

    public func clearMetadata() throws -> Int {
        metadataGeneration += 1
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw CacheError.storage
        }
        do { try clearNormalizedMetadata() } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        let imageKinds = [CacheKind.previewThumbnail, .fullImage, .thumbnail, .videoSegment]
            .map { String($0.rawValue) }.joined(separator: ",")
        guard sqlite3_exec(db, "DELETE FROM entries WHERE kind NOT IN (\(imageKinds))", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw CacheError.storage
        }
        return metadataGeneration
    }

    func trim() throws {
        let reserve = budget >= 200_000_000 ? min(64_000_000, budget / 10) : 0
        while try usage() > budget - reserve {
            let statement = try prepare("SELECT key,retention_rank FROM entries ORDER BY retention_rank ASC, accessed ASC LIMIT 1")
            let found = sqlite3_step(statement) == SQLITE_ROW
            let key = found ? columnString(statement, 0) : nil
            let rank = found ? Int(sqlite3_column_int(statement, 1)) : Int.max
            sqlite3_finalize(statement)
            if try trimNormalizedMetadata(throughRank: rank) { continue }
            guard let key else { break }
            try remove(key)
        }
    }

    func remove(_ key: String, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        let existing = try prepare("SELECT file,thumbnail_family FROM entries WHERE key=?")
        bind(key, at: 1, in: existing)
        let found = sqlite3_step(existing) == SQLITE_ROW
        let filename = found ? columnString(existing, 0) : nil
        let family = found ? columnString(existing, 1) : nil
        sqlite3_finalize(existing)
        let statement = try prepare("DELETE FROM entries WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
        if let filename { try? FileManager.default.removeItem(at: images.appendingPathComponent(filename)) }
        if let family { try reclassifyThumbnailFamily(family) }
    }

    private func reclassifyAllThumbnailFamilies() throws {
        let optional = try prepare("UPDATE entries SET retention_class=?,retention_rank=? WHERE thumbnail_family IS NOT NULL")
        bind(CacheRetentionClass.optionalThumbnail.rawValue, at: 1, in: optional)
        sqlite3_bind_int(optional, 2, Int32(CachePriorityPolicy.evictionRank(for: .optionalThumbnail)))
        let optionalResult = sqlite3_step(optional)
        sqlite3_finalize(optional)
        guard optionalResult == SQLITE_DONE else { throw CacheError.storage }

        let configured = try prepare("UPDATE entries SET retention_class=?,retention_rank=? WHERE thumbnail_family IS NOT NULL AND thumbnail_size=?")
        bind(CacheRetentionClass.configuredThumbnail.rawValue, at: 1, in: configured)
        sqlite3_bind_int(configured, 2, Int32(CachePriorityPolicy.evictionRank(for: .configuredThumbnail)))
        bind(configuredThumbnailSize.rawValue, at: 3, in: configured)
        let configuredResult = sqlite3_step(configured)
        sqlite3_finalize(configured)
        guard configuredResult == SQLITE_DONE else { throw CacheError.storage }

        let smallerSizes = ThumbnailSize.allCases.filter {
            $0.qualityRank < configuredThumbnailSize.qualityRank
        }
        guard !smallerSizes.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: smallerSizes.count).joined(separator: ",")
        let fallback = try prepare("UPDATE entries SET retention_class=?,retention_rank=? WHERE thumbnail_family IS NOT NULL AND thumbnail_size IN (\(placeholders)) AND thumbnail_family NOT IN (SELECT thumbnail_family FROM entries WHERE thumbnail_family IS NOT NULL AND thumbnail_size=?)")
        bind(CacheRetentionClass.smallerFallbackThumbnail.rawValue, at: 1, in: fallback)
        sqlite3_bind_int(fallback, 2, Int32(CachePriorityPolicy.evictionRank(for: .smallerFallbackThumbnail)))
        for (offset, size) in smallerSizes.enumerated() {
            bind(size.rawValue, at: Int32(offset + 3), in: fallback)
        }
        bind(configuredThumbnailSize.rawValue, at: Int32(smallerSizes.count + 3), in: fallback)
        let fallbackResult = sqlite3_step(fallback)
        sqlite3_finalize(fallback)
        guard fallbackResult == SQLITE_DONE else { throw CacheError.storage }
    }

    private func reclassifyThumbnailFamily(_ family: String) throws {
        let exactExists = try thumbnailExists(family: family, size: configuredThumbnailSize)
        let query = try prepare("SELECT key,thumbnail_size FROM entries WHERE thumbnail_family=?")
        bind(family, at: 1, in: query)
        var updates: [(String, CacheRetentionClass)] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let key = columnString(query, 0),
                  let raw = columnString(query, 1),
                  let size = ThumbnailSize(rawValue: raw) else { continue }
            let retention: CacheRetentionClass
            if size == configuredThumbnailSize {
                retention = .configuredThumbnail
            } else if size.qualityRank < configuredThumbnailSize.qualityRank && !exactExists {
                retention = .smallerFallbackThumbnail
            } else {
                retention = .optionalThumbnail
            }
            updates.append((key, retention))
        }
        sqlite3_finalize(query)
        for (key, retention) in updates {
            let update = try prepare("UPDATE entries SET retention_class=?,retention_rank=? WHERE key=?")
            bind(retention.rawValue, at: 1, in: update)
            sqlite3_bind_int(update, 2, Int32(CachePriorityPolicy.evictionRank(for: retention)))
            bind(key, at: 3, in: update)
            let result = sqlite3_step(update)
            sqlite3_finalize(update)
            guard result == SQLITE_DONE else { throw CacheError.storage }
        }
    }

    private func thumbnailExists(family: String, size: ThumbnailSize) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM entries WHERE thumbnail_family=? AND thumbnail_size=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(family, at: 1, in: statement)
        bind(size.rawValue, at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func retentionClass(for identity: ThumbnailCacheIdentity) throws -> CacheRetentionClass {
        if identity.size == configuredThumbnailSize { return .configuredThumbnail }
        if identity.size.qualityRank < configuredThumbnailSize.qualityRank,
           !(try thumbnailExists(family: identity.family, size: configuredThumbnailSize)) {
            return .smallerFallbackThumbnail
        }
        return .optionalThumbnail
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CacheError.storage }
        return statement
    }
    private func existingKind(for key: String) throws -> CacheKind? {
        let statement = try prepare("SELECT kind FROM entries WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return CacheKind(rawValue: Int(sqlite3_column_int(statement, 0)))
    }
    private func storedRevision(for key: String) throws -> Int64? {
        let statement = try prepare("SELECT row_revision FROM entries WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }
    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value { _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } }
        else { sqlite3_bind_null(statement, index) }
    }
    func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

private extension ThumbnailSize {
    var qualityRank: Int {
        switch self { case .sm: 0; case .m: 1; case .xl: 2 }
    }
}

public enum CacheError: LocalizedError { case storage
    public var errorDescription: String? { "The local photo cache could not be used." }
}
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
