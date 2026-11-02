import Foundation
import SynologyAPI
@_exported import TransportTestSupport
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

/// Fixtures seed the current normalized model directly, never legacy page payloads.
func seedMetadataCatalog(_ snapshot: TimelineSnapshot, repository: CachedPhotosRepository,
                         collection: PhotoCollectionDescriptor = .library(.personal),
                         currentRun: Bool = false) async throws {
    try await repository.initializeMetadataEngine()
    let namespace = await repository.personalMetadataNamespace
    let store = await repository.store
    let days = try snapshot.sections.flatMap(\.list).map { try CollectionDayCount(day: CaptureDay(year: $0.year, month: $0.month, day: $0.day), count: $0.itemCount) }
    let catalog = try CollectionDayCatalog(days: days, completeness: .complete)
    let run = currentRun ? await repository.runID : "fixture-previous-run"
    try await store.storeMetadataCatalog(catalog, key: CollectionKey(namespace: namespace, collection: collection), validatedRun: run, admission: store.metadataAdmission(namespace))
}
func seedMetadataPage(_ items: [PhotoItem], section: TimelineSection, repository: CachedPhotosRepository,
                      collection: PhotoCollectionDescriptor = .library(.personal),
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
