import Foundation
import SynologyAPI

public enum ResourceEvent<Value: Sendable>: Sendable {
    case value(Value, verified: Bool)
    case failure(String)
}

public enum AuthenticationStatus: Sendable, Equatable {
    case notStarted
    case loggingIn
    case signedIn
    case failed(String)
}

public struct FavoriteChange: Sendable {
    public let values: [Int64: Bool]
    public let sourceSection: TimelineSection?
    public let sourceCollection: PhotoCollectionDescriptor

    public init(values: [Int64: Bool], sourceSection: TimelineSection? = nil, sourceCollection: PhotoCollectionDescriptor = .personalLibrary) {
        self.values = values
        self.sourceSection = sourceSection
        self.sourceCollection = sourceCollection
    }
}

public struct PhotoItemChange: Sendable {
    public let items: [Int64: PhotoItem]
    public let quarterTurns: [Int64: Int]

    public init(items: [Int64: PhotoItem], quarterTurns: [Int64: Int] = [:]) {
        self.items = items
        self.quarterTurns = quarterTurns
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
}

public struct BatchFavoriteOutcome: Sendable, Equatable {
    public let successfulCount: Int
    public let failedCount: Int

    public init(successfulCount: Int, failedCount: Int) {
        self.successfulCount = successfulCount
        self.failedCount = failedCount
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
