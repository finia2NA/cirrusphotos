import Foundation
import SynologyAPI

private struct UnexpectedTransportCall: Error {}

extension PhotosTransport {
    func login(credentials: SynologyCredentials) async throws {}

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        throw UnexpectedTransportCall()
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        throw UnexpectedTransportCall()
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        throw UnexpectedTransportCall()
    }

    func thumbnail(
        _ descriptor: ThumbnailInfo,
        size: ThumbnailSize,
        etag: String?,
        lastModified: String?
    ) async throws -> ThumbnailResponse {
        throw UnexpectedTransportCall()
    }

    func fullImage(
        _ resource: FullImageResource,
        etag: String?,
        lastModified: String?
    ) async throws -> FullImageResponse {
        throw UnexpectedTransportCall()
    }
}
