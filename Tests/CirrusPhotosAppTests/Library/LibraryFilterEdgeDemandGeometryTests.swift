import XCTest
@testable import CirrusPhotosApp
import PhotoCache

final class LibraryFilterEdgeDemandGeometryTests: XCTestCase {
    func testUsesDirectionAtCorrespondingEdge() {
        XCTAssertEqual(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .newer, top: 100, viewportHeight: 500, documentHeight: 5_000), .newer)
        XCTAssertNil(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .older, top: 100, viewportHeight: 500, documentHeight: 5_000))
        XCTAssertEqual(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .older, top: 4_300, viewportHeight: 500, documentHeight: 5_000), .older)
        XCTAssertNil(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .newer, top: 4_300, viewportHeight: 500, documentHeight: 5_000))
    }

    func testShortDocumentReturnsOnlyActualScrollDirection() {
        XCTAssertEqual(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .newer, top: 0, viewportHeight: 500, documentHeight: 300), .newer)
        XCTAssertEqual(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .older, top: 0, viewportHeight: 500, documentHeight: 300), .older)
    }

    func testNoDemandAwayFromEitherEdge() {
        XCTAssertNil(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .newer, top: 2_000, viewportHeight: 500, documentHeight: 5_000))
        XCTAssertNil(LibraryFilterEdgeDemandGeometry.resolve(
            direction: .older, top: 2_000, viewportHeight: 500, documentHeight: 5_000))
    }
}
