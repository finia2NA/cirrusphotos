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
    func testObservedUserEventsDecodeFavoritesAndRejectOtherEvents() throws {
        func events(_ list: String) throws -> UserEventDiff {
            let body = "{\"success\":true,\"data\":{\"diff_version\":5,\"version_time\":6,\"has_next\":false,\"list\":\(list)}}"
            return try XCTUnwrap(JSONDecoder().decode(APIEnvelope<UserEventDiffData>.self, from: Data(body.utf8)).data).value
        }
        let favorites = try events(#"[{"event_type":"favorite_add","target_id":[7,8]},{"event_type":"favorite_delete","target_id":[7]}]"#)
        XCTAssertEqual(favorites.favorites, [.init(itemIDs: [7, 8], favorite: true), .init(itemIDs: [7], favorite: false)])
        XCTAssertEqual(favorites.cursor, DiffCursor(diffVersion: 5, versionTime: 6))
        XCTAssertTrue(favorites.isBoundedTerminal)
        XCTAssertTrue(try events("[]").isEmpty)
        let unknown = try events(#"[{"event_type":"share_album","target_id":[3]}]"#)
        XCTAssertFalse(unknown.isEmpty); XCTAssertFalse(unknown.isBoundedTerminal)
        let malformed = try events(#"[{"event_type":"favorite_add","target_id":"7"}]"#)
        XCTAssertFalse(malformed.isBoundedTerminal)
    }
}
