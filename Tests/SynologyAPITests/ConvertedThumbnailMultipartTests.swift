import Foundation
import XCTest
@testable import SynologyAPI

final class ConvertedThumbnailMultipartTests: XCTestCase {
    func testRoutingFieldsMatchConfirmedConverterOrderWithoutSIDBodyField() throws {
        let boundary = "test-boundary"
        let files = ConvertedThumbnailFiles(
            sm: Data([0x01, 0x02]), m: Data([0x03]), xl: Data([0x04, 0x05, 0x06])
        )
        let body = SynologyClient.convertedThumbnailMultipartBody(
            boundary: boundary, unitID: 238_228, files: files
        )
        let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))

        let api = try XCTUnwrap(text.range(of: "name=\"api\""))
        let version = try XCTUnwrap(text.range(of: "name=\"version\""))
        let method = try XCTUnwrap(text.range(of: "name=\"method\""))
        let unit = try XCTUnwrap(text.range(of: "name=\"unit_id\""))
        let sm = try XCTUnwrap(text.range(of: "name=\"thumb_sm\""))
        XCTAssertLessThan(api.lowerBound, version.lowerBound)
        XCTAssertLessThan(version.lowerBound, method.lowerBound)
        XCTAssertLessThan(method.lowerBound, unit.lowerBound)
        XCTAssertLessThan(unit.lowerBound, sm.lowerBound)
        XCTAssertFalse(text.contains("name=\"_sid\""))
        XCTAssertTrue(text.contains("\r\n\r\n238228\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
    }
}
