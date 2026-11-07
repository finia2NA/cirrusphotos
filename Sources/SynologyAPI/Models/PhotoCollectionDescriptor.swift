import Foundation

/// Persistent NAS collections retain their space or contextual album authority.
/// Session collections carry their source authority even after registration ends.
public enum PhotoCollectionDescriptor: Codable, Hashable, Sendable {
    case library(PhotoSpace)
    case favorites(PhotoSpace)
    case recentlyAdded
    case album(Int64)
    case incomingAlbum(ownerID: Int64, albumID: Int64)
    case folder(Int64, space: PhotoSpace)
    case person(Int64, space: PhotoSpace)
    case subject(Int64, space: PhotoSpace)
    case tag(Int64, space: PhotoSpace)
    case mapFilter(UUID, space: PhotoSpace)
    case libraryFilter(UUID, scope: PhotoContentScope)

    public var rawValue: String {
        let prefix = space == .shared ? "shared:" : ""
        switch self {
        case .library(let space): return space == .personal ? "personal" : "shared"
        case .favorites: return prefix + "favorites"
        case .recentlyAdded: return "recently-added"
        case .album(let id): return "album:\(id)"
        case .incomingAlbum(let owner, let id): return "incoming:\(owner):\(id)"
        case .folder(let id, _): return prefix + "folder:\(id)"
        case .person(let id, _): return prefix + "person:\(id)"
        case .subject(let id, _): return prefix + "subject:\(id)"
        case .tag(let id, _): return prefix + "tag:\(id)"
        case .mapFilter(let id, let space): return "map:\(space.rawValue):\(id.uuidString)"
        case .libraryFilter(let id, let scope): return "filter:\(scope.cacheComponent):\(id.uuidString)"
        }
    }

    /// Album authority deliberately does not imply an item origin space.
    public var space: PhotoSpace? { contentScope.space }
    public var contentScope: PhotoContentScope {
        switch self {
        case .library(let space), .favorites(let space), .folder(_, let space), .person(_, let space),
             .subject(_, let space), .tag(_, let space), .mapFilter(_, let space): return .space(space)
        case .recentlyAdded: return .space(.personal)
        case .album(let id): return .album(id)
        case .incomingAlbum(let owner, let id): return .incomingAlbum(ownerID: owner, albumID: id)
        case .libraryFilter(_, let scope): return scope
        }
    }

    public var albumID: Int64? { if case .album(let id) = self { return id }; return nil }
    public var incomingAlbumIdentity: (ownerID: Int64, albumID: Int64)? {
        if case .incomingAlbum(let owner, let id) = self { return (owner, id) }; return nil
    }
    public var folderID: Int64? { if case .folder(let id, _) = self { return id }; return nil }
    public var personID: Int64? { if case .person(let id, _) = self { return id }; return nil }
    public var subjectID: Int64? { if case .subject(let id, _) = self { return id }; return nil }
    public var tagID: Int64? { if case .tag(let id, _) = self { return id }; return nil }
    public var mapFilterID: UUID? { if case .mapFilter(let id, _) = self { return id }; return nil }
    public var libraryFilterID: UUID? { if case .libraryFilter(let id, _) = self { return id }; return nil }
    public var usesItemCatalog: Bool { albumID != nil || incomingAlbumIdentity != nil || folderID != nil }
    public var isMapFilter: Bool { mapFilterID != nil }
    public var isLibraryFilter: Bool { libraryFilterID != nil }
    public var isSessionDerived: Bool { isMapFilter || isLibraryFilter }
    public var favoriteOnly: Bool { if case .favorites = self { return true }; return false }
    public var supportsInitialTimeline: Bool { self == .library(.personal) }
    public func membershipTime(for item: PhotoItem) -> Int64? {
        self == .recentlyAdded ? item.indexedTime.map { $0 / 1000 } : item.time
    }

    /// Explicit startup policy; this is not an enumeration of all collections.
    public static var bootstrapCollections: [Self] { [.library(.personal), .favorites(.personal)] }

    public init?(rawValue: String) {
        if rawValue == "personal" { self = .library(.personal); return }
        if rawValue == "shared" { self = .library(.shared); return }
        if rawValue == "recently-added" { self = .recentlyAdded; return }
        let parts = rawValue.split(separator: ":")
        let shared = parts.first == "shared"
        let tokens = shared ? Array(parts.dropFirst()) : parts
        let space: PhotoSpace = shared ? .shared : .personal
        if tokens == ["favorites"] { self = .favorites(space); return }
        if tokens.count == 2, let id = Int64(tokens[1]), id > 0 {
            switch tokens[0] {
            case "folder": self = .folder(id, space: space)
            case "person": self = .person(id, space: space)
            case "subject": self = .subject(id, space: space)
            case "tag": self = .tag(id, space: space)
            case "album" where !shared: self = .album(id)
            default: return nil
            }
            return
        }
        if !shared, tokens.count == 3, tokens[0] == "incoming", let owner = Int64(tokens[1]), let id = Int64(tokens[2]) {
            self = .incomingAlbum(ownerID: owner, albumID: id); return
        }
        if parts.count == 3, parts[0] == "map", let space = PhotoSpace(rawValue: String(parts[1])), let id = UUID(uuidString: String(parts[2])) {
            self = .mapFilter(id, space: space); return
        }
        if parts.first == "filter", let last = parts.last, let id = UUID(uuidString: String(last)),
           let scope = PhotoContentScope(cacheComponent: parts.dropFirst().dropLast().joined(separator: ":")) {
            self = .libraryFilter(id, scope: scope); return
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let descriptor = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown collection descriptor")
        }
        self = descriptor
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
