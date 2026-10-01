import XCTest
@testable import TimelineCore

final class JustifiedRowsTests: XCTestCase {
    func testCompletedRowsFillWidthAndKeepOrderAndAspectRatio() {
        let ratios = [1.5, 1, 2, 0.75, 1.2, 1.8]
        let rows = JustifiedRows.layout(aspectRatios: ratios, availableWidth: 500)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.flatMap { $0.cells.map(\.index) }, Array(ratios.indices))
        for row in rows.dropLast() {
            XCTAssertEqual(row.width, 500, accuracy: 0.0001)
            for cell in row.cells {
                XCTAssertEqual(cell.width / row.height, ratios[cell.index], accuracy: 0.0001)
            }
        }
    }

    func testFinalRowStaysLeftAlignedAtTargetHeight() {
        let rows = JustifiedRows.layout(aspectRatios: [1, 1, 1, 1], availableWidth: 370,
                                        targetHeight: 180, gap: 6)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].width, 370, accuracy: 0.0001)
        XCTAssertEqual(rows[1].cells.first?.x, 0)
        XCTAssertEqual(rows[1].height, 180)
        XCTAssertEqual(rows[1].width, 180)
    }

    func testIncompletePrefixCanFlowIntoNextChunk() {
        let first = JustifiedRows.layoutPrefix(aspectRatios: [1, 1], availableWidth: 500,
                                                targetHeight: 180, gap: 6, finalize: false)
        XCTAssertTrue(first.rows.isEmpty)
        XCTAssertEqual(first.pendingRange, 0..<2)

        let continued = JustifiedRows.layoutPrefix(aspectRatios: [1, 1, 1, 1], availableWidth: 500,
                                                    targetHeight: 180, gap: 6, finalize: true)
        XCTAssertEqual(continued.rows, JustifiedRows.layout(aspectRatios: [1, 1, 1, 1],
                                                             availableWidth: 500))
        XCTAssertTrue(continued.pendingRange.isEmpty)
    }

    func testPendingBoundaryRowIsBoundedForExtremeRatios() {
        let result = JustifiedRows.layoutPrefix(aspectRatios: Array(repeating: 1e-20, count: 100),
                                                availableWidth: 500, finalize: false)
        XCTAssertEqual(result.rows.flatMap { $0.cells }.count, 96)
        XCTAssertEqual(result.pendingRange.count, 4)
        XCTAssertTrue(result.rows.allSatisfy { $0.cells.count <= 32 })
    }

    func testNarrowWidthAndPanoramaRemainContainedAndFinite() {
        for width in [0.5, 20.0, 90.0] {
            let rows = JustifiedRows.layout(aspectRatios: [100, 0.01, 1, 2, .greatestFiniteMagnitude], availableWidth: width)
            XCTAssertEqual(rows.flatMap { $0.cells.map(\.index) }, [0, 1, 2, 3, 4])
            for row in rows {
                XCTAssertTrue(row.height.isFinite)
                XCTAssertGreaterThanOrEqual(row.height, 0)
                XCTAssertLessThanOrEqual(row.width, width + 0.0001)
                for cell in row.cells {
                    XCTAssertTrue(cell.x.isFinite && cell.width.isFinite)
                    XCTAssertGreaterThanOrEqual(cell.width, 0)
                }
            }
        }
    }

    func testInvalidDimensionsUseSquareFallback() {
        let rows = JustifiedRows.layout(aspectRatios: [0, -1, .nan, .infinity], availableWidth: 500)
        XCTAssertEqual(rows.flatMap { $0.cells.map(\.index) }, [0, 1, 2, 3])
        for row in rows {
            for cell in row.cells {
                XCTAssertEqual(cell.width, row.height, accuracy: 0.0001)
            }
        }
        XCTAssertTrue(JustifiedRows.layout(aspectRatios: [1], availableWidth: 0).isEmpty)
    }
}
