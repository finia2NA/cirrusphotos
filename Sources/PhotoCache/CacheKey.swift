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

    public static func timeline(namespace: String,
                                collection: PhotoCollectionDescriptor = .personalLibrary) -> String {
        digest("\(namespace)|\(collection.rawValue)|timeline|v6|full|day")
    }

    public static func albumList(namespace: String) -> String {
        digest("\(namespace)|album|v4|list|normal|album_name|asc|sharing_info,thumbnail")
    }

    public static func locationIndex(namespace: String) -> String {
        digest("\(namespace)|personal|location-index|v1")
    }

    public static func page(namespace: String, section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary,
                            additional: [String] = PhotosRequestFields.pageAdditional) -> String? {
        guard let bounds = section.dateBounds else { return nil }
        return digest("\(namespace)|\(collection.rawValue)|item|v7|\(bounds.start)|\(bounds.end)|\(section.offset)|\(section.limit)|\(additional.joined(separator: ","))")
    }

    public static func thumbnail(namespace: String, descriptor: ThumbnailInfo,
                                 size: ThumbnailSize) -> String {
        digest("\(namespace)|personal|thumbnail|v2|unit|\(descriptor.unitID)|\(descriptor.cacheKey)|\(size.rawValue)")
    }

    public static func thumbnailIdentity(namespace: String, descriptor: ThumbnailInfo,
                                         size: ThumbnailSize) -> ThumbnailCacheIdentity {
        ThumbnailCacheIdentity(
            key: thumbnail(namespace: namespace, descriptor: descriptor, size: size),
            family: digest("\(namespace)|personal|thumbnail-family|v1|unit|\(descriptor.unitID)|\(descriptor.cacheKey)"),
            size: size
        )
    }

    public static func fullImage(namespace: String, resource: FullImageResource) -> String {
        digest("\(namespace)|personal|download|v2|unit|\(resource.unitID)|\(resource.cacheKey)")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
