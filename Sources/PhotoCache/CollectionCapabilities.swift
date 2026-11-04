import SynologyAPI

/// What the app may do with the items of a displayed collection, decided from
/// the collection that owns them (a filter or Map result resolves to its source).
/// Item actions still verify their selection and member origin when they run.
public struct CollectionCapabilities: Equatable, Sendable {
    public let source: PhotoCollectionDescriptor
    /// Whether a recipient holds a verified download grant for an incoming album.
    public let incomingDownloadGranted: Bool

    public init(source: PhotoCollectionDescriptor, incomingDownloadGranted: Bool = false) {
        self.source = source
        self.incomingDownloadGranted = incomingDownloadGranted
    }

    /// Grants downloads from an incoming album only when a verified album list
    /// reports a download grant for exactly that album.
    public init(source: PhotoCollectionDescriptor, incomingAlbums: [AlbumSummary], incomingAlbumsVerified: Bool) {
        self.init(source: source, incomingDownloadGranted: incomingAlbumsVerified &&
            incomingAlbums.contains { $0.collection == source && $0.recipientCanDownload })
    }

    public var isIncoming: Bool { source.incomingAlbumIdentity != nil }
    public var isShared: Bool { source.space == .shared }
    public var sourceAlbumID: Int64? { source.albumID }

    /// Favorites, rotation, deletion and file drags, which act in the item's own space.
    public var allowsSpaceItemActions: Bool { !isIncoming && !source.isLibraryFilter }

    /// Adding to and creating owned albums from the collection's items, in either
    /// space. Owned albums qualify because their members' origin is verified when
    /// the action runs. Contributing to incoming albums stays Personal-only.
    public var allowsAlbumMembership: Bool {
        guard !source.isSessionDerived else { return false }
        switch source.contentScope {
        case .space, .album: return true
        case .incomingAlbum: return false
        }
    }

    /// Editor handoff and contribution to incoming albums. Owned albums qualify
    /// because their members' origin is verified when the action runs.
    public var allowsPersonalActions: Bool {
        guard !source.isSessionDerived else { return false }
        switch source.contentScope {
        case .space(.personal), .album: return true
        case .space(.shared), .incomingAlbum: return false
        }
    }

    public var allowsDownloads: Bool { !isIncoming || incomingDownloadGranted }
}
