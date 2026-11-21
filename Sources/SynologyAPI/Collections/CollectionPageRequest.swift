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
    /// The first item's position in the whole collection, newest first. Folder pages are read
    /// by it, because the NAS ignores the day range with `folder_id` for folder-only accounts.
    public let collectionOffset: Int?
    public init(collection: PhotoCollectionDescriptor, order: CollectionOrder,
                newestDay: CaptureDay, oldestDay: CaptureDay, offset: Int, limit: Int, collectionOffset: Int? = nil) throws {
        guard oldestDay <= newestDay, offset >= 0, limit > 0, limit <= 1000,
              offset <= CollectionDayCatalog.maximumItems - limit else { throw CollectionCatalogError.invalidAddress }
        if let collectionOffset {
            guard collectionOffset >= offset, collectionOffset <= CollectionDayCatalog.maximumItems - limit else { throw CollectionCatalogError.invalidAddress }
        }
        self.collection = collection; self.order = order; self.newestDay = newestDay; self.oldestDay = oldestDay
        self.offset = offset; self.limit = limit; self.collectionOffset = collectionOffset
    }
}
public struct CollectionBatchResult: Sendable {
    public let items: [PhotoItem]
    public let profile: ItemFieldProfile
    public init(items: [PhotoItem], profile: ItemFieldProfile) {
        self.items = items; self.profile = profile
    }
}
