import Foundation

public struct ThumbnailResponse: Sendable {
    public let data: Data?
    public let etag: String?
    public let lastModified: String?
    public var notModified: Bool { data == nil }

    public init(data: Data?, etag: String?, lastModified: String?) {
        self.data = data
        self.etag = etag
        self.lastModified = lastModified
    }
}

public struct FullImageResponse: Sendable {
    public let data: Data?
    public let etag: String?
    public let lastModified: String?
    public var notModified: Bool { data == nil }

    public init(data: Data?, etag: String?, lastModified: String?) {
        self.data = data
        self.etag = etag
        self.lastModified = lastModified
    }
}

public protocol PhotosTransport: Sendable {
    func login(credentials: SynologyCredentials) async throws
    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot
    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem]
    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse
}
