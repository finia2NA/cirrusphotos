import Foundation
import SynologyAPI

public enum ResourceEvent<Value: Sendable>: Sendable {
    case value(Value, verified: Bool)
    case failure(RepositoryError)
}

public enum AuthenticationStatus: Sendable, Equatable {
    case notStarted
    case loggingIn
    case signedIn
    /// The NAS rejected the sign-in. It is not retried until the user asks.
    case failed(String)
    /// The NAS could not be reached. The next request tries again.
    case unreachable(String)
    /// The NAS no longer accepts the stored credentials or trusted device.
    /// Only signing in again resolves it.
    case needsSignIn(String)
    /// macOS could not verify the NAS certificate; the user decides whether to trust
    /// this one (SHA-256 of the leaf certificate).
    case untrustedCertificate(sha256: String)
}

public struct FavoriteChange: Sendable {
    public let values: [Int64: Bool]
    public let sourceSection: TimelineSection?
    public let sourceCollection: PhotoCollectionDescriptor

    public init(values: [Int64: Bool], sourceSection: TimelineSection? = nil, sourceCollection: PhotoCollectionDescriptor) {
        self.values = values
        self.sourceSection = sourceSection
        self.sourceCollection = sourceCollection
    }
}

public struct PhotoItemChange: Sendable {
    public let scope: PhotoContentScope
    public let items: [Int64: PhotoItem]
    public let quarterTurns: [Int64: Int]
    public let favoriteValues: [Int64: Bool]
    /// Authoritative ratings and tags, applied to displayed items without touching other fields.
    public let annotations: [Int64: PhotoAnnotations]

    public init(items: [Int64: PhotoItem], quarterTurns: [Int64: Int] = [:], favoriteValues: [Int64: Bool] = [:],
                annotations: [Int64: PhotoAnnotations] = [:], scope: PhotoContentScope = .space(.personal)) {
        self.scope = scope
        self.items = items
        self.quarterTurns = quarterTurns
        self.favoriteValues = favoriteValues
        self.annotations = annotations
    }
}

/// A rating or tag edit applied to a verified selection.
public enum PhotoAnnotationEdit: Sendable, Equatable {
    case rating(Int)
    case addTags([PhotoTag])
    case removeTags([PhotoTag])
}

/// A verified selection for a rating or tag edit.
public struct SelectionAnnotationAction: Sendable {
    public let itemIDs: [Int64]
    public let collection: PhotoCollectionDescriptor
    public let itemsByID: [Int64: PhotoItem]
    public let expectedTimelineFingerprint: String?

    public init(itemIDs: [Int64], collection: PhotoCollectionDescriptor, itemsByID: [Int64: PhotoItem],
                expectedTimelineFingerprint: String? = nil) {
        self.itemIDs = itemIDs
        self.collection = collection
        self.itemsByID = itemsByID
        self.expectedTimelineFingerprint = expectedTimelineFingerprint
    }

    public var items: [PhotoItem] { itemIDs.compactMap { itemsByID[$0] } }

    /// The same edit target for a subset of its items, for retrying failed ones. Ratings and tag
    /// changes are absolute, so a repeat is safe; the subset is not tied to the original timeline.
    public func restricted(to ids: Set<Int64>) -> SelectionAnnotationAction {
        SelectionAnnotationAction(itemIDs: itemIDs.filter(ids.contains), collection: collection,
                                  itemsByID: itemsByID.filter { ids.contains($0.key) })
    }

    /// The rating shared by every item, or nil when they differ.
    public var commonRating: Int? {
        let ratings = Set(items.map(\.rating))
        return ratings.count == 1 ? ratings.first : nil
    }

    /// Tags carried by at least one item, ordered by name.
    public var presentTags: [PhotoTag] {
        Dictionary(items.flatMap(\.tags).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public struct SelectionRotationAction: Sendable {
    public let itemIDs: [Int64]
    public let sectionsByID: [Int64: TimelineSection]
    public let collection: PhotoCollectionDescriptor
    public let itemsByID: [Int64: PhotoItem]
    public let expectedTimelineFingerprint: String?

    public init(itemIDs: [Int64], sectionsByID: [Int64: TimelineSection],
                collection: PhotoCollectionDescriptor, itemsByID: [Int64: PhotoItem],
                expectedTimelineFingerprint: String? = nil) {
        self.itemIDs = itemIDs
        self.sectionsByID = sectionsByID
        self.collection = collection
        self.itemsByID = itemsByID
        self.expectedTimelineFingerprint = expectedTimelineFingerprint
    }
}

public struct ThumbnailRotationProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case preparing, downloading, analyzing, rotating, uploading, refreshing, finished
    }
    public let completedItems: Int
    public let totalItems: Int
    public let itemID: Int64?
    public let stage: Stage
    public let failures: [String]
    /// Progress within the current photo, independent of the batch position.
    public let itemProgress: Double
    public let activity: [String]
    public let detail: String?

    public init(completedItems: Int, totalItems: Int, itemID: Int64?, stage: Stage,
                failures: [String] = [], itemProgress: Double = 0,
                activity: [String] = [], detail: String? = nil) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.itemID = itemID
        self.stage = stage
        self.failures = failures
        self.itemProgress = min(1, max(0, itemProgress))
        self.activity = activity
        self.detail = detail
    }
}

public struct SelectionFavoriteAction: Sendable {
    public let affectedIDs: [Int64]
    public let targetFavorite: Bool
    public let sectionsByID: [Int64: TimelineSection]
    public let collection: PhotoCollectionDescriptor
    public let itemsByID: [Int64: PhotoItem]
    public let expectedTimelineFingerprint: String?

    public init(
        affectedIDs: [Int64],
        targetFavorite: Bool,
        sectionsByID: [Int64: TimelineSection],
        collection: PhotoCollectionDescriptor,
        itemsByID: [Int64: PhotoItem] = [:],
        expectedTimelineFingerprint: String? = nil
    ) {
        self.affectedIDs = affectedIDs
        self.targetFavorite = targetFavorite
        self.sectionsByID = sectionsByID
        self.collection = collection
        self.itemsByID = itemsByID
        self.expectedTimelineFingerprint = expectedTimelineFingerprint
    }

    /// The same change for a subset of its items, for retrying failed ones. The target value is
    /// absolute, so it is safe to repeat; the subset is not tied to the original timeline.
    public func restricted(to ids: Set<Int64>) -> SelectionFavoriteAction {
        SelectionFavoriteAction(affectedIDs: affectedIDs.filter(ids.contains), targetFavorite: targetFavorite,
                                sectionsByID: sectionsByID.filter { ids.contains($0.key) }, collection: collection,
                                itemsByID: itemsByID.filter { ids.contains($0.key) })
    }
}

public struct BatchFavoriteOutcome: Sendable, Equatable {
    /// Failed and never-submitted IDs, in submission order.
    public let failedIDs: [Int64]
    public let successfulCount: Int
    public var failedCount: Int { failedIDs.count }

    public init(successfulCount: Int, failedIDs: [Int64]) {
        self.successfulCount = successfulCount
        self.failedIDs = failedIDs
    }
}

public struct BatchFavoriteError: LocalizedError, Sendable {
    public let outcome: BatchFavoriteOutcome
    public let underlyingError: any Error

    public init(outcome: BatchFavoriteOutcome, underlyingError: any Error) {
        self.outcome = outcome
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        "Favorite update failed (\(outcome.successfulCount) updated, \(outcome.failedCount) failed): \(underlyingError.localizedDescription)"
    }
}

struct SharedJob<Value: Sendable> {
    let id: UUID
    let task: Task<Value, Error>
    var subscribers: Set<UUID>
}

struct ImageResolution: Sendable {
    let data: Data
    let outcome: ThumbnailCacheOutcome
    let downloadedBytes: Int
}

struct FullImageResolution: Sendable {
    let data: Data
}

struct VideoWindowJob: Sendable {
    let id: UUID
    let resourceKey: String
    let range: ClosedRange<Int64>
    let window: VideoWindow
}

public enum ThumbnailCacheOutcome: Sendable, Equatable {
    case fetched
    case reused
    case cacheWriteFailed
}

public struct ThumbnailCacheMeasurement: Sendable, Equatable {
    public let outcome: ThumbnailCacheOutcome
    public let downloadedBytes: Int

    public init(outcome: ThumbnailCacheOutcome, downloadedBytes: Int) {
        self.outcome = outcome
        self.downloadedBytes = downloadedBytes
    }
}

public struct ThumbnailRenditionValue: Sendable, Equatable {
    public let data: Data
    public let size: ThumbnailSize
    public let isExact: Bool

    public init(data: Data, size: ThumbnailSize, isExact: Bool) {
        self.data = data
        self.size = size
        self.isExact = isExact
    }
}

public enum ThumbnailCachePurpose: Sendable, Equatable {
    case library
    case viewerPreview

    var kind: CacheKind {
        switch self {
        case .library: .thumbnail
        case .viewerPreview: .previewThumbnail
        }
    }
}

final class StreamProducer: @unchecked Sendable {
    var task: Task<Void, Never>?
}
