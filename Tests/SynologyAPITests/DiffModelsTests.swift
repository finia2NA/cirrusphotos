import Foundation
import XCTest
@testable import SynologyAPI

final class DiffModelsTests: XCTestCase {
    private func decode(_ body: String) throws -> PhotoDiff {
        let envelope = try JSONDecoder().decode(APIEnvelope<PhotoDiffData>.self, from: Data("{\"success\":true,\"data\":\(body)}".utf8))
        return try XCTUnwrap(envelope.data).value
    }
    func testObservedV7ShapeRequiresTerminalMarkerAndAllCategories() throws {
        let diff = try decode(#"{"diff_version":12,"version_time":34,"item":{"modify":[{"id":7,"filename":"ignored.jpg"}],"delete":[8],"merge":[],"move":[]},"similar":[],"has_next":false}"#)
        XCTAssertEqual(diff.modifiedItemIDs, [7]); XCTAssertEqual(diff.deletedItemIDs, [8])
        XCTAssertEqual(diff.cursor, DiffCursor(diffVersion: 12, versionTime: 34))
        XCTAssertTrue(diff.isBoundedTerminal)
    }
    func testUnsupportedAndPartialIntervalsCannotBecomeEmptyProofs() throws {
        for extra in [#""has_next":true,"similar":[]"#, #""has_next":false,"similar":[{"id":9}]"#] {
            let diff = try decode("{\"diff_version\":1,\"version_time\":2,\"item\":{\"modify\":[],\"delete\":[],\"merge\":[],\"move\":[]},\(extra)}")
            XCTAssertFalse(diff.isEmpty); XCTAssertFalse(diff.isBoundedTerminal)
        }
    }
    func testMalformedMissingAndUnknownShapesFailClosed() {
        for body in [
            #"{"diff_version":1,"version_time":2,"item":{"modify":[],"delete":[],"merge":[],"move":[]},"similar":[]}"#,
            #"{"diff_version":1,"version_time":2,"item":{"modify":[],"delete":[{"id":9}],"merge":[],"move":[]},"similar":[],"has_next":false}"#,
            #"{"diff_version":1,"version_time":2,"item":{"modify":[],"delete":[],"merge":[],"move":[]},"similar":[],"has_next":false,"unknown":[]}"#
        ] { XCTAssertThrowsError(try decode(body)) }
    }
    func testTerminalTombstonesStillRespectClientBoundAndConflictsFailClosed() {
        let cursor = DiffCursor(diffVersion: -7, versionTime: Int64.max)
        XCTAssertFalse(PhotoDiff(cursor: cursor, modifiedItemIDs: [], deletedItemIDs: Array(1...5012)).isBoundedTerminal)
        XCTAssertFalse(PhotoDiff(cursor: cursor, modifiedItemIDs: [1, 1], deletedItemIDs: []).isBoundedTerminal)
        XCTAssertFalse(PhotoDiff(cursor: cursor, modifiedItemIDs: [1], deletedItemIDs: [1]).isBoundedTerminal)
        XCTAssertEqual(try JSONDecoder().decode(DiffCursor.self, from: JSONEncoder().encode(cursor)), cursor)
    }
}
