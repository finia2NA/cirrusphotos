import Foundation

/// The server-maintained indexes that each open as a persistent collection.
public enum CollectionIndexKind: String, CaseIterable, Codable, Sendable {
    case person, subject, tag

    public func collection(_ id: Int64, space: PhotoSpace) -> PhotoCollectionDescriptor {
        switch self {
        case .person: .person(id, space: space)
        case .subject: .subject(id, space: space)
        case .tag: .tag(id, space: space)
        }
    }
}

extension CodingUserInfoKey {
    /// Required when decoding `CollectionIndexEntry`: person covers use a different shape.
    public static let collectionIndexKind = CodingUserInfoKey(rawValue: "collectionIndexKind")!
}

/// A person, subject or tag and its cover. Names and membership remain authoritative on the NAS.
///
/// The encoded form matches the server's list rows, so stored indexes and responses share one decoder.
public struct CollectionIndexEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let thumbnail: ThumbnailInfo?

    public init(id: Int64, name: String, itemCount: Int, thumbnail: ThumbnailInfo?) {
        self.id = id; self.name = name; self.itemCount = itemCount; self.thumbnail = thumbnail
    }

    public static func decoder(for kind: CollectionIndexKind) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.collectionIndexKind] = kind
        return decoder
    }

    private enum CodingKeys: String, CodingKey { case id, name, itemCount = "item_count", additional }
    private enum AdditionalKeys: String, CodingKey { case thumbnail }
    private struct FaceThumbnail: Codable { let cache_key: String }

    public init(from decoder: Decoder) throws {
        guard let kind = decoder.userInfo[.collectionIndexKind] as? CollectionIndexKind else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing collection index kind."))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(Int64.self, forKey: .id)
        self.id = id
        name = try c.decode(String.self, forKey: .name)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        let additional = try? c.nestedContainer(keyedBy: AdditionalKeys.self, forKey: .additional)
        switch kind {
        case .person:
            // Person covers carry only a face cache key; the person ID addresses the face.
            let face = try? additional?.decode(FaceThumbnail.self, forKey: .thumbnail)
            thumbnail = face.map { ThumbnailInfo(unitID: id, cacheKey: $0.cache_key, sm: "ready", m: "ready", xl: "ready", kind: "person") }
        case .subject, .tag:
            thumbnail = try additional?.decodeIfPresent(ThumbnailInfo.self, forKey: .thumbnail)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(itemCount, forKey: .itemCount)
        var additional = c.nestedContainer(keyedBy: AdditionalKeys.self, forKey: .additional)
        if let thumbnail, thumbnail.kind == "person" {
            try additional.encode(FaceThumbnail(cache_key: thumbnail.cacheKey), forKey: .thumbnail)
        } else {
            try additional.encodeIfPresent(thumbnail, forKey: .thumbnail)
        }
    }
}
