import Foundation
import SynologyAPI
@testable import PhotoCache

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

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        throw TestFailure("Unexpected timeline request")
    }

    func albums() async throws -> [AlbumSummary] {
        throw TestFailure("Unexpected album-list request")
    }

    func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        throw TestFailure("Unexpected album-timeline request")
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        throw TestFailure("Unexpected item-page request")
    }

    func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem] {
        throw TestFailure("Unexpected location-scan request")
    }

    func diffVersion() async throws -> DiffCursor {
        throw SynologyAPIError.api(103)
    }

    func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        throw TestFailure("Unexpected Diff request")
    }


    func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        throw TestFailure("Unexpected favorite write")
    }

    func items(ids: [Int64]) async throws -> [PhotoItem] { throw TestFailure("Unexpected item lookup") }
    func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws { throw TestFailure("Unexpected rotation") }
    func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit] { throw TestFailure("Unexpected regeneration") }
    func restoreFromRegenerating(unitIDs: [Int64]) async throws { throw TestFailure("Unexpected regeneration restore") }
    func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles) async throws { throw TestFailure("Unexpected converted upload") }

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

/// Fixtures seed the current normalized model directly, never legacy page payloads.
func seedMetadataCatalog(_ snapshot: TimelineSnapshot, repository: CachedPhotosRepository,
                         collection: PhotoCollectionDescriptor = .personalLibrary,
                         currentRun: Bool = false) async throws {
    try await repository.initializeMetadataEngine()
    let namespace = await repository.metadataNamespace
    let store = await repository.store
    let days = try snapshot.sections.flatMap(\.list).map { try CollectionDayCount(day: CaptureDay(year: $0.year, month: $0.month, day: $0.day), count: $0.itemCount) }
    let catalog = try CollectionDayCatalog(days: days, completeness: .complete)
    let run = currentRun ? await repository.runID : "fixture-previous-run"
    try await store.storeMetadataCatalog(catalog, key: CollectionKey(namespace: namespace, collection: collection), validatedRun: run, admission: store.metadataAdmission(namespace))
}
func seedMetadataPage(_ items: [PhotoItem], section: TimelineSection, repository: CachedPhotosRepository,
                      collection: PhotoCollectionDescriptor = .personalLibrary,
                      validatedRun: String? = nil) async throws {
    try await repository.initializeMetadataEngine()
    let namespace = await repository.metadataNamespace(for: collection)
    let store = await repository.store
    let key = CollectionKey(namespace: namespace, collection: collection)
    let address = try DayPageAddress(section: section, collection: collection)
    var counts = try await store.metadataCatalog(key)?.catalog.days ?? []
    counts.removeAll { $0.day == address.day }
    counts.append(try CollectionDayCount(day: address.day, count: section.list[0].itemCount))
    let catalog = try CollectionDayCatalog(days: counts, completeness: .complete)
    let runID = await repository.runID
    let run = validatedRun?.hasPrefix(runID) == true ? runID : "fixture-previous-run"
    let admission = try await store.metadataAdmission(namespace)
    try await store.storeMetadataCatalog(catalog, key: key, validatedRun: run, admission: admission)
    let generation = try await store.metadataDayGeneration(key, day: address.day)!
    let page = try DayPageRead(address: address, dayCount: section.list[0].itemCount, membershipGeneration: UInt64(generation))
    try await store.storeMetadataPage(page, items: try items.map { try fixtureItem($0, on: address.day) }, profile: .fullPage, namespace: namespace, currentRun: run, admission: admission)
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
