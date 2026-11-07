import Foundation
import GRDB

/// What cached bytes are for, as the Storage settings show them.
public enum CacheUsageCategory: String, CaseIterable, Sendable, Identifiable {
    case metadata, thumbnails, previews, fullImages, video

    public var id: Self { self }

    public var title: String {
        switch self {
        case .metadata: "Metadata"
        case .thumbnails: "Thumbnails"
        case .previews: "Large previews"
        case .fullImages: "Full-size photos"
        case .video: "Video"
        }
    }

    init(_ kind: CacheKind) {
        switch kind {
        case .thumbnail: self = .thumbnails
        case .previewThumbnail: self = .previews
        case .fullImage: self = .fullImages
        case .videoSegment: self = .video
        }
    }
}

/// Bytes by category, counted the way the cache budget counts them.
public struct CacheUsageBreakdown: Sendable, Equatable {
    public var bytes: [CacheUsageCategory: Int64] = [:]
    public var total: Int64 { bytes.values.reduce(0, +) }

    public init(bytes: [CacheUsageCategory: Int64] = [:]) { self.bytes = bytes }
}

/// One account's cache directory.
public struct CachedAccount: Sendable, Identifiable, Equatable {
    /// The directory name, `CacheKey.namespace(server:account:)`.
    public let namespace: String
    public let server: String?
    public let username: String?
    public let usage: CacheUsageBreakdown

    public var id: String { namespace }
}

/// The per-account directories under the cache root: what each holds, and removal.
public enum CacheInventory {
    static let labelFile = "account.json"

    private struct Label: Codable {
        let server: String
        let username: String
    }

    /// Names the account a cache directory belongs to; the directory name is a hash.
    static func writeLabel(root: URL, server: URL, username: String) {
        let label = Label(server: server.host ?? server.absoluteString, username: username)
        guard let data = try? JSONEncoder().encode(label) else { return }
        try? data.write(to: root.appendingPathComponent(labelFile), options: .atomic)
    }

    /// Reads every account directory without opening it as a cache, so nothing is
    /// discarded or created. Directories without a current cache database are skipped.
    public static func scan(root: URL = CacheLocation.defaultRoot()) -> [CachedAccount] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries.compactMap { directory -> CachedAccount? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let usage = usage(at: directory) else { return nil }
            let label = (try? Data(contentsOf: directory.appendingPathComponent(labelFile)))
                .flatMap { try? JSONDecoder().decode(Label.self, from: $0) }
            return CachedAccount(namespace: directory.lastPathComponent, server: label?.server,
                                 username: label?.username, usage: usage)
        }
        .sorted { $0.usage.total > $1.usage.total }
    }

    static func usage(at directory: URL) -> CacheUsageBreakdown? {
        let path = directory.appendingPathComponent("index.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var configuration = Configuration()
        configuration.readonly = true
        guard let database = try? DatabaseQueue(path: path, configuration: configuration) else { return nil }
        defer { try? database.close() }
        return try? database.read { db -> CacheUsageBreakdown in
            var usage = CacheUsageBreakdown()
            usage.bytes[.metadata] = try DiskCache.metadataStorageCost(in: db)
            guard try db.tableExists(CacheEntryRecord.databaseTableName) else { return usage }
            let rows = try Row.fetchAll(db, sql: "SELECT kind, SUM(cost) AS cost FROM \(CacheEntryRecord.databaseTableName) GROUP BY kind")
            for row in rows {
                guard let kind = CacheKind(rawValue: row["kind"]) else { continue }
                usage.bytes[CacheUsageCategory(kind), default: 0] += row["cost"] ?? 0
            }
            return usage
        }
    }

    /// Deletes one account's cache directory. The account's repository must be shut down.
    public static func remove(namespace: String, root: URL = CacheLocation.defaultRoot()) throws {
        guard !namespace.isEmpty, !namespace.contains("/"), namespace != ".", namespace != ".." else { return }
        let directory = root.appendingPathComponent(namespace, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
