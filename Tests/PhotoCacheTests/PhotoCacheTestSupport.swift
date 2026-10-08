import Foundation
import SynologyAPI

struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String = "Unexpected test transport call") {
        self.message = message
    }

    var errorDescription: String? { message }
}

func temporaryTestRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

func waitUntil(
    attempts: Int = 300,
    interval: Duration = .milliseconds(3),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        try? await Task.sleep(for: interval)
    }
    return false
}

extension PhotosTransport {
    func login(credentials: SynologyCredentials) async throws {}

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        throw TestFailure("Unexpected timeline request")
    }

    func albums() async throws -> [AlbumSummary] {
        throw TestFailure("Unexpected album-list request")
    }

    func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot {
        throw TestFailure("Unexpected album-timeline request")
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        throw TestFailure("Unexpected item-page request")
    }

    func locationScanPage(offset: Int, limit: Int) async throws -> [PhotoItem] {
        throw TestFailure("Unexpected location-scan request")
    }

    func diffVersion() async throws -> DiffCursor {
        throw TestFailure("Unexpected Diff version request")
    }

    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        throw TestFailure("Unexpected Diff request")
    }

    func locationItems(ids: [Int64]) async throws -> LocationItemLookup {
        throw TestFailure("Unexpected location lookup")
    }

    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        throw TestFailure("Unexpected favorite write")
    }

    func thumbnail(
        _ descriptor: ThumbnailInfo,
        size: ThumbnailSize,
        etag: String?,
        lastModified: String?
    ) async throws -> ThumbnailResponse {
        throw TestFailure("Unexpected thumbnail request")
    }

    func fullImage(
        _ resource: FullImageResource,
        etag: String?,
        lastModified: String?
    ) async throws -> FullImageResponse {
        throw TestFailure("Unexpected original-image request")
    }
}
