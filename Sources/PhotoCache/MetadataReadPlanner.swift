import Foundation
import SynologyAPI

public struct DayPageRead: Sendable, Equatable {
    public let address: DayPageAddress
    public let dayCount: Int
    public let membershipGeneration: UInt64
    public init(address: DayPageAddress, dayCount: Int, membershipGeneration: UInt64) throws {
        guard dayCount > address.offset, dayCount <= CollectionDayCatalog.maximumItems else { throw CollectionCatalogError.invalidCount }
        self.address = address; self.dayCount = dayCount; self.membershipGeneration = membershipGeneration
    }
    public var count: Int { min(address.capacity, dayCount - address.offset) }
}
public struct CollectionReadBatch: Sendable {
    public let request: CollectionPageRequest
    public let pages: [DayPageRead]
    public let profile: ItemFieldProfile

    /// Preserves server order, refuses geometry drift, and never drops extra IDs.
    public func materialize(_ result: CollectionBatchResult) throws -> [[PhotoItem]] {
        guard result.profile == profile, result.items.count == request.limit,
              Set(result.items.map(\.id)).count == result.items.count else { throw CollectionCatalogError.invalidCoverage }
        var position = 0
        var materialized: [[PhotoItem]] = []
        for page in pages {
            let slice = Array(result.items[position..<(position + page.count)])
            guard try slice.allSatisfy({ try CaptureDay(time: $0.time) == page.address.day }) else {
                throw CollectionCatalogError.invalidCoverage
            }
            materialized.append(slice)
            position += page.count
        }
        guard position == result.items.count else { throw CollectionCatalogError.invalidCoverage }
        return materialized
    }
}

/// Pure transport planning. A demand is never padded merely to fill a network packet.
public enum MetadataReadPlanner {
    public static let maximumItems = 1000
    public static let maximumDays = 32
    public static let lookupBatchSize = 100

    public static func plan(demands: [DayPageRead], catalog: CollectionDayCatalog,
                            profile: ItemFieldProfile) throws -> [CollectionReadBatch] {
        let dayPositions = Dictionary(uniqueKeysWithValues: catalog.days.enumerated().map { ($0.element.day, $0.offset) })
        let counts = Dictionary(uniqueKeysWithValues: catalog.days.map { ($0.day, $0.count) })
        var unique: [DayPageAddress: DayPageRead] = [:]
        for demand in demands {
            guard counts[demand.address.day] == demand.dayCount else { throw CollectionCatalogError.invalidCoverage }
            if let prior = unique[demand.address], prior != demand { throw CollectionCatalogError.invalidCoverage }
            unique[demand.address] = demand
        }
        let sorted = unique.values.sorted {
            if $0.address.collection.rawValue != $1.address.collection.rawValue { return $0.address.collection.rawValue < $1.address.collection.rawValue }
            if $0.address.order.rawValue != $1.address.order.rawValue { return $0.address.order.rawValue < $1.address.order.rawValue }
            if $0.address.day != $1.address.day { return $0.address.day > $1.address.day }
            return $0.address.offset < $1.address.offset
        }
        var groups: [[DayPageRead]] = []
        for demand in sorted {
            if let last = groups.last, let tail = last.last, let head = last.first {
                let samePredicate = head.address.collection == demand.address.collection && head.address.order == demand.address.order
                let count = last.reduce(0) { $0 + $1.count }
                let distinctDays = Set(last.map { $0.address.day }).count
                let sameDay = tail.address.day == demand.address.day
                let contiguous = sameDay
                    ? tail.address.offset + tail.count == demand.address.offset
                    : head.address.offset == 0 && tail.address.offset + tail.count == tail.dayCount && demand.address.offset == 0 &&
                      dayPositions[demand.address.day] == dayPositions[tail.address.day].map { $0 + 1 }
                if samePredicate && contiguous && count + demand.count <= maximumItems &&
                    (sameDay || distinctDays < maximumDays) {
                    groups[groups.count - 1].append(demand)
                    continue
                }
            }
            groups.append([demand])
        }
        return try groups.map { pages in
            let first = pages.first!, last = pages.last!
            return CollectionReadBatch(request: try CollectionPageRequest(
                collection: first.address.collection, order: first.address.order,
                newestDay: first.address.day, oldestDay: last.address.day,
                offset: first.address.offset, limit: pages.reduce(0) { $0 + $1.count }
            ), pages: pages, profile: profile)
        }
    }
}
