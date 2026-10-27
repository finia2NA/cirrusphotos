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

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        throw UnexpectedTransportCall()
    }

    func albums() async throws -> [AlbumSummary] {
        throw UnexpectedTransportCall()
    }

    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        throw UnexpectedTransportCall()
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        throw UnexpectedTransportCall()
    }

    func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem] {
        throw UnexpectedTransportCall()
    }

    func diffVersion() async throws -> DiffCursor {
        throw SynologyAPIError.api(103)
    }

    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        throw UnexpectedTransportCall()
    }


    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        throw UnexpectedTransportCall()
    }

    func items(ids: [Int64]) async throws -> [PhotoItem] { throw UnexpectedTransportCall() }
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws { throw UnexpectedTransportCall() }
    func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit] { throw UnexpectedTransportCall() }
    func restoreFromRegenerating(unitIDs: [Int64]) async throws { throw UnexpectedTransportCall() }
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles) async throws { throw UnexpectedTransportCall() }

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

func fixtureDayCatalog(_ snapshot: TimelineSnapshot, initial: Bool) throws -> CollectionDayCatalog {
    try CollectionDayCatalog(sections: snapshot.sections, completeness: initial ? .partial : .complete)
}
func fixtureSection(_ request: CollectionPageRequest) -> TimelineSection {
    let days = [request.newestDay, request.oldestDay].reduce(into: [CaptureDay]()) { if !$0.contains($1) { $0.append($1) } }
    return TimelineSection(offset: request.offset, limit: request.limit, list: days.map {
        TimelineDay(year: $0.year, month: $0.month, day: $0.day, itemCount: request.offset + request.limit)
    })
}
/// Most mock media payloads use a fixed timestamp; place them on their declared
/// query day so these tests exercise their own behavior rather than malformed dates.
func fixtureItem(_ item: PhotoItem, on day: CaptureDay) throws -> PhotoItem {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
    json["time"] = day.startTime + ((item.time % 86400) + 86400) % 86400
    return try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: json))
}
func fixtureBatch(_ items: [PhotoItem], request: CollectionPageRequest, fields: ItemFieldProfile) throws -> CollectionBatchResult {
    let corrected = try items.map { item in
        item.time >= request.oldestDay.startTime && item.time <= request.newestDay.endTime ? item : try fixtureItem(item, on: request.newestDay)
    }
    return CollectionBatchResult(items: corrected, profile: fields)
}
