import Foundation

/// A Synology tag and its cover.
public struct TagSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let thumbnail: ThumbnailInfo?

    private enum CodingKeys: String, CodingKey { case id, name, itemCount = "item_count", additional }
    private struct Additional: Codable { let thumbnail: ThumbnailInfo? }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        thumbnail = try c.decodeIfPresent(Additional.self, forKey: .additional)?.thumbnail
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(itemCount, forKey: .itemCount)
        try c.encode(Additional(thumbnail: thumbnail), forKey: .additional)
    }
}
