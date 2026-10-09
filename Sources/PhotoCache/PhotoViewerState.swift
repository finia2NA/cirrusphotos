import Foundation
import SynologyAPI

public struct PhotoViewerLocation: Sendable, Equatable, Hashable {
    public let sectionIndex: Int
    public let pageOffset: Int
    public let ordinal: Int

    public init(sectionIndex: Int, pageOffset: Int, ordinal: Int) {
        self.sectionIndex = sectionIndex
        self.pageOffset = pageOffset
        self.ordinal = ordinal
    }
}

/// The grid supplies the exact page coordinate because a visual row may span API pages.
public struct PhotoViewerSeed: Sendable {
    public let sectionIndex: Int
    public let pageOffset: Int
    public let item: PhotoItem
    public let page: [PhotoItem]?
    public let pageVerified: Bool

    public init(sectionIndex: Int, pageOffset: Int, item: PhotoItem,
                page: [PhotoItem]? = nil, pageVerified: Bool = false) {
        self.sectionIndex = sectionIndex
        self.pageOffset = pageOffset
        self.item = item
        self.page = page
        self.pageVerified = pageVerified
    }
}

public struct PhotoViewerSelection: Sendable, Equatable {
    public let generation: UInt64
    public let itemID: Int64?

    public init(generation: UInt64, itemID: Int64?) {
        self.generation = generation
        self.itemID = itemID
    }
}

public enum PhotoViewerResourceStatus: Sendable, Equatable {
    case idle
    case loading
    /// Cached data remains usable when its attempted validation fails.
    case ready(verified: Bool, validationFailure: String?)
    case failure(String)
    case unsupported(String)
}

public struct PhotoViewerState: Sendable {
    public let selection: PhotoViewerSelection
    public let desiredLocation: PhotoViewerLocation
    public let item: PhotoItem?
    public let metadataVerified: Bool
    public let thumbnailData: Data?
    public let fullImageData: Data?
    public let videoResource: VideoPlaybackResource?
    public let metadataStatus: PhotoViewerResourceStatus
    public let thumbnailStatus: PhotoViewerResourceStatus
    public let fullImageStatus: PhotoViewerResourceStatus
    public let isLoadingLargePreview: Bool
    public let canNavigatePrevious: Bool
    public let canNavigateNext: Bool
    public let allowNetwork: Bool
    public let favoriteUpdating: Bool
    public let favoriteFailure: String?
    public let isClosed: Bool
}
