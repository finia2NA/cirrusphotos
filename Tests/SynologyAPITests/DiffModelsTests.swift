import Foundation
import XCTest
@testable import SynologyAPI

final class DiffModelsTests: XCTestCase {
    private func decode(_ data: String) throws -> PhotoDiff {
        let envelope = try JSONDecoder().decode(APIEnvelope<PhotoDiffData>.self,
                                                from: Data(data.utf8))
        return try XCTUnwrap(envelope.data).value
    }

    func testObservedModifyAndIntegerDeleteShapesDecodeStrictly() throws {
        let diff = try decode("""
        {"success":true,"data":{"diff_version":12,"version_time":34,
        "item":{"modify":[{"id":7,"filename":"ignored.jpg"}],"delete":[8]},
        "album":{"modify":[],"delete":[]}}}
        """)
        XCTAssertEqual(diff.cursor, DiffCursor(diffVersion: 12, versionTime: 34))
        XCTAssertEqual(diff.modifiedItemIDs, [7])
        XCTAssertEqual(diff.deletedItemIDs, [8])
        XCTAssertFalse(diff.hasAlbumActivity)
    }

    func testAlbumEntriesRemainOpaqueButRequireConservativeActivity() throws {
        let diff = try decode("""
        {"success":true,"data":{"diff_version":1,"version_time":2,
        "item":{"modify":[],"delete":[]},
        "album":{"modify":[{"unrecognized":true}],"delete":[99]}}}
        """)
        XCTAssertTrue(diff.hasAlbumActivity)
        XCTAssertFalse(diff.isEmpty)
    }

    func testMissingArrayUnknownCategoryAndObjectTombstoneFailClosed() {
        let fixtures = [
            #"{"success":true,"data":{"diff_version":1,"version_time":2,"item":{"modify":[]},"album":{"modify":[],"delete":[]}}}"#,
            #"{"success":true,"data":{"diff_version":1,"version_time":2,"item":{"modify":[],"delete":[],"move":[]},"album":{"modify":[],"delete":[]}}}"#,
            #"{"success":true,"data":{"diff_version":1,"version_time":2,"item":{"modify":[],"delete":[{"id":9}]},"album":{"modify":[],"delete":[]}}}"#,
            #"{"success":true,"data":{"diff_version":1,"version_time":2,"has_more":true,"item":{"modify":[],"delete":[]},"album":{"modify":[],"delete":[]}}}"#,
        ]
        for fixture in fixtures {
            XCTAssertThrowsError(try decode(fixture))
        }
    }

    func testCursorRoundTripsOpaquePairWithoutOrderingAssumptions() throws {
        let cursor = DiffCursor(diffVersion: -7, versionTime: 9_223_372_036_854_775_000)
        let data = try JSONEncoder().encode(cursor)
        XCTAssertEqual(try JSONDecoder().decode(DiffCursor.self, from: data), cursor)
    }
}
