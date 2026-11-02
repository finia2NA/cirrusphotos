import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class MetadataReadPlannerTests: XCTestCase {
    private func fixtures(_ counts: [Int]) throws -> (CollectionDayCatalog, [DayPageRead]) {
        let base = try CaptureDay(year: 2024, month: 6, day: 30)
        let entries = try counts.enumerated().map { try CollectionDayCount(day: CaptureDay(time: base.startTime - Int64($0.offset) * 86_400), count: $0.element) }
        let catalog = try CollectionDayCatalog(days: entries, completeness: .complete)
        let demands = try entries.flatMap { entry in
            try stride(from: 0, to: entry.count, by: 250).map { offset in
                try DayPageRead(address: DayPageAddress(collection: .library(.personal), day: entry.day, offset: offset), dayCount: entry.count, membershipGeneration: 1)
            }
        }
        return (catalog, demands)
    }
    func testSmallDaysBatchWithoutPerDayRequestsOrPadding() throws {
        let (catalog, demands) = try fixtures([20, 5, 12, 1, 50])
        let batches = try MetadataReadPlanner.plan(demands: demands, catalog: catalog, profile: .fullPage)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].request.limit, 88)
        XCTAssertEqual(batches[0].pages.count, 5)
        XCTAssertEqual(try MetadataReadPlanner.plan(demands: [demands[0]], catalog: catalog, profile: .fullPage)[0].request.limit, 20)
    }
    func testGapsAndNonzeroOffsetsNeverBecomeWrongRangeQueries() throws {
        let (catalog, demands) = try fixtures([10, 10, 10])
        XCTAssertEqual(try MetadataReadPlanner.plan(demands: [demands[0], demands[2]], catalog: catalog, profile: .fullPage).count, 2)
        let (largeCatalog, large) = try fixtures([1501, 10])
        let batches = try MetadataReadPlanner.plan(demands: Array(large[4...]), catalog: largeCatalog, profile: .fullPage)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].request.offset, 1000)
        XCTAssertEqual(batches[0].request.limit, 501)
        XCTAssertEqual(batches[1].request.offset, 0)
    }
    func testItemAndDayCaps() throws {
        let (catalog, demands) = try fixtures([1501])
        XCTAssertEqual(try MetadataReadPlanner.plan(demands: demands, catalog: catalog, profile: .fullPage).map { $0.request.limit }, [1000, 501])
        let (manyDays, small) = try fixtures(Array(repeating: 1, count: 69))
        XCTAssertEqual(try MetadataReadPlanner.plan(demands: small, catalog: manyDays, profile: .fullPage).map { $0.pages.count }, [32, 32, 5])
    }
    func testDistinctPredicateNeverSharesMembership() throws {
        let (catalog, demands) = try fixtures([20])
        let favorites = try DayPageRead(address: DayPageAddress(collection: .favorites(.personal), day: demands[0].address.day, offset: 0), dayCount: 20, membershipGeneration: 1)
        XCTAssertEqual(try MetadataReadPlanner.plan(demands: [demands[0], favorites], catalog: catalog, profile: .fullPage).count, 2)
    }
    func testMaterializerRejectsMissingExtraDuplicateAndUnexpectedDays() throws {
        let (catalog, demands) = try fixtures([2, 1])
        let batch = try XCTUnwrap(MetadataReadPlanner.plan(demands: demands, catalog: catalog, profile: .fullPage).first)
        func item(_ id: Int64, day: CaptureDay) throws -> PhotoItem {
            try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\"time\":\(day.startTime),\"type\":\"photo\"}".utf8))
        }
        let first = demands[0].address.day, second = demands[1].address.day
        let items = try [item(1, day: first), item(2, day: first), item(3, day: second)]
        let result = try batch.materialize(.init(items: items, profile: .fullPage))
        XCTAssertEqual(result.map { $0.map(\.id) }, [[1, 2], [3]])
        XCTAssertThrowsError(try batch.materialize(.init(items: Array(items.prefix(2)), profile: .fullPage)))
        XCTAssertThrowsError(try batch.materialize(.init(items: items + [items[0]], profile: .fullPage)))
        XCTAssertThrowsError(try batch.materialize(.init(items: [items[0], items[0], items[2]], profile: .fullPage)))
        XCTAssertThrowsError(try batch.materialize(.init(items: [items[2], items[1], items[0]], profile: .fullPage)))
        XCTAssertThrowsError(try batch.materialize(.init(items: items, profile: .identityAndTime)))
    }

}
