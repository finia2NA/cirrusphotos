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
    /// Bare IDs from `item.merge`. Adding a Live Photo creates a short-lived item for its
    /// video that the NAS then folds into the still; the merge lists that absorbed ID,
    /// which no longer exists, while the still arrives in `modify`. The reconciler looks
    /// merged IDs up and treats each as a replacement if it exists and a deletion if not.
    public let mergedItemIDs: [Int64]
    public let hasNext: Bool
    public let hasUnsupportedActivity: Bool
    /// Entry counts of the non-empty categories that make `hasUnsupportedActivity` true.
    public let unsupportedCounts: [String: Int]
    /// Distinct structures of the first unsupported entries, without values.
    public let unsupportedShapes: [String]
    public init(cursor: DiffCursor, modifiedItemIDs: [Int64], deletedItemIDs: [Int64], mergedItemIDs: [Int64] = [],
                hasNext: Bool = false, hasUnsupportedActivity: Bool = false, unsupportedCounts: [String: Int] = [:],
                unsupportedShapes: [String] = []) {
        self.cursor = cursor; self.modifiedItemIDs = modifiedItemIDs; self.deletedItemIDs = deletedItemIDs
        self.mergedItemIDs = mergedItemIDs
        self.hasNext = hasNext; self.hasUnsupportedActivity = hasUnsupportedActivity || !unsupportedCounts.isEmpty
        self.unsupportedCounts = unsupportedCounts; self.unsupportedShapes = unsupportedShapes
    }
    /// A one-line description for diagnostics; it contains counts only, no item IDs.
    public var summary: String {
        let overlap = Set(modifiedItemIDs).intersection(deletedItemIDs).count
            + Set(mergedItemIDs).intersection(modifiedItemIDs + deletedItemIDs).count
        let unsupported = unsupportedCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "modify=\(modifiedItemIDs.count) delete=\(deletedItemIDs.count) merge=\(mergedItemIDs.count) overlap=\(overlap) hasNext=\(hasNext) unsupported=[\(unsupported)]"
            + (unsupportedShapes.isEmpty ? "" : " shapes=[\(unsupportedShapes.joined(separator: "; "))]")
    }
    public var isEmpty: Bool {
        modifiedItemIDs.isEmpty && deletedItemIDs.isEmpty && mergedItemIDs.isEmpty && !hasNext && !hasUnsupportedActivity
    }
    public var isBoundedTerminal: Bool {
        let all = modifiedItemIDs + deletedItemIDs + mergedItemIDs
        return !hasNext && !hasUnsupportedActivity && all.count <= 2000 && Set(all).count == all.count
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
    /// Counts of the event types that make `hasUnsupportedActivity` true.
    public let unsupportedEventTypes: [String: Int]
    public init(cursor: DiffCursor, favorites: [FavoriteEvent], hasNext: Bool = false, hasUnsupportedActivity: Bool = false,
                unsupportedEventTypes: [String: Int] = [:]) {
        self.cursor = cursor; self.favorites = favorites; self.hasNext = hasNext
        self.hasUnsupportedActivity = hasUnsupportedActivity || !unsupportedEventTypes.isEmpty
        self.unsupportedEventTypes = unsupportedEventTypes
    }
    /// A one-line description for diagnostics; it contains counts only, no item IDs.
    public var summary: String {
        let unsupported = unsupportedEventTypes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "favorites=\(favorites.reduce(0) { $0 + $1.itemIDs.count }) hasNext=\(hasNext) unsupported=[\(unsupported)]"
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
        var unsupported: [String: Int] = [:]
        for event in try container.decode([Event].self, forKey: .list) {
            switch (event.eventType, event.targetIDs) {
            case ("favorite_add", let ids?): favorites.append(.init(itemIDs: ids, favorite: true))
            case ("favorite_delete", let ids?): favorites.append(.init(itemIDs: ids, favorite: false))
            default: unsupported[event.eventType, default: 0] += 1
            }
        }
        value = UserEventDiff(cursor: DiffCursor(diffVersion: try container.decode(Int64.self, forKey: .diffVersion),
                                                 versionTime: try container.decode(Int64.self, forKey: .versionTime)),
                              favorites: favorites, hasNext: try container.decode(Bool.self, forKey: .hasNext),
                              unsupportedEventTypes: unsupported)
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
                          mergedItemIDs: item.mergedIDs ?? [],
                          hasNext: try container.decode(Bool.self, forKey: .hasNext),
                          unsupportedCounts: ["merge": item.mergedIDs == nil ? item.merge.count : 0, "move": item.move.count,
                                              "similar": similar.count].filter { $0.value > 0 },
                          unsupportedShapes: Self.shapes(item: item, similar: similar))
    }
    private static func shapes(item: ItemChanges, similar: [OpaqueChange]) -> [String] {
        let modified = Set(item.modify.map(\.id)), deleted = Set(item.delete)
        let merges = item.mergedIDs == nil ? item.merge : []
        let entries = merges.map { ("merge", $0) } + item.move.map { ("move", $0) } + similar.map { ("similar", $0) }
        var seen: [String] = []
        for (category, entry) in entries.prefix(20) {
            let description = entry.describe(category, modified: modified, deleted: deleted)
            if !seen.contains(description) { seen.append(description) }
        }
        return seen
    }
}
private struct ItemChanges: Decodable {
    let modify: [ItemModify]
    let delete: [Int64]
    let merge: [OpaqueChange]
    let move: [OpaqueChange]
    /// The merge entries as item IDs when every entry is a bare integer, the only observed shape.
    var mergedIDs: [Int64]? {
        merge.allSatisfy { $0.shape == "int" } ? merge.flatMap(\.integers) : nil
    }
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
/// An activity entry the reconciler does not apply. It keeps only the entry's structure
/// (key names and value types) and its integer leaves, for diagnostics.
private struct OpaqueChange: Decodable {
    let shape: String
    let integers: [Int64]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { shape = "null"; integers = []; return }
        if let object = try? container.decode([String: OpaqueChange].self) {
            let fields = object.sorted { $0.key < $1.key }
            shape = "{" + fields.map { "\($0.key):\($0.value.shape)" }.joined(separator: ",") + "}"
            integers = fields.flatMap(\.value.integers); return
        }
        if let array = try? container.decode([OpaqueChange].self) {
            shape = "[\(array.count)x\(array.first?.shape ?? "")]"; integers = array.flatMap(\.integers); return
        }
        if (try? container.decode(String.self)) != nil { shape = "string"; integers = []; return }
        if let number = try? container.decode(Int64.self) { shape = "int"; integers = [number]; return }
        if (try? container.decode(Double.self)) != nil { shape = "number"; integers = []; return }
        if (try? container.decode(Bool.self)) != nil { shape = "bool"; integers = []; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid activity value")
    }
    /// The structure plus how many integer leaves name an item modified or deleted in the same interval.
    func describe(_ category: String, modified: Set<Int64>, deleted: Set<Int64>) -> String {
        "\(category) \(shape) ints=\(integers.count) inModify=\(integers.filter(modified.contains).count) inDelete=\(integers.filter(deleted.contains).count)"
    }
}
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}
