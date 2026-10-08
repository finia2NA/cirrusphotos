import Foundation

/// A geographic coordinate attached to a photo. Platform-independent so both the
/// API layer and the UI can share one value type.
public struct PhotoCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// False for non-finite values or latitude/longitude out of range.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90.0...90.0).contains(latitude) &&
            (-180.0...180.0).contains(longitude)
    }

    private enum CodingKeys: String, CodingKey { case latitude, longitude }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try Self.decodeNumber(container, forKey: .latitude)
        longitude = try Self.decodeNumber(container, forKey: .longitude)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }

    private static func decodeNumber(_ container: KeyedDecodingContainer<CodingKeys>,
                                     forKey key: CodingKeys) throws -> Double {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let text = try? container.decode(String.self, forKey: key), let value = Double(text) {
            return value
        }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: container, debugDescription: "Expected a numeric coordinate")
    }
}

/// A visible map region expressed in the same terms as MapKit regions.
public struct MapRegion: Sendable, Equatable {
    public let center: PhotoCoordinate
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(center: PhotoCoordinate, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

/// A minimum cluster radius in degrees. Callers derive it from the current viewport
/// so pins cannot be packed tighter than their on-screen size.
public struct MapCellSpan: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One geotagged photo as consumed by the map surface.
public struct MapPhotoRecord: Sendable, Equatable {
    public let id: Int64
    public let time: Int64
    public let coordinate: PhotoCoordinate

    public init(id: Int64, time: Int64, coordinate: PhotoCoordinate) {
        self.id = id
        self.time = time
        self.coordinate = coordinate
    }
}

/// A map annotation: either one photo or a counted cluster of nearby photos.
public struct MapClusterGroup: Sendable, Equatable {
    public let coordinate: PhotoCoordinate
    public let count: Int
    /// Newest member; supplies the pin thumbnail.
    public let representative: MapPhotoRecord
    /// Descending capture time, then descending id for determinism.
    public let memberIDs: [Int64]

    public init(coordinate: PhotoCoordinate, count: Int, representative: MapPhotoRecord,
                memberIDs: [Int64]) {
        self.coordinate = coordinate
        self.count = count
        self.representative = representative
        self.memberIDs = memberIDs
    }

    public var isSingle: Bool { count == 1 }
}

/// Grid-accelerated radius clustering for the map surface.
///
/// Records are visited newest-first and joined to the nearest already-open cluster
/// whose newest member lies within one cell radius on both axes; otherwise they open
/// their own cluster. This never splits two photos that are within the radius of each
/// other just because a grid boundary falls between them, and clusters never chain
/// arbitrarily far the way transitive merging would.
///
/// The radius starts at the finest useful value (viewport span / 512, raised to
/// `minimumCellSpan` when supplied) and doubles until the cluster count fits
/// `maxAnnotations`. Longitude wrap (an antimeridian-spanning region) is not handled;
/// the library does not currently require it.
public enum MapClusterBuilder {
    public static func groups(records: [MapPhotoRecord],
                              in region: MapRegion,
                              maxAnnotations: Int = 256,
                              minimumCellSpan: MapCellSpan? = nil) -> [MapClusterGroup] {
        guard region.latitudeDelta > 0, region.longitudeDelta > 0,
              region.latitudeDelta.isFinite, region.longitudeDelta.isFinite,
              region.center.latitude.isFinite, region.center.longitude.isFinite else { return [] }
        let cap = max(1, maxAnnotations)
        let minLatitude = region.center.latitude - region.latitudeDelta / 2 - region.latitudeDelta * 0.1
        let maxLatitude = region.center.latitude + region.latitudeDelta / 2 + region.latitudeDelta * 0.1
        let minLongitude = region.center.longitude - region.longitudeDelta / 2 - region.longitudeDelta * 0.1
        let maxLongitude = region.center.longitude + region.longitudeDelta / 2 + region.longitudeDelta * 0.1

        let candidates = records.filter {
            $0.coordinate.isValid &&
                $0.coordinate.latitude >= minLatitude && $0.coordinate.latitude <= maxLatitude &&
                $0.coordinate.longitude >= minLongitude && $0.coordinate.longitude <= maxLongitude
        }
        guard !candidates.isEmpty else { return [] }

        let ordered = candidates.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time > rhs.time }
            return lhs.id > rhs.id
        }
        var latitudeCell = max(region.latitudeDelta / 512, minimumCellSpan?.latitude ?? 0)
        var longitudeCell = max(region.longitudeDelta / 512, minimumCellSpan?.longitude ?? 0)
        while true {
            let groups = cluster(ordered: ordered, minLatitude: minLatitude,
                                 minLongitude: minLongitude,
                                 latitudeCell: latitudeCell, longitudeCell: longitudeCell)
            if groups.count <= cap { return groups }
            if latitudeCell >= region.latitudeDelta && longitudeCell >= region.longitudeDelta {
                return groups
            }
            latitudeCell = min(latitudeCell * 2, region.latitudeDelta)
            longitudeCell = min(longitudeCell * 2, region.longitudeDelta)
        }
    }

    private struct CellKey: Hashable {
        let row: Int
        let column: Int
    }

    private static func cluster(ordered: [MapPhotoRecord],
                                minLatitude: Double, minLongitude: Double,
                                latitudeCell: Double,
                                longitudeCell: Double) -> [MapClusterGroup] {
        var membersByCluster: [[MapPhotoRecord]] = []
        var clusterIndicesByCell: [CellKey: [Int]] = [:]
        for record in ordered {
            let row = Int(floor((record.coordinate.latitude - minLatitude) / latitudeCell))
            let column = Int(floor((record.coordinate.longitude - minLongitude) / longitudeCell))
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for rowOffset in -1...1 {
                for columnOffset in -1...1 {
                    guard let indices = clusterIndicesByCell[CellKey(row: row + rowOffset,
                                                                     column: column + columnOffset)]
                    else { continue }
                    for index in indices {
                        guard let representative = membersByCluster[index].first else { continue }
                        let latitudeDistance = abs(representative.coordinate.latitude
                                                   - record.coordinate.latitude)
                        let longitudeDistance = abs(representative.coordinate.longitude
                                                     - record.coordinate.longitude)
                        guard latitudeDistance <= latitudeCell,
                              longitudeDistance <= longitudeCell else { continue }
                        let distance = latitudeDistance * latitudeDistance
                            + longitudeDistance * longitudeDistance
                        if distance < bestDistance {
                            bestDistance = distance
                            bestIndex = index
                        }
                    }
                }
            }
            if let bestIndex {
                membersByCluster[bestIndex].append(record)
            } else {
                clusterIndicesByCell[CellKey(row: row, column: column), default: []]
                    .append(membersByCluster.count)
                membersByCluster.append([record])
            }
        }
        var groups: [MapClusterGroup] = []
        groups.reserveCapacity(membersByCluster.count)
        for members in membersByCluster {
            guard let representative = members.first else { continue }
            groups.append(MapClusterGroup(coordinate: representative.coordinate,
                                          count: members.count,
                                          representative: representative,
                                          memberIDs: members.map(\.id)))
        }
        return groups.sorted { lhs, rhs in
            if lhs.representative.time != rhs.representative.time {
                return lhs.representative.time > rhs.representative.time
            }
            return lhs.representative.id > rhs.representative.id
        }
    }
}
