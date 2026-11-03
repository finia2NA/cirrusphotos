import Foundation

public struct DiffCursor: Codable, Sendable, Equatable, Hashable {
    public let diffVersion: Int64
    public let versionTime: Int64
    public init(diffVersion: Int64, versionTime: Int64) { self.diffVersion = diffVersion; self.versionTime = versionTime }
    enum CodingKeys: String, CodingKey { case diffVersion = "diff_version", versionTime = "version_time" }
}

/// The observed mobile v7 `list` interval. Cursor values are opaque.
public struct PhotoDiff: Sendable, Equatable {
    public let cursor: DiffCursor
    public let modifiedItemIDs: [Int64]
    public let deletedItemIDs: [Int64]
    public let hasNext: Bool
    public let hasUnsupportedActivity: Bool
    public init(cursor: DiffCursor, modifiedItemIDs: [Int64], deletedItemIDs: [Int64],
                hasNext: Bool = false, hasUnsupportedActivity: Bool = false) {
        self.cursor = cursor; self.modifiedItemIDs = modifiedItemIDs; self.deletedItemIDs = deletedItemIDs
        self.hasNext = hasNext; self.hasUnsupportedActivity = hasUnsupportedActivity
    }
    public var isEmpty: Bool { modifiedItemIDs.isEmpty && deletedItemIDs.isEmpty && !hasNext && !hasUnsupportedActivity }
    public var isBoundedTerminal: Bool {
        !hasNext && !hasUnsupportedActivity && modifiedItemIDs.count <= 2000 && deletedItemIDs.count <= 2000 - modifiedItemIDs.count &&
        Set(modifiedItemIDs).count == modifiedItemIDs.count && Set(deletedItemIDs).count == deletedItemIDs.count &&
        Set(modifiedItemIDs).isDisjoint(with: deletedItemIDs)
    }
}
/// One favorite toggle from the v7 `list_user_event` feed.
public struct FavoriteEvent: Sendable, Equatable {
    public let itemIDs: [Int64]
    public let favorite: Bool
    public init(itemIDs: [Int64], favorite: Bool) { self.itemIDs = itemIDs; self.favorite = favorite }
}

/// The observed v7 `list_user_event` interval. Only favorite events are understood;
/// any other event type marks the interval unsupported.
public struct UserEventDiff: Sendable, Equatable {
    public let cursor: DiffCursor
    public let favorites: [FavoriteEvent]
    public let hasNext: Bool
    public let hasUnsupportedActivity: Bool
    public init(cursor: DiffCursor, favorites: [FavoriteEvent], hasNext: Bool = false, hasUnsupportedActivity: Bool = false) {
        self.cursor = cursor; self.favorites = favorites; self.hasNext = hasNext; self.hasUnsupportedActivity = hasUnsupportedActivity
    }
    public var isEmpty: Bool { favorites.isEmpty && !hasNext && !hasUnsupportedActivity }
    public var isBoundedTerminal: Bool {
        !hasNext && !hasUnsupportedActivity && favorites.reduce(0) { $0 + $1.itemIDs.count } <= 2000
    }
}

struct UserEventDiffData: Decodable {
    let value: UserEventDiff
    private enum CodingKeys: String, CodingKey {
        case diffVersion = "diff_version", versionTime = "version_time", list
        case hasNext = "has_next"
    }
    private struct Event: Decodable {
        let eventType: String
        let targetIDs: [Int64]?
        enum CodingKeys: String, CodingKey { case eventType = "event_type", targetIDs = "target_id" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            eventType = try container.decode(String.self, forKey: .eventType)
            targetIDs = try? container.decode([Int64].self, forKey: .targetIDs)
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var favorites: [FavoriteEvent] = []
        var unsupported = false
        for event in try container.decode([Event].self, forKey: .list) {
            switch (event.eventType, event.targetIDs) {
            case ("favorite_add", let ids?): favorites.append(.init(itemIDs: ids, favorite: true))
            case ("favorite_delete", let ids?): favorites.append(.init(itemIDs: ids, favorite: false))
            default: unsupported = true
            }
        }
        value = UserEventDiff(cursor: DiffCursor(diffVersion: try container.decode(Int64.self, forKey: .diffVersion),
                                                 versionTime: try container.decode(Int64.self, forKey: .versionTime)),
                              favorites: favorites, hasNext: try container.decode(Bool.self, forKey: .hasNext),
                              hasUnsupportedActivity: unsupported)
    }
}

struct DiffVersionData: Decodable {
    let cursor: DiffCursor
    init(from decoder: Decoder) throws { cursor = try DiffCursor(from: decoder) }
}
struct PhotoDiffData: Decodable {
    let value: PhotoDiff
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case diffVersion = "diff_version", versionTime = "version_time", item, similar
        case hasNext = "has_next"
    }
    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard dynamic.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown v7 item feed category"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let item = try container.decode(ItemChanges.self, forKey: .item)
        let similar = try container.decode([OpaqueChange].self, forKey: .similar)
        value = PhotoDiff(cursor: DiffCursor(diffVersion: try container.decode(Int64.self, forKey: .diffVersion),
                                            versionTime: try container.decode(Int64.self, forKey: .versionTime)),
                          modifiedItemIDs: item.modify.map(\.id), deletedItemIDs: item.delete,
                          hasNext: try container.decode(Bool.self, forKey: .hasNext),
                          hasUnsupportedActivity: !item.merge.isEmpty || !item.move.isEmpty || !similar.isEmpty)
    }
}
private struct ItemChanges: Decodable {
    let modify: [ItemModify]
    let delete: [Int64]
    let merge: [OpaqueChange]
    let move: [OpaqueChange]
    private enum CodingKeys: String, CodingKey, CaseIterable { case modify, delete, merge, move }
    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard dynamic.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown item activity"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modify = try container.decode([ItemModify].self, forKey: .modify)
        delete = try container.decode([Int64].self, forKey: .delete)
        merge = try container.decode([OpaqueChange].self, forKey: .merge)
        move = try container.decode([OpaqueChange].self, forKey: .move)
    }
}
private struct ItemModify: Decodable { let id: Int64 }
private struct OpaqueChange: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode([String: OpaqueChange].self)) != nil { return }
        if (try? container.decode([OpaqueChange].self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(Bool.self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid activity value")
    }
}
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}
