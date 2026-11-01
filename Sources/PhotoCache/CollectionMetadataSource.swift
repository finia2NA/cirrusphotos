import SynologyAPI

public enum MetadataSourceID: String, Codable, Sendable { case items }
public enum CollectionMembershipPolicy: Sendable, Equatable {
    case itemInventory
    case authoritativePerRun
    case sessionDerived
}
/// Acquisition policy is data only. The repository engine alone reads source intervals.
public enum CollectionMetadataSource {
    public static func membershipPolicy(for collection: PhotoCollectionDescriptor) -> CollectionMembershipPolicy {
        switch collection {
        case .personalLibrary: .itemInventory
        case .favorites, .album, .incomingAlbum, .folder: .authoritativePerRun
        case .mapFilter, .libraryFilter: .sessionDerived
        }
    }
}
