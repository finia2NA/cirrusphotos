import Foundation

/// The two independent NAS item domains. Album sharing is not a third space.
public enum PhotoSpace: String, CaseIterable, Codable, Hashable, Sendable {
    case personal, shared
}

/// An authority within which an item or unit ID is meaningful. An album's
/// unresolved members deliberately remain album-scoped until their origin is
/// established; neither a numeric ID nor owner_user_id proves global identity.
public enum PhotoContentScope: Hashable, Codable, Sendable {
    case space(PhotoSpace)
    case album(Int64)
    case incomingAlbum(ownerID: Int64, albumID: Int64)

    public var cacheComponent: String {
        switch self {
        case .space(let space): space.rawValue
        case .album(let id): "album:\(id)"
        case .incomingAlbum(let owner, let album): "incoming:\(owner):\(album)"
        }
    }

    public var space: PhotoSpace? {
        guard case .space(let space) = self else { return nil }
        return space
    }
}

/// Item IDs and thumbnail unit IDs are different server identities. This type
/// represents only an item ID; resource models retain their separate unit ID.
public struct PhotoItemIdentity: Hashable, Codable, Sendable {
    public let scope: PhotoContentScope
    public let itemID: Int64

    public init(scope: PhotoContentScope, itemID: Int64) {
        self.scope = scope
        self.itemID = itemID
    }
}
