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

public enum PhotoRotationDirection: String, Codable, Sendable, CaseIterable {
    case clockwise
    case counterClockwise = "counter_clockwise"
}

public struct RegeneratingThumbnailUnit: Sendable, Equatable {
    public let itemID: Int64?
    public let unitID: Int64

    public init(itemID: Int64? = nil, unitID: Int64) {
        self.itemID = itemID
        self.unitID = unitID
    }
}

public struct ConvertedThumbnailFiles: Sendable, Equatable {
    public let sm: Data
    public let m: Data
    public let xl: Data

    public init(sm: Data, m: Data, xl: Data) {
        self.sm = sm
        self.m = m
        self.xl = xl
    }
}

public protocol PhotosTransport: Sendable {
    func login(credentials: SynologyCredentials) async throws
    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot
    func albums() async throws -> [AlbumSummary]
    func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot
    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem]

    /// One page of the whole-library location scan: `Browse.Item` list v7 with no
    /// date bounds, `additional` from `PhotosRequestFields.locationScanAdditional`.
    /// Returns at most `limit` items newest-first; an empty or short page ends the scan.
    func locationScanPage(offset: Int, limit: Int) async throws -> [PhotoItem]
    func diffVersion() async throws -> DiffCursor
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff
    func locationItems(ids: [Int64]) async throws -> LocationItemLookup

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws
    func items(ids: [Int64]) async throws -> [PhotoItem]
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws
    func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit]
    func restoreFromRegenerating(unitIDs: [Int64]) async throws
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles) async throws
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse
}
