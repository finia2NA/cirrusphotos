import Foundation
import XCTest
import SynologyAPI
import TimelineCore
@testable import PhotoCache

final class LocationIndexDeltaTests: XCTestCase {
    private let cursor = DiffCursor(diffVersion: 1, versionTime: 2)

    private func item(_ id: Int64, time: Int64 = 100,
                      latitude: Double? = 1, longitude: Double? = 2) throws -> PhotoItem {
        let gps: String
        if let latitude, let longitude {
            gps = ",\"gps\":{\"latitude\":\(latitude),\"longitude\":\(longitude)}"
        } else {
            gps = ""
        }
        return try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"time":\(time),"type":"photo","additional":{"thumbnail":{"unit_id":\(id + 1000),"cache_key":"r\(id)"}\(gps)}}
        """.utf8))
    }

    private func record(_ id: Int64, time: Int64 = 100) -> PhotoLocationRecord {
        PhotoLocationRecord(id: id, time: time,
                            coordinate: PhotoCoordinate(latitude: 1, longitude: 2),
                            thumbnail: ThumbnailInfo(unitID: id + 1000, cacheKey: "r\(id)"))
    }

    func testMergeAddsUpdatesRemovesGPSAndDeletesKnownAndUnknownIDs() throws {
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [2, 3],
                             deletedItemIDs: [1, 99], hasAlbumActivity: false)
        let lookup = LocationItemLookup(
            requestedIDs: [2, 3],
            items: [try item(2, time: 200, latitude: 5, longitude: 6),
                    try item(3, time: 300, latitude: nil, longitude: nil)]
        )
        let decision = LocationIndexDelta.merge(
            existing: [record(1), record(2), record(3)], diff: diff, lookup: lookup
        )
        guard case .updated(let records) = decision else { return XCTFail("Expected update") }
        XCTAssertEqual(records.map(\.id), [2])
        XCTAssertEqual(records[0].coordinate, PhotoCoordinate(latitude: 5, longitude: 6))
        XCTAssertEqual(records[0].thumbnail?.unitID, 1002, "Item and thumbnail IDs remain distinct")
    }

    func testEmptyIntervalIsOnlyReusableDecision() {
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [],
                             hasAlbumActivity: false)
        XCTAssertEqual(LocationIndexDelta.merge(existing: [record(1)], diff: diff, lookup: nil),
                       .unchanged)
    }

    func testConflictsDuplicatesAlbumActivityAndLookupOmissionRequireRebuild() throws {
        let cases = [
            PhotoDiff(cursor: cursor, modifiedItemIDs: [1, 1], deletedItemIDs: [], hasAlbumActivity: false),
            PhotoDiff(cursor: cursor, modifiedItemIDs: [1], deletedItemIDs: [1], hasAlbumActivity: false),
            PhotoDiff(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [], hasAlbumActivity: true),
        ]
        for diff in cases {
            guard case .rebuildRequired = LocationIndexDelta.merge(existing: [], diff: diff, lookup: nil)
            else { return XCTFail("Ambiguous delta was accepted") }
        }
        let missing = PhotoDiff(cursor: cursor, modifiedItemIDs: [1, 2], deletedItemIDs: [],
                                hasAlbumActivity: false)
        let lookup = LocationItemLookup(requestedIDs: [1, 2], items: [try item(1)])
        guard case .rebuildRequired = LocationIndexDelta.merge(existing: [], diff: missing, lookup: lookup)
        else { return XCTFail("Lookup omission was treated as deletion") }
    }

    func testOversizedIntervalRequiresRebuild() {
        let ids = (0...LocationIndexDelta.maximumChangedIDs).map(Int64.init)
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: ids,
                             deletedItemIDs: [], hasAlbumActivity: false)
        guard case .rebuildRequired = LocationIndexDelta.merge(existing: [], diff: diff, lookup: nil)
        else { return XCTFail("Oversized interval was accepted") }
    }

    func testMergeUsesStableCaptureDescendingThenIDAscendingOrder() throws {
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [3, 1, 2],
                             deletedItemIDs: [], hasAlbumActivity: false)
        let lookup = LocationItemLookup(
            requestedIDs: [3, 1, 2],
            items: [try item(3, time: 200), try item(1, time: 200), try item(2, time: 300)]
        )
        let decision = LocationIndexDelta.merge(existing: [], diff: diff, lookup: lookup)
        guard case .updated(let records) = decision else { return XCTFail("Expected update") }
        XCTAssertEqual(records.map(\.id), [2, 1, 3])
    }
}
