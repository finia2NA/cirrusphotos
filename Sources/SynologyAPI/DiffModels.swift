import Foundation

public struct DiffCursor: Codable, Sendable, Equatable, Hashable {
    public let diffVersion: Int64
    public let versionTime: Int64

    public init(diffVersion: Int64, versionTime: Int64) {
        self.diffVersion = diffVersion
        self.versionTime = versionTime
    }

    enum CodingKeys: String, CodingKey {
        case diffVersion = "diff_version"
        case versionTime = "version_time"
    }
}

public struct PhotoDiff: Sendable, Equatable {
    public let cursor: DiffCursor
    public let modifiedItemIDs: [Int64]
    public let deletedItemIDs: [Int64]
    public let hasAlbumActivity: Bool

    public init(cursor: DiffCursor, modifiedItemIDs: [Int64],
                deletedItemIDs: [Int64], hasAlbumActivity: Bool) {
        self.cursor = cursor
        self.modifiedItemIDs = modifiedItemIDs
        self.deletedItemIDs = deletedItemIDs
        self.hasAlbumActivity = hasAlbumActivity
    }

    public var isEmpty: Bool {
        modifiedItemIDs.isEmpty && deletedItemIDs.isEmpty && !hasAlbumActivity
    }
}

public struct LocationItemLookup: Sendable, Equatable {
    public let requestedIDs: [Int64]
    public let items: [PhotoItem]

    public init(requestedIDs: [Int64], items: [PhotoItem]) {
        self.requestedIDs = requestedIDs
        self.items = items
    }
}

struct DiffVersionData: Decodable {
    let cursor: DiffCursor

    init(from decoder: Decoder) throws {
        cursor = try DiffCursor(from: decoder)
    }
}

struct PhotoDiffData: Decodable {
    let value: PhotoDiff

    private enum CodingKeys: String, CodingKey {
        case diffVersion = "diff_version"
        case versionTime = "version_time"
        case item, album
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cursor = DiffCursor(
            diffVersion: try container.decode(Int64.self, forKey: .diffVersion),
            versionTime: try container.decode(Int64.self, forKey: .versionTime)
        )
        let item = try container.decode(StrictChangeGroup<ItemModify>.self, forKey: .item)
        let album = try container.decode(StrictChangeGroup<OpaqueChange>.self, forKey: .album)
        value = PhotoDiff(
            cursor: cursor,
            modifiedItemIDs: item.modify.map(\.id),
            deletedItemIDs: try item.delete.map { try $0.integerValue() },
            hasAlbumActivity: !album.modify.isEmpty || !album.delete.isEmpty
        )
    }
}

private struct StrictChangeGroup<Modify: Decodable>: Decodable {
    let modify: [Modify]
    let delete: [OpaqueChange]

    private enum CodingKeys: String, CodingKey, CaseIterable { case modify, delete }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown Diff change category")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modify = try container.decode([Modify].self, forKey: .modify)
        delete = try container.decode([OpaqueChange].self, forKey: .delete)
    }
}

private struct ItemModify: Decodable {
    let id: Int64
}

private enum OpaqueChange: Decodable {
    case integer(Int64)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if (try? container.decode(JSONValue.self)) != nil { self = .other }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Diff entry") }
    }

    func integerValue() throws -> Int64 {
        guard case .integer(let value) = self else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Item deletion is not an integer ID")
            )
        }
        return value
    }
}

private enum JSONValue: Decodable {
    case object, array, string, number, bool, null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if (try? container.decode([String: JSONValue].self)) != nil { self = .object }
        else if (try? container.decode([JSONValue].self)) != nil { self = .array }
        else if (try? container.decode(String.self)) != nil { self = .string }
        else if (try? container.decode(Double.self)) != nil { self = .number }
        else if (try? container.decode(Bool.self)) != nil { self = .bool }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}
