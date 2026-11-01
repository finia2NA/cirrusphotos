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

public struct VideoRangeResponse: Sendable, Equatable {
    public let data: Data
    public let range: ClosedRange<Int64>
    public let totalLength: Int64
    public let contentType: String
    public let etag: String?
    public let lastModified: String?

    public init(data: Data, range: ClosedRange<Int64>, totalLength: Int64,
                contentType: String, etag: String?, lastModified: String?) {
        self.data = data
        self.range = range
        self.totalLength = totalLength
        self.contentType = contentType
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

public struct TransferProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    public var fractionCompleted: Double? {
        guard let totalBytes else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public enum PhotoDownloadKind: String, Sendable {
    case original = "source"
    case compressedJPEG = "optimized_jpeg"
}

public struct PhotoDownloadResponse: Sendable {
    public let temporaryURL: URL
    public let filename: String
    public init(temporaryURL: URL, filename: String) {
        self.temporaryURL = temporaryURL
        self.filename = filename
    }
}

public protocol PhotosTransport: Sendable {
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse
    func login(credentials: SynologyCredentials) async throws
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry]
    func albums() async throws -> [AlbumSummary]
    func addableAlbums() async throws -> [AlbumSummary]
    func album(id: Int64) async throws -> AlbumSummary
    func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary
    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws
    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws

    /// One page of the whole-library location scan: `Browse.Item` list v7 with no
    /// date bounds, `additional` from `PhotosRequestFields.locationScanAdditional`.
    /// Returns at most `limit` items newest-first; an empty or short page ends the scan.
    func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem]
    func diffVersion() async throws -> DiffCursor
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws
    func items(ids: [Int64]) async throws -> [PhotoItem]
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws
    func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit]
    func restoreFromRegenerating(unitIDs: [Int64]) async throws
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles) async throws
    func uploadConvertedThumbnails(
        unitID: Int64, files: ConvertedThumbnailFiles,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                   etag: String?, lastModified: String?) async throws -> ThumbnailResponse
    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse
    func fullImage(
        _ resource: FullImageResource, etag: String?, lastModified: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> FullImageResponse
    func livePhotoMotion(itemID: Int64) async throws -> VideoPlaybackResource?
    func videoRange(_ resource: VideoPlaybackResource,
                    range: ClosedRange<Int64>) async throws -> VideoRangeResponse
}

public extension PhotosTransport {
    func addableAlbums() async throws -> [AlbumSummary] { throw SynologyAPIError.unsupported("Addable album listing is unavailable.") }
    func album(id: Int64) async throws -> AlbumSummary { throw SynologyAPIError.unsupported("Album lookup is unavailable.") }
    func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary { throw SynologyAPIError.unsupported("Album creation is unavailable.") }
    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws { throw SynologyAPIError.unsupported("Album membership changes are unavailable.") }
    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws { throw SynologyAPIError.unsupported("Album membership changes are unavailable.") }

    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        throw SynologyAPIError.unsupported("Photo downloads are unavailable.")
    }

    func uploadConvertedThumbnails(
        unitID: Int64, files: ConvertedThumbnailFiles,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try await uploadConvertedThumbnails(unitID: unitID, files: files)
    }

    func fullImage(
        _ resource: FullImageResource, etag: String?, lastModified: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> FullImageResponse {
        try await fullImage(resource, etag: etag, lastModified: lastModified)
    }

    func livePhotoMotion(itemID: Int64) async throws -> VideoPlaybackResource? {
        throw SynologyAPIError.unsupported("Live Photo motion transport is unavailable.")
    }

    func videoRange(_ resource: VideoPlaybackResource,
                    range: ClosedRange<Int64>) async throws -> VideoRangeResponse {
        throw SynologyAPIError.unsupported("Video range transport is unavailable.")
    }
}
