import Foundation

/// A Personal Space album as returned by `SYNO.Foto.Browse.Album method=list`.
public struct AlbumSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let createTime: Int64?
    public let startTime: Int64?
    public let endTime: Int64?
    public let sortBy: String?
    public let sortDirection: String?
    public let thumbnail: ThumbnailInfo?

    enum CodingKeys: String, CodingKey {
        case id, name, additional
        case itemCount = "item_count"
        case createTime = "create_time"
        case startTime = "start_time"
        case endTime = "end_time"
        case sortBy = "sort_by"
        case sortDirection = "sort_direction"
    }

    private struct Additional: Codable {
        let thumbnail: ThumbnailInfo?
    }

    public init(id: Int64, name: String, itemCount: Int,
                createTime: Int64? = nil, startTime: Int64? = nil, endTime: Int64? = nil,
                sortBy: String? = nil, sortDirection: String? = nil,
                thumbnail: ThumbnailInfo? = nil) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.createTime = createTime
        self.startTime = startTime
        self.endTime = endTime
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.thumbnail = thumbnail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        createTime = try container.decodeIfPresent(Int64.self, forKey: .createTime)
        startTime = try container.decodeIfPresent(Int64.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Int64.self, forKey: .endTime)
        sortBy = try container.decodeIfPresent(String.self, forKey: .sortBy)
        sortDirection = try container.decodeIfPresent(String.self, forKey: .sortDirection)
        thumbnail = (try? container.decodeIfPresent(Additional.self, forKey: .additional))?.thumbnail
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(itemCount, forKey: .itemCount)
        try container.encodeIfPresent(createTime, forKey: .createTime)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(sortBy, forKey: .sortBy)
        try container.encodeIfPresent(sortDirection, forKey: .sortDirection)
        if let thumbnail {
            try container.encode(Additional(thumbnail: thumbnail), forKey: .additional)
        }
    }
}
