import Foundation
import SynologyAPI

/// Test transports conform to this instead of `PhotosTransport` and implement only
/// the requests a test exercises. Login succeeds; every other request fails.
public protocol TestPhotosTransport: PhotosTransport {}

public struct UnexpectedTransportCall: LocalizedError {
    public let request: String
    public init(_ request: String) { self.request = request }
    public var errorDescription: String? { "Unexpected test transport call: \(request)" }
}

public extension TestPhotosTransport {
    func uploadPhoto(at url: URL, destination: PhotoUploadDestination, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult {
        throw UnexpectedTransportCall("uploadPhoto")
    }
    func collectionIndex(_ kind: CollectionIndexKind, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        throw UnexpectedTransportCall("collectionIndex")
    }
    func suggestPeople(prefix: String, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        throw UnexpectedTransportCall("suggestPeople")
    }
    func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
        throw UnexpectedTransportCall("renamePerson")
    }
    func mergePerson(sourceID: Int64, targetID: Int64, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
        throw UnexpectedTransportCall("mergePerson")
    }
    func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        throw UnexpectedTransportCall("folder")
    }
    func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] {
        throw UnexpectedTransportCall("folders")
    }
    func readFolderCatalogBatch(folderID: Int64, offset: Int, limit: Int, space: PhotoSpace) async throws -> [DayTimelineEntry] {
        throw UnexpectedTransportCall("readFolderCatalogBatch")
    }
    func downloadIncomingPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, reference: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        throw UnexpectedTransportCall("downloadIncomingPhotos")
    }
    func login(credentials: SynologyCredentials) async throws {}
    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        throw UnexpectedTransportCall("collectionDayCatalog")
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        throw UnexpectedTransportCall("readCollectionBatch")
    }
    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        throw UnexpectedTransportCall("readAlbumCatalogBatch")
    }
    func userProfiles(ids: [Int64]) async throws -> [PhotosUserProfile] {
        throw UnexpectedTransportCall("userProfiles")
    }
    func profilePhoto(descriptor: String) async throws -> Data {
        throw UnexpectedTransportCall("profilePhoto")
    }
    func albums() async throws -> [AlbumSummary] {
        throw UnexpectedTransportCall("albums")
    }
    func incomingAlbums() async throws -> [IncomingAlbum] {
        throw UnexpectedTransportCall("incomingAlbums")
    }
    func readIncomingAlbumCatalogBatch(reference: String, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        throw UnexpectedTransportCall("readIncomingAlbumCatalogBatch")
    }
    func readIncomingCollectionBatch(_ request: CollectionPageRequest, reference: String, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        throw UnexpectedTransportCall("readIncomingCollectionBatch")
    }
    func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] {
        throw UnexpectedTransportCall("albumItems")
    }
    func incomingItems(ids: [Int64], reference: String) async throws -> [PhotoItem] {
        throw UnexpectedTransportCall("incomingItems")
    }
    func albumThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64, etag: String?, lastModified: String?) async throws -> MediaResponse {
        throw UnexpectedTransportCall("albumThumbnail")
    }
    func incomingThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, reference: String, etag: String?, lastModified: String?) async throws -> MediaResponse {
        throw UnexpectedTransportCall("incomingThumbnail")
    }
    func addItems(_ itemIDs: [Int64], toSharedAlbumReference reference: String) async throws {
        throw UnexpectedTransportCall("addItems")
    }
    func addableAlbums() async throws -> [AlbumSummary] {
        throw UnexpectedTransportCall("addableAlbums")
    }
    func album(id: Int64) async throws -> AlbumSummary {
        throw UnexpectedTransportCall("album")
    }
    func currentPhotosUserID() async throws -> Int64 {
        throw UnexpectedTransportCall("currentPhotosUserID")
    }
    func sharingPrincipals() async throws -> [SharingPrincipal] {
        throw UnexpectedTransportCall("sharingPrincipals")
    }
    func setAlbumShared(id: Int64, enabled: Bool) async throws -> AlbumSharingReference {
        throw UnexpectedTransportCall("setAlbumShared")
    }
    func updateAlbumSharing(reference: String, changes: [SharingPermissionChange], password: SharingPasswordChange, expiration: Int64?) async throws {
        throw UnexpectedTransportCall("updateAlbumSharing")
    }
    func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary {
        throw UnexpectedTransportCall("createAlbum")
    }
    func deleteAlbum(id: Int64) async throws {
        throw UnexpectedTransportCall("deleteAlbum")
    }
    func renameAlbum(id: Int64, name: String) async throws {
        throw UnexpectedTransportCall("renameAlbum")
    }
    func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws {
        throw UnexpectedTransportCall("addItems")
    }
    func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws {
        throw UnexpectedTransportCall("removeItems")
    }
    func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem] {
        throw UnexpectedTransportCall("readPersonalInventoryBatch")
    }
    func diffVersion() async throws -> DiffCursor {
        // Unsupported Diff versions make the repository fall back to authoritative reads.
        throw SynologyAPIError.api(103)
    }
    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        throw UnexpectedTransportCall("changes")
    }
    func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        throw UnexpectedTransportCall("items")
    }
    func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace, etag: String?, lastModified: String?) async throws -> MediaResponse {
        throw UnexpectedTransportCall("thumbnail")
    }
    func setRegenerating(itemIDs: [Int64], space: PhotoSpace) async throws -> [RegeneratingThumbnailUnit] {
        throw UnexpectedTransportCall("setRegenerating")
    }
    func restoreFromRegenerating(unitIDs: [Int64], space: PhotoSpace) async throws {
        throw UnexpectedTransportCall("restoreFromRegenerating")
    }
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles, space: PhotoSpace, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        throw UnexpectedTransportCall("uploadConvertedThumbnails")
    }
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?) async throws -> MediaResponse {
        throw UnexpectedTransportCall("fullImage")
    }
    func fullImage(_ resource: FullImageResource, etag: String?, lastModified: String?, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> MediaResponse {
        try await fullImage(resource, etag: etag, lastModified: lastModified)
    }
    func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>, receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws {
        throw UnexpectedTransportCall("streamVideoRange")
    }
    func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {
        throw UnexpectedTransportCall("setFavorite")
    }
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection, space: PhotoSpace) async throws {
        throw UnexpectedTransportCall("rotate")
    }
    func deleteItems(_ itemIDs: [Int64], space: PhotoSpace) async throws {
        throw UnexpectedTransportCall("deleteItems")
    }
    func livePhotoMotion(itemID: Int64, space: PhotoSpace) async throws -> VideoPlaybackResource? {
        throw UnexpectedTransportCall("livePhotoMotion")
    }
    func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, space: PhotoSpace, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        throw UnexpectedTransportCall("downloadPhotos")
    }
}
