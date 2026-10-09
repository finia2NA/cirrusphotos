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
