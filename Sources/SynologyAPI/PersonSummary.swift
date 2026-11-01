import Foundation

/// A server-recognized person. Names and membership remain authoritative on the NAS.
public struct PersonSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let thumbnail: ThumbnailInfo?

    private enum CodingKeys: String, CodingKey { case id, name, itemCount = "item_count", additional }
    private struct FaceThumbnail: Codable { let cache_key: String }
    private struct Additional: Codable {
        let thumbnail: FaceThumbnail?
        init(thumbnail: FaceThumbnail?) { self.thumbnail = thumbnail }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            thumbnail = try? c.decode(FaceThumbnail.self, forKey: .thumbnail)
        }
        enum CodingKeys: String, CodingKey { case thumbnail }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let personID = try c.decode(Int64.self, forKey: .id)
        id = personID
        name = try c.decode(String.self, forKey: .name)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        let face = try c.decodeIfPresent(Additional.self, forKey: .additional)?.thumbnail
        thumbnail = face.map { ThumbnailInfo(unitID: personID, cacheKey: $0.cache_key, sm: "ready", m: "ready", xl: "ready", kind: "person") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(itemCount, forKey: .itemCount)
        try c.encode(Additional(thumbnail: thumbnail.map { FaceThumbnail(cache_key: $0.cacheKey) }), forKey: .additional)
    }
}
