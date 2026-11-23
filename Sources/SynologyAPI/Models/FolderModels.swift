import Foundation

public struct FolderSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let parent: Int64
    public let additional: Additional?
    /// Parts of the row left out because they could not be read, such as `additional.thumbnail[2]`
    /// with the reason. Diagnostics only: not stored, and not part of equality.
    public let unreadableFields: [String]

    public struct Additional: Codable, Hashable, Sendable {
        public let thumbnail: [FolderThumbnail]?
        /// The account's rights in the folder; Shared Space listings report it.
        public let accessPermission: AlbumAccessPermission?
        enum CodingKeys: String, CodingKey { case thumbnail; case accessPermission = "access_permission" }
    }

    enum CodingKeys: String, CodingKey { case id, name, parent, additional }

    /// `id`, `name` and `parent` are required. A cover or permission that cannot be read is
    /// left out and listed in `unreadableFields`, so one odd value does not fail a listing.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        parent = try values.decode(Int64.self, forKey: .parent)
        var unreadable: [String] = []
        if values.contains(.additional), !((try? values.decodeNil(forKey: .additional)) ?? false) {
            do {
                let nested = try values.nestedContainer(keyedBy: Additional.CodingKeys.self, forKey: .additional)
                additional = Additional(thumbnail: Self.thumbnails(nested, unreadable: &unreadable),
                                        accessPermission: Self.permission(nested, unreadable: &unreadable))
            } catch {
                additional = nil
                unreadable.append("additional: \(error.decodingSummary)")
            }
        } else {
            additional = nil
        }
        unreadableFields = unreadable
    }

    public static func == (lhs: FolderSummary, rhs: FolderSummary) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.parent == rhs.parent && lhs.additional == rhs.additional
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(parent); hasher.combine(additional)
    }

    /// Whether the account may download originals from the folder; nil when the NAS did not say.
    public var allowsDownload: Bool? { additional?.accessPermission?.download }
    public var displayName: String { name.split(separator: "/").last.map(String.init) ?? "/" }
    private static func thumbnails(_ values: KeyedDecodingContainer<Additional.CodingKeys>,
                                   unreadable: inout [String]) -> [FolderThumbnail]? {
        guard values.contains(.thumbnail), !((try? values.decodeNil(forKey: .thumbnail)) ?? false) else { return nil }
        do {
            var list = try values.nestedUnkeyedContainer(forKey: .thumbnail)
            var thumbnails: [FolderThumbnail] = []
            while !list.isAtEnd {
                let index = list.currentIndex
                do { thumbnails.append(try list.decode(FolderThumbnail.self)) }
                catch {
                    unreadable.append("additional.thumbnail[\(index)]: \(error.decodingSummary)")
                    // Step past the entry; a failed decode leaves the container where it was.
                    guard (try? list.decode(SkippedValue.self)) != nil else { break }
                }
            }
            return thumbnails
        } catch {
            unreadable.append("additional.thumbnail: \(error.decodingSummary)")
            return nil
        }
    }

    private static func permission(_ values: KeyedDecodingContainer<Additional.CodingKeys>,
                                   unreadable: inout [String]) -> AlbumAccessPermission? {
        do { return try values.decodeIfPresent(AlbumAccessPermission.self, forKey: .accessPermission) }
        catch {
            unreadable.append("additional.access_permission: \(error.decodingSummary)")
            return nil
        }
    }
}

/// Folder listings return ordinary photo thumbnails or a server-generated custom folder cover.
/// A custom cover is identified by the folder and sequence, without a photo unit ID.
public enum FolderThumbnail: Codable, Hashable, Sendable {
    case photo(ThumbnailInfo)
    case custom(cacheKey: String, sequence: Int64)

    private enum CodingKeys: String, CodingKey {
        case cacheKey = "cache_key"
        case sequence = "folder_cover_seq"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.sequence) {
            self = .custom(cacheKey: try values.decode(String.self, forKey: .cacheKey),
                           sequence: try values.decode(Int64.self, forKey: .sequence))
        } else {
            self = .photo(try ThumbnailInfo(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .photo(let thumbnail):
            try thumbnail.encode(to: encoder)
        case .custom(let cacheKey, let sequence):
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(cacheKey, forKey: .cacheKey)
            try values.encode(sequence, forKey: .sequence)
        }
    }
}

/// Accepts any JSON value without reading it.
private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

extension Error {
    /// For a `DecodingError`, the coding path and what was wrong, without the offending value;
    /// otherwise `logSummary`.
    public var decodingSummary: String {
        guard let error = self as? DecodingError else { return logSummary }
        func path(_ codingPath: [any CodingKey]) -> String {
            let text = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : (text.isEmpty ? "<root>" : text)
        }
        switch error {
        case .typeMismatch(let type, let context):
            return "type mismatch at \(path(context.codingPath)): expected \(type)"
        case .valueNotFound(let type, let context):
            return "null at \(path(context.codingPath)): expected \(type)"
        case .keyNotFound(let key, let context):
            return "missing key \(path(context.codingPath + [key]))"
        case .dataCorrupted(let context):
            return "corrupted at \(path(context.codingPath)): \(LogRedaction.scrub(context.debugDescription))"
        @unknown default:
            return "DecodingError"
        }
    }
}
