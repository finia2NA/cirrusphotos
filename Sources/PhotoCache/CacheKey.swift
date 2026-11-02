import CryptoKit
import Foundation
import SynologyAPI

/// Exact identity of one cached thumbnail rendition and its rendition family.
public struct ThumbnailCacheIdentity: Sendable, Equatable {
    public let key: String
    public let family: String
    public let size: ThumbnailSize

    public init(key: String, family: String, size: ThumbnailSize) {
        self.key = key
        self.family = family
        self.size = size
    }
}

/// Central construction for semantic cache keys. Callers describe the resource;
/// storage receives only the resulting opaque key.
public enum CacheKey {
    public static func namespace(server: URL, account: String) -> String {
        digest("cirrus-cache-v1|\(server.absoluteString.lowercased())|\(account)")
    }

    public static func page(scope: PhotoContentScope, namespace: String, section: TimelineSection,
                            collection: PhotoCollectionDescriptor) -> String? {
        guard let address = try? DayPageAddress(section: section, collection: collection) else { return nil }
        return digest("\(namespace)|\(scope.cacheComponent)|\(collection.rawValue)|day-page|\(address.day.id)|\(address.offset)|\(address.capacity)|\(address.order.rawValue)")
    }

    public static func thumbnail(scope: PhotoContentScope, namespace: String, descriptor: ThumbnailInfo,
                                 size: ThumbnailSize, collection: PhotoCollectionDescriptor) -> String {
        let authority = collection.incomingAlbumIdentity != nil || collection.albumID != nil || collection.isLibraryFilter ? collection.rawValue + "|" + scope.cacheComponent : scope.cacheComponent
        return digest("\(namespace)|\(authority)|thumbnail|v2|\(descriptor.kind ?? "unit")|\(descriptor.unitID)|\(descriptor.cacheKey)|\(size.rawValue)")
    }

    public static func thumbnailIdentity(scope: PhotoContentScope, namespace: String, descriptor: ThumbnailInfo,
                                         size: ThumbnailSize, collection: PhotoCollectionDescriptor) -> ThumbnailCacheIdentity {
        let authority = collection.incomingAlbumIdentity != nil || collection.albumID != nil || collection.isLibraryFilter ? collection.rawValue + "|" + scope.cacheComponent : scope.cacheComponent
        return ThumbnailCacheIdentity(
            key: thumbnail(scope: scope, namespace: namespace, descriptor: descriptor, size: size, collection: collection),
            family: digest("\(namespace)|\(authority)|thumbnail-family|v1|\(descriptor.kind ?? "unit")|\(descriptor.unitID)|\(descriptor.cacheKey)"),
            size: size
        )
    }

    public static func fullImage(namespace: String, resource: FullImageResource) -> String {
        digest("\(namespace)|\(resource.scope.cacheComponent)|download|v2|unit|\(resource.unitID)|\(resource.cacheKey)")
    }

    public static func videoSegment(namespace: String, resource: VideoPlaybackResource,
                                    index: Int64) -> String {
        digest("\(namespace)|\(resource.scope.cacheComponent)|video|v3|segment-65536|unit|\(resource.unitID)|\(resource.cacheKey)|\(resource.variant.cacheComponent)|segment|\(index)")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
