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
        let candidate = try MetadataChangeApplication.prepare(diff: .init(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [1]), oldInventory: [old], referencedDays: [:], lookup: [])
        XCTAssertEqual(candidate.affectedDays, [try CaptureDay(time: old.time)])
        XCTAssertFalse(candidate.invalidateAll)
    }
    func testDateMoveInvalidatesBothDaysAndSameDayEditStillInvalidatesMembership() throws {
        let old = MetadataIndexItem(id: 1, time: 1_704_067_200, coordinate: nil, thumbnail: nil)
        let moved = try item(1, time: old.time + 86_400)
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [1], deletedItemIDs: [])
        let candidate = try MetadataChangeApplication.prepare(diff: diff, oldInventory: [old], referencedDays: [:], lookup: [moved])
        XCTAssertEqual(candidate.affectedDays.count, 2)
        let unchangedDay = try MetadataChangeApplication.prepare(diff: diff, oldInventory: [old], referencedDays: [:], lookup: [item(1, time: old.time)])
        XCTAssertEqual(unchangedDay.affectedDays.count, 1)
    }
    func testUnindexedIDsInvalidateOnlyTheCachedPagesThatListThem() throws {
        let new = try item(5, time: 1_704_067_200)
        let diff = PhotoDiff(cursor: cursor, modifiedItemIDs: [5], deletedItemIDs: [6])
        let addition = try MetadataChangeApplication.prepare(diff: diff, oldInventory: [], referencedDays: [:], lookup: [new])
        XCTAssertFalse(addition.invalidateAll)
        XCTAssertEqual(addition.affectedDays, [try CaptureDay(time: new.time)])
        let listed = try CaptureDay(year: 2020, month: 5, day: 1), deletedDay = try CaptureDay(year: 2019, month: 1, day: 1)
        let evicted = try MetadataChangeApplication.prepare(diff: diff, oldInventory: [], referencedDays: [5: [listed], 6: [deletedDay]], lookup: [new])
        XCTAssertEqual(evicted.affectedDays, [try CaptureDay(time: new.time), listed, deletedDay])
    }
    func testPartialAndMissingLookupNeverImplyTombstones() throws {
        XCTAssertThrowsError(try MetadataChangeApplication.prepare(diff: .init(cursor: cursor, modifiedItemIDs: [5], deletedItemIDs: []), oldInventory: [], referencedDays: [:], lookup: []))
        XCTAssertThrowsError(try MetadataChangeApplication.prepare(diff: .init(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: [], hasNext: true), oldInventory: [], referencedDays: [:], lookup: []))
    }
}
