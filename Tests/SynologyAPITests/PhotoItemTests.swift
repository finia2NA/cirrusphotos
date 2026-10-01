import Foundation
import XCTest
@testable import SynologyAPI

final class PhotoItemTests: XCTestCase {
    func testOrientationControlsDisplayAspectRatio() throws {
        for (orientation, expected) in [(1, 2.0), (3, 2.0), (6, 0.5), (8, 0.5)] {
            let item = try decode(resolution: "{\"width\":4000,\"height\":2000}",
                                  orientation: ",\"orientation\":\(orientation)")
            XCTAssertEqual(item.displayAspectRatio, expected)
            let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(restored.additional?.orientation, orientation)
        }
    }

    func testOlderCachedRecordAndInvalidResolution() throws {
        let legacy = try decode(resolution: "{\"width\":4000,\"height\":2000}", orientation: "")
        XCTAssertNil(legacy.additional?.orientation)
        XCTAssertEqual(legacy.displayAspectRatio, 2)
        XCTAssertEqual(try decode(resolution: "{\"width\":0,\"height\":2000}", orientation: "").displayAspectRatio, 1)
        XCTAssertEqual(try decode(resolution: "{\"width\":4000,\"height\":-1}", orientation: "").displayAspectRatio, 1)
    }

    func testDayIDUsesUTCBoundary() throws {
        let before = try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":1,\"time\":1704067199,\"type\":\"photo\"}".utf8))
        let after = try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":2,\"time\":1704067200,\"type\":\"photo\"}".utf8))
        XCTAssertEqual(before.utcDayID, "2023-12-31")
        XCTAssertEqual(after.utcDayID, "2024-01-01")
    }

    private func decode(resolution: String, orientation: String) throws -> PhotoItem {
        let json = "{\"id\":1,\"time\":1700000000,\"type\":\"photo\",\"additional\":{\"resolution\":\(resolution)\(orientation)}}"
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }
}
