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
    public let itemID: Int64
    public let section: TimelineSection
    public let favorite: Bool
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
