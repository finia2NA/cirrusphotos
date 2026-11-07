struct APIEnvelope<Value: Decodable>: Decodable {
    let success: Bool
    let data: Value?
    let error: APIError?
}

struct APIError: Decodable { let code: Int }

struct LoginData: Decodable {
    let sid: String
    let synoToken: String?
    /// The trusted-device token; returned by v6 logins.
    let did: String?

    enum CodingKeys: String, CodingKey {
        case sid, did
        case synoToken = "synotoken"
    }
}

public struct SignInResult: Sendable, Equatable {
    /// Lets later logins skip the code when the login proved one.
    public let deviceToken: String?

    public init(deviceToken: String?) { self.deviceToken = deviceToken }
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

/// `SYNO.Foto.BackgroundTask.File` / `.Info` task record. `completion` counts
/// requested IDs, so it never proves which items were deleted.
struct BackgroundTaskInfo: Decodable {
    let id: Int64
    let status: String
    let error: Int
}

struct BackgroundTaskSubmission: Decodable {
    let taskInfo: BackgroundTaskInfo
    enum CodingKeys: String, CodingKey { case taskInfo = "task_info" }
}

struct BackgroundTaskList: Decodable { let list: [BackgroundTaskInfo] }

struct ItemSetData: Decodable {
    let errorList: [ItemSetError]
    enum CodingKeys: String, CodingKey { case errorList = "error_list" }
}

struct ItemSetError: Decodable { let id: Int64?; let code: Int? }

/// A write result whose `error_list` is empty on success. Failed entries are bare item IDs
/// for tags and objects for other fields, so only their number is read.
struct ItemWriteResult: Decodable {
    let errorList: [Entry]
    enum CodingKeys: String, CodingKey { case errorList = "error_list" }
    struct Entry: Decodable { init(from decoder: Decoder) throws {} }
}

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

    func playbackResource(scope: PhotoContentScope) -> VideoPlaybackResource? {
        guard liveType == "video", let additional, let thumbnail = additional.thumbnail,
              let quality = VideoQuality.closest(to: .high, in: Set((additional.videoConvert ?? []).compactMap(\.knownQuality))) else { return nil }
        return VideoPlaybackResource(scope: scope, unitID: thumbnail.unitID, cacheKey: thumbnail.cacheKey,
                                     filename: filename, variant: .converted(quality))
    }
}
