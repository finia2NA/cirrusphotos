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
    let namespace: String
    let runID = UUID().uuidString
    let gate = NetworkGate()
    let fullImageGate = FullImageGate()
    var authenticationState = RepositoryAuthenticationState()
    var metadata = RepositoryMetadataWork()
    var imageWork = RepositoryImageWork()
    var favorites = RepositoryFavoriteState()

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
        store = try DiskCache(root: root, budget: budget,
                              protectedTimelineKey: CacheKey.timeline(namespace: namespace))
    }

    public func setBudget(_ bytes: Int64) async throws { try await store.setBudget(bytes) }

    public func usage() async throws -> Int64 { try await store.usage() }

    public func clearCache() async throws { try await store.clear() }

    func cancelIdleLogin() {
        guard !metadata.hasDemand && !imageWork.hasDemand else { return }
        authenticationState.cancelIfUnconnected()
    }
}
