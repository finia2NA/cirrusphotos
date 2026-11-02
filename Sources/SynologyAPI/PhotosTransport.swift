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

public struct VideoRangeHeader: Sendable, Equatable {
    public let range: ClosedRange<Int64>
    public let totalLength: Int64
    public let contentType: String
    public let etag: String?
    public let lastModified: String?

    public init(range: ClosedRange<Int64>, totalLength: Int64, contentType: String,
                etag: String?, lastModified: String?) {
        self.range = range
        self.totalLength = totalLength
        self.contentType = contentType
        self.etag = etag
        self.lastModified = lastModified
    }
}

public enum VideoRangeEvent: Sendable {
    case header(VideoRangeHeader)
    case bytes(offset: Int64, data: Data)
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

public enum PhotoUploadDestination: Sendable {
    case timeline(PhotoSpace)
    case album(Int64)
}

public struct PhotoUploadResult: Sendable, Decodable {
    public let action: String
    public let id: Int64
    public let unitID: Int64
    enum CodingKeys: String, CodingKey { case action, id; case unitID = "unit_id" }
}

public protocol PhotosTransport: Sendable {
    func uploadPhoto(at url: URL, destination: PhotoUploadDestination, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult
    func people(space: PhotoSpace) async throws -> [PersonSummary]
    func suggestPeople(prefix: String, space: PhotoSpace) async throws -> [PersonSummary]
    func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws -> PersonSummary
    func mergePerson(sourceID: Int64, targetID: Int64, name: String, space: PhotoSpace) async throws -> PersonSummary
    func subjects(space: PhotoSpace) async throws -> [SubjectSummary]
    func tags(space: PhotoSpace) async throws -> [TagSummary]
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary]
    func readFolderCatalogBatch(folderID: Int64, offset: Int, limit: Int, space: PhotoSpace) async throws -> [DayTimelineEntry]

    func downloadIncomingPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, reference: String,
                                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse
    func login(credentials: SynologyCredentials) async throws
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry]

    func userProfiles(ids: [Int64]) async throws -> [PhotosUserProfile]
    func profilePhoto(descriptor: String) async throws -> Data
    func albums() async throws -> [AlbumSummary]
    func incomingAlbums() async throws -> [IncomingAlbum]
    func readIncomingAlbumCatalogBatch(reference: String, offset: Int, limit: Int) async throws -> [DayTimelineEntry]
    func readIncomingCollectionBatch(_ request: CollectionPageRequest, reference: String, fields: ItemFieldProfile) async throws -> CollectionBatchResult
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem]
    func incomingItems(ids: [Int64], reference: String) async throws -> [PhotoItem]
    func albumThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64,
                        etag: String?, lastModified: String?) async throws -> ThumbnailResponse
    func incomingThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, reference: String,
                           etag: String?, lastModified: String?) async throws -> ThumbnailResponse
    func addItems(_ itemIDs: [Int64], toSharedAlbumReference reference: String) async throws
    func addableAlbums() async throws -> [AlbumSummary]
    func album(id: Int64) async throws -> AlbumSummary
    func currentPhotosUserID() async throws -> Int64
    func sharingPrincipals() async throws -> [SharingPrincipal]
    func setAlbumShared(id: Int64, enabled: Bool) async throws -> AlbumSharingReference
    func updateAlbumSharing(reference: String, changes: [SharingPermissionChange], password: SharingPasswordChange, expiration: Int64?) async throws
    func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary
    func deleteAlbum(id: Int64) async throws
    func renameAlbum(id: Int64, name: String) async throws
    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws
    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws

    /// One page of the whole-library location scan: `Browse.Item` list v7 with no
    /// date bounds, `additional` from `PhotosRequestFields.locationScanAdditional`.
    /// Returns at most `limit` items newest-first; an empty or short page ends the scan.
    func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem]
    func diffVersion() async throws -> DiffCursor
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff

    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem]
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse

    func setRegenerating(itemIDs: [Int64], space: PhotoSpace) async throws -> [RegeneratingThumbnailUnit]
    func restoreFromRegenerating(unitIDs: [Int64], space: PhotoSpace) async throws
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles, space: PhotoSpace,
                                   progress: @escaping @Sendable (TransferProgress) -> Void) async throws

    func fullImage(_ resource: FullImageResource,
                   etag: String?, lastModified: String?) async throws -> FullImageResponse
    func fullImage(
        _ resource: FullImageResource, etag: String?, lastModified: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> FullImageResponse

    func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>,
                          receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws
    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection, space: PhotoSpace) async throws
    func livePhotoMotion(itemID: Int64, space: PhotoSpace) async throws -> VideoPlaybackResource?
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, space: PhotoSpace,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse

}

public extension PhotosTransport {
    func uploadPhoto(at url: URL, destination: PhotoUploadDestination, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult {
        throw SynologyAPIError.unsupported("Photo uploads are unavailable.")
    }
    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {
        throw SynologyAPIError.unsupported("Favorite changes are unavailable.")
    }
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection, space: PhotoSpace) async throws {
        throw SynologyAPIError.unsupported("Photo rotation is unavailable.")
    }
    func livePhotoMotion(itemID: Int64, space: PhotoSpace) async throws -> VideoPlaybackResource? {
        throw SynologyAPIError.unsupported("Live Photo motion is unavailable.")
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, space: PhotoSpace,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        throw SynologyAPIError.unsupported("Photo downloads are unavailable.")
    }

    func people(space: PhotoSpace) async throws -> [PersonSummary] {
        throw SynologyAPIError.unsupported("People is unavailable.")
    }
    func suggestPeople(prefix: String, space: PhotoSpace) async throws -> [PersonSummary] {
        throw SynologyAPIError.unsupported("People suggestions are unavailable.")
    }
    func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws -> PersonSummary {
        throw SynologyAPIError.unsupported("Renaming people is unavailable.")
    }
    func mergePerson(sourceID: Int64, targetID: Int64, name: String, space: PhotoSpace) async throws -> PersonSummary {
        throw SynologyAPIError.unsupported("Merging people is unavailable.")
    }
    func subjects(space: PhotoSpace) async throws -> [SubjectSummary] {
        throw SynologyAPIError.unsupported("Subjects are unavailable.")
    }
    func tags(space: PhotoSpace) async throws -> [TagSummary] {
        throw SynologyAPIError.unsupported("Tags are unavailable.")
    }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        throw SynologyAPIError.unsupported("Folder lookup is unavailable.")
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] {
        throw SynologyAPIError.unsupported("Folder listing is unavailable.")
    }
    func readFolderCatalogBatch(folderID: Int64, offset: Int, limit: Int, space: PhotoSpace) async throws -> [DayTimelineEntry] {
        throw SynologyAPIError.unsupported("Folder items are unavailable.")
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        throw SynologyAPIError.unsupported("Photo details are unavailable.")
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace, etag: String?, lastModified: String?) async throws -> ThumbnailResponse {
        throw SynologyAPIError.unsupported("Thumbnails are unavailable.")
    }

    func incomingAlbums() async throws -> [IncomingAlbum] { throw SynologyAPIError.unsupported("Incoming albums are unavailable.") }
    func readIncomingAlbumCatalogBatch(reference: String, offset: Int, limit: Int) async throws -> [DayTimelineEntry] { throw SynologyAPIError.unsupported("Incoming albums are unavailable.") }
    func readIncomingCollectionBatch(_ request: CollectionPageRequest, reference: String, fields: ItemFieldProfile) async throws -> CollectionBatchResult { throw SynologyAPIError.unsupported("Incoming albums are unavailable.") }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] { throw SynologyAPIError.unsupported("Album items are unavailable.") }
    func incomingItems(ids: [Int64], reference: String) async throws -> [PhotoItem] { throw SynologyAPIError.unsupported("Incoming album items are unavailable.") }
    func albumThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64, etag: String?, lastModified: String?) async throws -> ThumbnailResponse { throw SynologyAPIError.unsupported("Album thumbnails are unavailable.") }
    func incomingThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, reference: String, etag: String?, lastModified: String?) async throws -> ThumbnailResponse { throw SynologyAPIError.unsupported("Incoming album thumbnails are unavailable.") }
    func addItems(_ itemIDs: [Int64], toSharedAlbumReference reference: String) async throws { throw SynologyAPIError.unsupported("Shared album contribution is unavailable.") }

    func userProfiles(ids: [Int64]) async throws -> [PhotosUserProfile] { throw SynologyAPIError.unsupported("Profiles unavailable.") }
    func profilePhoto(descriptor: String) async throws -> Data { throw SynologyAPIError.unsupported("Profile photos unavailable.") }
    func addableAlbums() async throws -> [AlbumSummary] { throw SynologyAPIError.unsupported("Addable album listing is unavailable.") }
    func album(id: Int64) async throws -> AlbumSummary { throw SynologyAPIError.unsupported("Album lookup is unavailable.") }
    func currentPhotosUserID() async throws -> Int64 { throw SynologyAPIError.unsupported("Current user unavailable.") }
    func sharingPrincipals() async throws -> [SharingPrincipal] { throw SynologyAPIError.unsupported("Sharing users unavailable.") }
    func setAlbumShared(id: Int64, enabled: Bool) async throws -> AlbumSharingReference { throw SynologyAPIError.unsupported("Sharing unavailable.") }
    func updateAlbumSharing(reference: String, changes: [SharingPermissionChange], password: SharingPasswordChange, expiration: Int64?) async throws { throw SynologyAPIError.unsupported("Sharing unavailable.") }
    func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary { throw SynologyAPIError.unsupported("Album creation is unavailable.") }
    func deleteAlbum(id: Int64) async throws { throw SynologyAPIError.unsupported("Album deletion is unavailable.") }
    func renameAlbum(id: Int64, name: String) async throws { throw SynologyAPIError.unsupported("Album renaming is unavailable.") }
    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws { throw SynologyAPIError.unsupported("Album membership changes are unavailable.") }
    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws { throw SynologyAPIError.unsupported("Album membership changes are unavailable.") }

    func downloadIncomingPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, reference: String,
                                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        throw SynologyAPIError.unsupported("Shared album downloads are unavailable.")
    }

    func setRegenerating(itemIDs: [Int64], space: PhotoSpace) async throws -> [RegeneratingThumbnailUnit] { throw SynologyAPIError.unsupported("Thumbnail regeneration unavailable.") }
    func restoreFromRegenerating(unitIDs: [Int64], space: PhotoSpace) async throws { throw SynologyAPIError.unsupported("Thumbnail regeneration unavailable.") }
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles, space: PhotoSpace,
                                   progress: @escaping @Sendable (TransferProgress) -> Void) async throws { throw SynologyAPIError.unsupported("Thumbnail regeneration unavailable.") }

    func fullImage(
        _ resource: FullImageResource, etag: String?, lastModified: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> FullImageResponse {
        try await fullImage(resource, etag: etag, lastModified: lastModified)
    }

    func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>,
                          receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws {
        throw SynologyAPIError.unsupported("Video range transport is unavailable.")
    }
}
