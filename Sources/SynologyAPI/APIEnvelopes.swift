struct APIEnvelope<Value: Decodable>: Decodable {
    let success: Bool
    let data: Value?
    let error: APIError?
}

struct APIError: Decodable { let code: Int }

struct LoginData: Decodable {
    let sid: String
    let synoToken: String?

    enum CodingKeys: String, CodingKey {
        case sid
        case synoToken = "synotoken"
    }
}

struct TimelineData: Decodable { let section: [TimelineSection] }
struct ItemData: Decodable { let list: [PhotoItem] }
struct AlbumMutationData: Decodable {
    let album: AlbumSummary?
    let errorList: [DiscardedJSON]?
    enum CodingKeys: String, CodingKey { case album; case errorList = "error_list" }
}

// Error entries are intentionally opaque: their shapes are not established.
struct DiscardedJSON: Decodable {
    init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
}

struct AlbumListData: Decodable { let list: [AlbumSummary] }
struct EmptyData: Decodable {}

struct ItemSetData: Decodable {
    let errorList: [ItemSetError]
    enum CodingKeys: String, CodingKey { case errorList = "error_list" }
}

struct ItemSetError: Decodable { let id: Int64?; let code: Int? }

struct RegeneratingData: Decodable { let list: [RegeneratingEntry] }
struct RegeneratingEntry: Decodable {
    let itemID: Int64?
    let unitID: Int64
    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case unitID = "unit_id"
    }
}

struct LivePhotoUnitData: Decodable {
    let list: [LivePhotoUnitGroup]
}

struct LivePhotoUnitGroup: Decodable {
    let itemID: Int64
    let unit: [LivePhotoUnitMember]
    enum CodingKeys: String, CodingKey { case itemID = "id_item", unit }
}

struct LivePhotoUnitMember: Decodable {
    let liveType: String
    let filename: String?
    let additional: PhotoItem.Additional?
    enum CodingKeys: String, CodingKey { case liveType = "live_type", filename, additional }

    func playbackResource() -> VideoPlaybackResource? {
        guard liveType == "video", let additional, let thumbnail = additional.thumbnail,
              let quality = VideoQuality.closest(to: .high, in: Set((additional.videoConvert ?? []).compactMap(\.knownQuality))) else { return nil }
        return VideoPlaybackResource(unitID: thumbnail.unitID, cacheKey: thumbnail.cacheKey,
                                     filename: filename, variant: .converted(quality))
    }
}
