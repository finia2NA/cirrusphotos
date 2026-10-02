import CryptoKit
import Foundation
import SQLite3
import SynologyAPI

public enum CacheKind: Int, Sendable { case fullImage = 0, thumbnail = 1, page = 2, timeline = 3 }

public struct CacheEntry: Sendable {
    public let data: Data
    public let etag: String?
    public let lastModified: String?
    public let validatedRun: String?
}

public enum CacheKey {
    public static func namespace(server: URL, account: String) -> String {
        digest("cirrus-cache-v1|\(server.absoluteString.lowercased())|\(account)")
    }
    public static func timeline(namespace: String) -> String {
        digest("\(namespace)|personal|timeline|v6|full|day")
    }
    public static func page(namespace: String, section: TimelineSection) -> String? {
        guard let bounds = section.dateBounds else { return nil }
        return digest("\(namespace)|personal|item|v7|\(bounds.start)|\(bounds.end)|\(section.offset)|\(section.limit)|thumbnail,resolution,orientation,video_convert,video_meta,address,favorite")
    }
    public static func thumbnail(namespace: String, descriptor: ThumbnailInfo, size: ThumbnailSize) -> String {
        digest("\(namespace)|personal|thumbnail|v2|unit|\(descriptor.unitID)|\(descriptor.cacheKey)|\(size.rawValue)")
    }
    public static func fullImage(namespace: String, resource: FullImageResource) -> String {
        digest("\(namespace)|personal|download|v2|unit|\(resource.unitID)|\(resource.cacheKey)")
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
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
    private let root: URL
    private let images: URL
    nonisolated(unsafe) private var db: OpaquePointer?
    private var budget: Int64
    private let protectedTimelineKey: String
    private var generation = 0

    public init(root: URL, budget: Int64, protectedTimelineKey: String) throws {
        self.root = root
        images = root.appendingPathComponent("images", isDirectory: true)
        self.budget = budget
        self.protectedTimelineKey = protectedTimelineKey
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("index.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CacheError.storage }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY, kind INTEGER NOT NULL, payload BLOB, file TEXT, cost INTEGER NOT NULL, accessed REAL NOT NULL, validated_run TEXT, etag TEXT, last_modified TEXT, digest TEXT); CREATE INDEX IF NOT EXISTS entries_eviction ON entries(kind, accessed);", nil, nil, nil) == SQLITE_OK else {
            throw CacheError.storage
        }
        // Add the integrity column to early prototype indexes without discarding cached images.
        _ = sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN digest TEXT", nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    public func get(_ key: String) throws -> CacheEntry? {
        let sql = "SELECT payload,file,etag,last_modified,validated_run,digest FROM entries WHERE key=?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let filename = columnString(statement, 1)
        let data: Data
        if let filename {
            let url = images.appendingPathComponent(filename)
            guard let loaded = try? Data(contentsOf: url) else {
                try? remove(key)
                return nil
            }
            data = loaded
        } else {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            data = Data(bytes: bytes, count: count)
        }
        if let expected = columnString(statement, 5), expected != digest(data) {
            try? remove(key)
            return nil
        }
        let result = CacheEntry(data: data, etag: columnString(statement, 2),
                                lastModified: columnString(statement, 3), validatedRun: columnString(statement, 4))
        let touch = try prepare("UPDATE entries SET accessed=? WHERE key=?")
        defer { sqlite3_finalize(touch) }
        sqlite3_bind_double(touch, 1, Date().timeIntervalSince1970)
        bind(key, at: 2, in: touch)
        guard sqlite3_step(touch) == SQLITE_DONE else { throw CacheError.storage }
        return result
    }

    public func currentGeneration() -> Int { generation }

    public func put(_ key: String, kind: CacheKind, data: Data, validatedRun: String?,
                    etag: String? = nil, lastModified: String? = nil, expectedGeneration: Int? = nil) throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        let filename = (kind == .thumbnail || kind == .fullImage) ? key + ".img" : nil
        if let filename {
            try data.write(to: images.appendingPathComponent(filename), options: .atomic)
        }
        let statement = try prepare("INSERT OR REPLACE INTO entries (key,kind,payload,file,cost,accessed,validated_run,etag,last_modified,digest) VALUES (?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(kind.rawValue))
        if filename == nil { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), sqliteTransient) } }
        else { sqlite3_bind_null(statement, 3) }
        bind(filename, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(data.count))
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        bind(validatedRun, at: 7, in: statement)
        bind(etag, at: 8, in: statement)
        bind(lastModified, at: 9, in: statement)
        bind(digest(data), at: 10, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
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

    public func usage() throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(SUM(cost),0) FROM entries")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CacheError.storage }
        return sqlite3_column_int64(statement, 0)
    }

    public func setBudget(_ value: Int64) throws { budget = value; try trim() }

    public func clear() throws {
        generation += 1
        let statement = try prepare("SELECT file FROM entries WHERE file IS NOT NULL")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnString(statement, 0) {
                try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
            }
        }
        guard sqlite3_exec(db, "DELETE FROM entries", nil, nil, nil) == SQLITE_OK else { throw CacheError.storage }
    }

    private func trim() throws {
        let reserve = budget >= 200_000_000 ? min(64_000_000, budget / 10) : 0
        while try usage() > budget - reserve {
            let statement = try prepare("SELECT key FROM entries WHERE key != ? ORDER BY kind ASC, accessed ASC LIMIT 1")
            bind(protectedTimelineKey, at: 1, in: statement)
            let key = sqlite3_step(statement) == SQLITE_ROW ? columnString(statement, 0) : nil
            sqlite3_finalize(statement)
            guard let key else { break }
            try remove(key)
        }
    }

    private func remove(_ key: String) throws {
        let existing = try prepare("SELECT file FROM entries WHERE key=?")
        bind(key, at: 1, in: existing)
        let filename = sqlite3_step(existing) == SQLITE_ROW ? columnString(existing, 0) : nil
        sqlite3_finalize(existing)
        let statement = try prepare("DELETE FROM entries WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
        if let filename { try? FileManager.default.removeItem(at: images.appendingPathComponent(filename)) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CacheError.storage }
        return statement
    }
    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value { _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } }
        else { sqlite3_bind_null(statement, index) }
    }
    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

public enum CacheError: LocalizedError { case storage
    public var errorDescription: String? { "The local photo cache could not be used." }
}
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
