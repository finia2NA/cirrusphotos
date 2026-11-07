import Foundation

/// Named retention classes shared by every disk-cache resource. The order is defined
/// separately so adding a class does not silently change an existing persisted raw value.
public enum CacheRetentionClass: String, CaseIterable, Sendable {
    case activeTimeline
    case metadataPage
    case configuredThumbnail
    case smallerFallbackThumbnail
    case fullImage
    case optionalThumbnail
    case videoPlayback
    case locationIndex
}

/// The single source of truth for disk-cache retention. Entries later in this list are
/// discarded before entries earlier in the list. Network scheduling priorities are separate.
public enum CachePriorityPolicy {
    public static let highestToLowest: [CacheRetentionClass] = [
        .activeTimeline,
        .locationIndex,
        .metadataPage,
        .configuredThumbnail,
        .smallerFallbackThumbnail,
        .fullImage,
        .optionalThumbnail,
        .videoPlayback,
    ]

    static var lowestToHighest: [CacheRetentionClass] {
        Array(highestToLowest.reversed())
    }

    static func evictionRank(for retentionClass: CacheRetentionClass) -> Int {
        lowestToHighest.firstIndex(of: retentionClass) ?? lowestToHighest.count
    }

    static func defaultClass(for kind: CacheKind) -> CacheRetentionClass {
        switch kind {
        case .previewThumbnail: .optionalThumbnail
        case .fullImage: .fullImage
        case .thumbnail: .configuredThumbnail
        case .videoSegment: .videoPlayback
        }
    }
}
