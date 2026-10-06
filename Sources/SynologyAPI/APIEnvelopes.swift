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
struct AlbumListData: Decodable { let list: [AlbumSummary] }
struct EmptyData: Decodable {}
