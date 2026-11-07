import XCTest
@testable import CirrusPhotosApp

final class VideoLoadingDemandTests: XCTestCase {
    func testAdvancedOffsetUsesOriginalEnd() throws {
        var demand = try VideoLoadingDemand(requestedOffset: 100, currentOffset: 140, requestedLength: 100, allToEnd: false)
        XCTAssertEqual(demand.nextLength(limit: 1000), 60)
        try demand.advance(60)
        XCTAssertNil(demand.nextLength(limit: 1000))
    }

    func testAllToEndAndOverflow() throws {
        var demand = try VideoLoadingDemand(requestedOffset: 100, currentOffset: 100, requestedLength: 1, allToEnd: true)
        XCTAssertEqual(demand.nextLength(limit: 1024), 1024)
        try demand.advance(500)
        XCTAssertEqual(demand.offset, 600)
        XCTAssertThrowsError(try VideoLoadingDemand(requestedOffset: Int64.max - 1, currentOffset: 0, requestedLength: 3, allToEnd: false))
    }
}
