import CryptoKit
import Foundation
import SQLite3
import SynologyAPI

public enum CacheKind: Int, Sendable {
    // Keep the established raw values stable because they are persisted in SQLite.
    // CachePriorityPolicy, not these compatibility values, defines eviction order.
    case previewThumbnail = -1
    case fullImage = 0
    case thumbnail = 1
    case page = 2
    case timeline = 3
}

public struct CacheEntry: Sendable {
    public let data: Data
    public let kind: CacheKind
    public let etag: String?
    public let lastModified: String?
    public let validatedRun: String?
}

public struct ThumbnailCacheIdentity: Sendable, Equatable {
    public let key: String
    public let family: String
    public let size: ThumbnailSize

    public init(key: String, family: String, size: ThumbnailSize) {
        self.key = key
        self.family = family
        self.size = size
    }
}

public enum CacheKey {
    public static func namespace(server: URL, account: String) -> String {
        digest("cirrus-cache-v1|\(server.absoluteString.lowercased())|\(account)")
    }
    public static func timeline(namespace: String, collection: PhotoCollectionDescriptor = .personalLibrary) -> String {
        digest("\(namespace)|\(collection.rawValue)|timeline|v6|full|day")
    }
    public static func page(namespace: String, section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary) -> String? {
        guard let bounds = section.dateBounds else { return nil }
        return digest("\(namespace)|\(collection.rawValue)|item|v7|\(bounds.start)|\(bounds.end)|\(section.offset)|\(section.limit)|thumbnail,resolution,orientation,video_convert,video_meta,address,favorite")
    }
    public static func thumbnail(namespace: String, descriptor: ThumbnailInfo, size: ThumbnailSize) -> String {
        digest("\(namespace)|personal|thumbnail|v2|unit|\(descriptor.unitID)|\(descriptor.cacheKey)|\(size.rawValue)")
    }
    public static func thumbnailIdentity(namespace: String, descriptor: ThumbnailInfo,
                                         size: ThumbnailSize) -> ThumbnailCacheIdentity {
        ThumbnailCacheIdentity(
            key: thumbnail(namespace: namespace, descriptor: descriptor, size: size),
            family: digest("\(namespace)|personal|thumbnail-family|v1|unit|\(descriptor.unitID)|\(descriptor.cacheKey)"),
            size: size
        )
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
    private var configuredThumbnailSize: ThumbnailSize = .m

    public init(root: URL, budget: Int64, protectedTimelineKey: String) throws {
        self.root = root
        images = root.appendingPathComponent("images", isDirectory: true)
        self.budget = budget
        self.protectedTimelineKey = protectedTimelineKey
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("index.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CacheError.storage }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY, kind INTEGER NOT NULL, payload BLOB, file TEXT, cost INTEGER NOT NULL, accessed REAL NOT NULL, validated_run TEXT, etag TEXT, last_modified TEXT, digest TEXT, retention_class TEXT, retention_rank INTEGER, thumbnail_family TEXT, thumbnail_size TEXT); CREATE INDEX IF NOT EXISTS entries_eviction ON entries(kind, accessed);", nil, nil, nil) == SQLITE_OK else {
            throw CacheError.storage
        }
        // Add the integrity column to early prototype indexes without discarding cached images.
        _ = sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN digest TEXT", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN retention_class TEXT", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN retention_rank INTEGER", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN thumbnail_family TEXT", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN thumbnail_size TEXT", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS entries_thumbnail_family ON entries(thumbnail_family,thumbnail_size)", nil, nil, nil)
        for kind in [CacheKind.previewThumbnail, .fullImage, .thumbnail, .page, .timeline] {
            let retention = CachePriorityPolicy.defaultClass(for: kind).rawValue
            let sql = "UPDATE entries SET retention_class='\(retention)' WHERE retention_class IS NULL AND kind=\(kind.rawValue)"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CacheError.storage }
        }
        for retention in CacheRetentionClass.allCases {
            let rank = CachePriorityPolicy.evictionRank(for: retention)
            let sql = "UPDATE entries SET retention_rank=\(rank) WHERE retention_class='\(retention.rawValue)'"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CacheError.storage }
        }
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS entries_retention ON entries(retention_rank,accessed)", nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    public func get(_ key: String) throws -> CacheEntry? {
        let sql = "SELECT payload,file,etag,last_modified,validated_run,digest,kind FROM entries WHERE key=?"
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
        guard let kind = CacheKind(rawValue: Int(sqlite3_column_int(statement, 6))) else {
            try? remove(key)
            return nil
        }
        let result = CacheEntry(data: data, kind: kind, etag: columnString(statement, 2),
                                lastModified: columnString(statement, 3), validatedRun: columnString(statement, 4))
        let touch = try prepare("UPDATE entries SET accessed=? WHERE key=?")
        defer { sqlite3_finalize(touch) }
        sqlite3_bind_double(touch, 1, Date().timeIntervalSince1970)
        bind(key, at: 2, in: touch)
        guard sqlite3_step(touch) == SQLITE_DONE else { throw CacheError.storage }
        return result
    }

    public func currentGeneration() -> Int { generation }

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
        let filename = (storedKind == .previewThumbnail || storedKind == .thumbnail || storedKind == .fullImage)
            ? key + ".img" : nil
        if let filename {
            try data.write(to: images.appendingPathComponent(filename), options: .atomic)
        }
        let retention = try identity.map { try retentionClass(for: $0) }
            ?? CachePriorityPolicy.defaultClass(for: storedKind)
        let statement = try prepare("INSERT OR REPLACE INTO entries (key,kind,payload,file,cost,accessed,validated_run,etag,last_modified,digest,retention_class,retention_rank,thumbnail_family,thumbnail_size) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(storedKind.rawValue))
        if filename == nil { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), sqliteTransient) } }
        else { sqlite3_bind_null(statement, 3) }
        bind(filename, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(data.count))
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        bind(validatedRun, at: 7, in: statement)
        bind(etag, at: 8, in: statement)
        bind(lastModified, at: 9, in: statement)
        bind(digest(data), at: 10, in: statement)
        bind(retention.rawValue, at: 11, in: statement)
        sqlite3_bind_int(statement, 12, Int32(CachePriorityPolicy.evictionRank(for: retention)))
        bind(identity?.family, at: 13, in: statement)
        bind(identity?.size.rawValue, at: 14, in: statement)
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
        return sqlite3_column_int64(statement, 0)
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
            let statement = try prepare("SELECT key FROM entries WHERE key != ? ORDER BY retention_rank ASC, accessed ASC LIMIT 1")
            bind(protectedTimelineKey, at: 1, in: statement)
            let key = sqlite3_step(statement) == SQLITE_ROW ? columnString(statement, 0) : nil
            sqlite3_finalize(statement)
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

    private func prepare(_ sql: String) throws -> OpaquePointer? {
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
    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value { _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } }
        else { sqlite3_bind_null(statement, index) }
    }
    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
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
