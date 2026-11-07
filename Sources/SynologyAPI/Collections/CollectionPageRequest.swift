import Foundation

/// Fixed acquisition profiles. Partial reads cannot establish full-detail or annotation authority.
public enum ItemFieldProfile: String, Codable, Sendable {
    case identityAndTime, locations, fullPage
    public var additional: [String] {
        switch self {
        case .identityAndTime: []
        case .locations: PhotosRequestFields.locationScanAdditional
        case .fullPage: PhotosRequestFields.pageAdditional
        }
    }
}

/// A transient range query; its offset is relative to these exact date bounds.
public struct CollectionPageRequest: Sendable, Equatable, Hashable {
    public let collection: PhotoCollectionDescriptor
    public let order: CollectionOrder
    public let newestDay: CaptureDay
    public let oldestDay: CaptureDay
    public let offset: Int
    public let limit: Int
    public init(collection: PhotoCollectionDescriptor, order: CollectionOrder,
                newestDay: CaptureDay, oldestDay: CaptureDay, offset: Int, limit: Int) throws {
        guard oldestDay <= newestDay, offset >= 0, limit > 0, limit <= 1000,
              offset <= CollectionDayCatalog.maximumItems - limit else { throw CollectionCatalogError.invalidAddress }
        self.collection = collection; self.order = order; self.newestDay = newestDay; self.oldestDay = oldestDay
        self.offset = offset; self.limit = limit
    }
}
public struct CollectionBatchResult: Sendable {
    public let items: [PhotoItem]
    public let profile: ItemFieldProfile
    public init(items: [PhotoItem], profile: ItemFieldProfile) {
        self.items = items; self.profile = profile
    }
}
