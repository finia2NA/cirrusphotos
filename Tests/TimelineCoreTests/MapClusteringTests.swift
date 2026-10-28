import XCTest
@testable import TimelineCore

final class MapClusteringTests: XCTestCase {
    private let region = MapRegion(center: PhotoCoordinate(latitude: 0, longitude: 0),
                                   latitudeDelta: 10, longitudeDelta: 10)

    private func record(_ id: Int64, lat: Double, lon: Double, time: Int64 = 100) -> MapPhotoRecord {
        MapPhotoRecord(id: id, time: time,
                       coordinate: PhotoCoordinate(latitude: lat, longitude: lon))
    }

    func testInvalidCoordinatesAreExcluded() {
        let records = [
            record(1, lat: .nan, lon: 0),
            record(2, lat: 0, lon: .infinity),
            record(3, lat: 91, lon: 0),
            record(4, lat: 0, lon: -181),
            record(5, lat: 1, lon: 1),
        ]
        let groups = MapClusterBuilder.groups(records: records, in: region)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.memberIDs, [5])
    }

    func testRegionMarginIncludesNearbyPointsAndExcludesFarOnes() {
        let records = [
            record(1, lat: 5.5, lon: 0),
            record(2, lat: 7, lon: 0),
            record(3, lat: -5.9, lon: 0),
            record(4, lat: 0, lon: 5.9),
            record(5, lat: 0, lon: 6.5),
        ]
        let groups = MapClusterBuilder.groups(records: records, in: region)
        let ids = Set(groups.flatMap(\.memberIDs))
        XCTAssertEqual(ids, [1, 3, 4])
    }

    func testNearbyPointsClusterAtCoarseZoomAndSeparateAtFineZoom() {
        let records = [
            record(1, lat: 0.00010, lon: 0.00010, time: 200),
            record(2, lat: 0.00017, lon: 0.00017, time: 100),
        ]
        let coarse = MapClusterBuilder.groups(records: records, in: region)
        XCTAssertEqual(coarse.count, 1)
        XCTAssertEqual(coarse.first?.count, 2)
        XCTAssertFalse(coarse.first?.isSingle ?? true)

        let fineRegion = MapRegion(center: PhotoCoordinate(latitude: 0.00015, longitude: 0.00015),
                                   latitudeDelta: 0.0002, longitudeDelta: 0.0002)
        let fine = MapClusterBuilder.groups(records: records, in: fineRegion)
        XCTAssertEqual(fine.count, 2)
        XCTAssertTrue(fine.allSatisfy(\.isSingle))
    }

    func testPointsWithinMinimumRadiusMergeAcrossGridBoundaries() {
        let region = MapRegion(center: PhotoCoordinate(latitude: 0, longitude: 0),
                               latitudeDelta: 1, longitudeDelta: 1)
        let records = [
            record(1, lat: 0.0, lon: 0.0, time: 200),
            record(2, lat: -0.0001, lon: 0.0, time: 100),
        ]
        let span = MapCellSpan(latitude: 0.1, longitude: 0.1)
        let groups = MapClusterBuilder.groups(records: records, in: region,
                                              minimumCellSpan: span)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.first?.memberIDs, [1, 2])
    }

    func testMinimumRadiusStillSeparatesDistantPoints() {
        let region = MapRegion(center: PhotoCoordinate(latitude: 0, longitude: 0),
                               latitudeDelta: 1, longitudeDelta: 1)
        let records = [
            record(1, lat: 0.0, lon: 0.0, time: 200),
            record(2, lat: -0.0001, lon: 0.0, time: 100),
            record(3, lat: -0.5, lon: 0.0, time: 50),
        ]
        let span = MapCellSpan(latitude: 0.1, longitude: 0.1)
        let groups = MapClusterBuilder.groups(records: records, in: region,
                                              minimumCellSpan: span)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.count), [2, 1])
        XCTAssertEqual(Set(groups.flatMap(\.memberIDs)), [1, 2, 3])
    }

    func testRadiusNeverChainsAcrossLongDistances() {
        let region = MapRegion(center: PhotoCoordinate(latitude: 0, longitude: 0),
                               latitudeDelta: 4, longitudeDelta: 4)
        let span = MapCellSpan(latitude: 0.6, longitude: 0.6)
        let records = [
            record(1, lat: 0.0, lon: 0.0, time: 300),
            record(2, lat: 0.5, lon: 0.0, time: 200),
            record(3, lat: 1.0, lon: 0.0, time: 100),
            record(4, lat: 1.5, lon: 0.0, time: 50),
        ]
        let groups = MapClusterBuilder.groups(records: records, in: region,
                                              maxAnnotations: 512, minimumCellSpan: span)
        XCTAssertEqual(groups.count, 2, "Neighbor chains must not merge into one group")
        XCTAssertEqual(groups.map(\.count), [2, 2])
    }

    func testSinglePointBucketIsSingle() {
        let groups = MapClusterBuilder.groups(records: [record(1, lat: 1, lon: 1)], in: region)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isSingle)
        XCTAssertEqual(groups[0].count, 1)
    }

    func testMaxAnnotationCapIsRespected() {
        var records: [MapPhotoRecord] = []
        var state: UInt64 = 0x9E3779B97F4A7C15
        for id in 1...2000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let lat = Double(state % 100_000) / 100_000 * 10 - 5
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let lon = Double(state % 100_000) / 100_000 * 10 - 5
            records.append(record(Int64(id), lat: lat, lon: lon))
        }
        let groups = MapClusterBuilder.groups(records: records, in: region, maxAnnotations: 256)
        XCTAssertLessThanOrEqual(groups.count, 256)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, records.count)
        XCTAssertEqual(groups.flatMap(\.memberIDs).count, records.count)
    }

    func testDenseZoomUsesCoarserGroupsWithinDefaultLimitWithoutLosingPhotos() {
        let fineRegion = MapRegion(center: PhotoCoordinate(latitude: 40, longitude: 10),
                                   latitudeDelta: 0.01, longitudeDelta: 0.01)
        var records: [MapPhotoRecord] = []
        for index in 0..<1_600 {
            let latitude = 39.995 + Double(index / 40) * 0.00025
            let longitude = 9.995 + Double(index % 40) * 0.00025
            records.append(record(Int64(index), lat: latitude, lon: longitude, time: Int64(index)))
        }
        let moreDetailed = MapClusterBuilder.groups(records: records, in: fineRegion,
                                                    maxAnnotations: 512)
        let groups = MapClusterBuilder.groups(records: records, in: fineRegion)
        XCTAssertGreaterThan(moreDetailed.count, MapClusterBuilder.defaultMaxAnnotations)
        XCTAssertLessThanOrEqual(groups.count, MapClusterBuilder.defaultMaxAnnotations)
        XCTAssertLessThan(groups.count, moreDetailed.count)
        XCTAssertTrue(groups.contains { $0.count > 1 })
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, records.count)
        XCTAssertEqual(Set(groups.flatMap(\.memberIDs)), Set(records.map(\.id)))
    }

    func testAnnotationCapOfOneIncludesOppositeMarginEdges() {
        let records = [
            record(1, lat: -5.9, lon: -5.9, time: 2),
            record(2, lat: 5.9, lon: 5.9, time: 1),
        ]
        let groups = MapClusterBuilder.groups(records: records, in: region,
                                               maxAnnotations: 1)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testRepresentativeIsNewestMemberAndMembersAreOrdered() {
        let records = [
            record(1, lat: 2, lon: 2, time: 300),
            record(2, lat: 2, lon: 2, time: 500),
            record(3, lat: 2, lon: 2, time: 400),
            record(4, lat: 2, lon: 2, time: 500),
        ]
        let groups = MapClusterBuilder.groups(records: records, in: region)
        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.representative.id, 4)
        XCTAssertEqual(group.representative.time, 500)
        XCTAssertEqual(group.memberIDs, [4, 2, 3, 1])
    }

    func testIdenticalCoordinatesNeverSplit() {
        let records = [
            record(1, lat: 0.5, lon: 0.5, time: 10),
            record(2, lat: 0.5, lon: 0.5, time: 20),
        ]
        let fineRegion = MapRegion(center: PhotoCoordinate(latitude: 0.5, longitude: 0.5),
                                   latitudeDelta: 0.00001, longitudeDelta: 0.00001)
        let groups = MapClusterBuilder.groups(records: records, in: fineRegion)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].memberIDs, [2, 1])
    }

    func testOutputIsDeterministicAcrossRuns() {
        var records: [MapPhotoRecord] = []
        for id in 1...500 {
            let latitude = Double(id % 50) / 10
            let longitude = Double(id % 37) / 10
            let time = Int64(1000 - id)
            records.append(record(Int64(id), lat: latitude, lon: longitude, time: time))
        }
        let first = MapClusterBuilder.groups(records: records, in: region)
        let second = MapClusterBuilder.groups(records: records, in: region)
        XCTAssertEqual(first, second)
    }

    func testEmptyInputAndDegenerateRegion() {
        XCTAssertTrue(MapClusterBuilder.groups(records: [], in: region).isEmpty)
        let zero = MapRegion(center: PhotoCoordinate(latitude: 0, longitude: 0),
                             latitudeDelta: 0, longitudeDelta: 0)
        XCTAssertTrue(MapClusterBuilder.groups(records: [record(1, lat: 0, lon: 0)],
                                               in: zero).isEmpty)
    }

    func testCoordinateDecodesNumericStringsAndEncodesNumbers() throws {
        let json = Data("{\"latitude\":\"35.5\",\"longitude\":139.25}".utf8)
        let coordinate = try JSONDecoder().decode(PhotoCoordinate.self, from: json)
        XCTAssertEqual(coordinate.latitude, 35.5)
        XCTAssertEqual(coordinate.longitude, 139.25)
        XCTAssertTrue(coordinate.isValid)

        let encoded = try JSONEncoder().encode(coordinate)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Double])
        XCTAssertEqual(object["latitude"], 35.5)
        XCTAssertEqual(object["longitude"], 139.25)
    }
}
