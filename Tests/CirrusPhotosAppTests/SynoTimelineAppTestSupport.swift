import Foundation
import SynologyAPI
@_exported import TransportTestSupport

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
