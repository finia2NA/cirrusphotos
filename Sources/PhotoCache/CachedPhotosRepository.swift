import Foundation
import SynologyAPI

/// The single coordination actor for all cached Photos resources.
///
/// State values and resource extensions share this actor's isolation. In particular,
/// metadata mutation epochs and optimistic Favorites changes must stay ordered together;
/// splitting these pipelines into independent actors would weaken that guarantee.
public actor CachedPhotosRepository {
    public let store: DiskCache
    let client: any PhotosTransport
    let credentials: SynologyCredentials
    public nonisolated let namespace: String
    let runID = UUID().uuidString
    let gate = NetworkGate()
    let fullImageGate = FullImageGate()
    let videoTransferGate = VideoTransferGate()
    var authenticationState = RepositoryAuthenticationState()
    var metadata = MetadataEngineState()
    var imageWork = RepositoryImageWork()
    let favorites = RepositoryFavoriteState()
    let sharedFavorites = RepositoryFavoriteState()
    var itemMutations = RepositoryItemMutationState()
    var incomingAccess: [PhotoCollectionDescriptor: IncomingAlbum] = [:]
    var avatars: [AvatarIdentity: Data] = [:]
    var avatarTasks: [AvatarIdentity: AvatarWork] = [:]

    public init(credentials: SynologyCredentials, baseURL: URL = SynologyClient.defaultBaseURL,
                budget: Int64 = CacheBudget.bytes(at: 0.5), cacheRoot: URL? = nil,
                transport: (any PhotosTransport)? = nil) throws {
        self.credentials = credentials
        namespace = CacheKey.namespace(server: baseURL, account: credentials.username)
        client = transport ?? SynologyClient(baseURL: baseURL)
        let root: URL
        if let cacheRoot {
            root = cacheRoot
        } else {
            root = CacheLocation.defaultRoot().appendingPathComponent(namespace, isDirectory: true)
        }
        store = try DiskCache(root: root, budget: budget)
    }

    public func setBudget(_ bytes: Int64) async throws {
        try await store.setBudget(bytes)
        if metadata.initialized, let state = try? await store.metadataState(personalMetadataNamespace), !state.inventoryComplete { metadata.inventoryCurrent = false }
        await publishStoredLocationProjection()
    }

    public func usage() async throws -> Int64 { try await store.usage() }

    func cancelIdleLogin() {
        guard !metadata.hasDemand && !imageWork.hasDemand else { return }
        authenticationState.cancelIfUnconnected()
    }
}
