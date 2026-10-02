import Foundation
import XCTest
@testable import SynologyAPI

final class PhotoItemTests: XCTestCase {
    func testOrientationIsDecodedButDoesNotRotateServerResolutionAgain() throws {
        for orientation in [1, 3, 6, 8] {
            let item = try decode(resolution: "{\"width\":4000,\"height\":2000}",
                                  orientation: ",\"orientation\":\(orientation)")
            XCTAssertEqual(item.displayAspectRatio, 2)
            let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(restored.additional?.orientation, orientation)
        }
    }

    func testObservedRotatedItemsMatchServedThumbnailGeometry() throws {
        let portrait = try decode(id: 183538,
                                  resolution: "{\"width\":3024,\"height\":4032}",
                                  orientation: ",\"orientation\":6")
        XCTAssertEqual(portrait.displayAspectRatio, 3024.0 / 4032.0)
        XCTAssertEqual(portrait.displayAspectRatio, 320.0 / 427.0, accuracy: 0.001)

        let landscape = try decode(id: 183471,
                                   resolution: "{\"width\":2208,\"height\":1242}",
                                   orientation: ",\"orientation\":8")
        XCTAssertEqual(landscape.displayAspectRatio, 2208.0 / 1242.0)
        XCTAssertEqual(landscape.displayAspectRatio, 569.0 / 320.0, accuracy: 0.001)
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

    private func decode(id: Int = 1, resolution: String, orientation: String) throws -> PhotoItem {
        let json = "{\"id\":\(id),\"time\":1700000000,\"type\":\"photo\",\"additional\":{\"resolution\":\(resolution)\(orientation)}}"
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }
}
