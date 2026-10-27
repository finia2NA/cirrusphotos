import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class MetadataChangeApplicationTests: XCTestCase {
    private let cursor = DiffCursor(diffVersion: 2, versionTime: 2)
    private func item(_ id: Int64, time: Int64) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(time),\"type\":\"photo\"}".utf8))
    }
    func testKnownUnlocatedDeletionStillInvalidatesItsOldDay() throws {
        let old = MetadataIndexItem(id: 1, time: 1_704_067_200, coordinate: nil, thumbnail: nil)
        let candidate = try MetadataChangeApplication.prepare(diff: .init(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [1]), oldInventory: [old], inventoryComplete: false, lookup: [])
        XCTAssertEqual(candidate.affectedDays, [try CaptureDay(time: old.time)])
        XCTAssertFalse(candidate.invalidateAll)
    }
    func testDateMoveInvalidatesBothDaysAndSameDayEditStillInvalidatesMembership() throws {
        let old = MetadataIndexItem(id: 1, time: 1_704_067_200, coordinate: nil, thumbnail: nil)
        let moved = try item(1, time: old.time + 86_400)
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [1], deletedItemIDs: [])
        let candidate = try MetadataChangeApplication.prepare(diff: diff, oldInventory: [old], inventoryComplete: false, lookup: [moved])
        XCTAssertEqual(candidate.affectedDays.count, 2)
        let unchangedDay = try MetadataChangeApplication.prepare(diff: diff, oldInventory: [old], inventoryComplete: false, lookup: [item(1, time: old.time)])
        XCTAssertEqual(unchangedDay.affectedDays.count, 1)
    }
    func testSparseAbsenceIsUnknownAndCompleteAbsenceCanBeAddition() throws {
        let new = try item(5, time: 1_704_067_200)
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [5], deletedItemIDs: [])
        XCTAssertTrue(try MetadataChangeApplication.prepare(diff: diff, oldInventory: [], inventoryComplete: false, lookup: [new]).invalidateAll)
        XCTAssertFalse(try MetadataChangeApplication.prepare(diff: diff, oldInventory: [], inventoryComplete: true, lookup: [new]).invalidateAll)
    }
    func testPartialAndMissingLookupNeverImplyTombstones() throws {
        XCTAssertThrowsError(try MetadataChangeApplication.prepare(diff: .init(cursor: cursor, modifiedItemIDs: [5], deletedItemIDs: []), oldInventory: [], inventoryComplete: true, lookup: []))
        XCTAssertThrowsError(try MetadataChangeApplication.prepare(diff: .init(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [], hasNext: true), oldInventory: [], inventoryComplete: true, lookup: []))
    }
}
