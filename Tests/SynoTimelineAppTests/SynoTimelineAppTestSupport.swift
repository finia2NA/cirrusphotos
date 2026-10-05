import Foundation
import SynologyAPI

func temporaryTestRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

@MainActor
func waitUntil(
    attempts: Int = 500,
    interval: Duration = .milliseconds(3),
    _ predicate: @escaping @MainActor @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        try? await Task.sleep(for: interval)
    }
    return false
}

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
