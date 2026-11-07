import Foundation
import PhotoCache
import SynologyAPI

/// Every persisted user preference and its key. Views that bind with `@AppStorage`
/// use the keys declared here so no preference name is spelled twice.
@MainActor
final class AppPreferences: ObservableObject {
    enum Key {
        static let thumbnailSize = "thumbnailSize"
        static let loadsLargeViewerPreviews = "loadsLargeViewerPreviews"
        static let pixelInterpolation = "pixelInterpolation"
        static let videoMuted = "videoMuted"
        static let videoQuality = "videoQuality"
        static let itemsPerRow = "itemsPerRow"
        static let cropsThumbnailsToSquare = "cropsThumbnailsToSquare"
        static let groupsByDay = "groupsByDay"
        static let alwaysShowsTimeline = "alwaysShowsTimeline"
        static let cacheBudget = "cacheBudget"
        static let photoDownloadDirectory = "photoDownloadDirectory"
        static let viewerHighlightThreshold = "viewerHighlightThreshold"
        static let viewerFocusEdgeTolerance = "viewerFocusEdgeTolerance"
        static let viewerHistogramShowsColor = "viewerHistogramShowsColor"
        static let warmingIncludesSharedSpace = "warmingIncludesSharedSpace"
        static let showsViewerToolbarTools = "showsViewerToolbarTools"
    }

    static let itemsPerRowRange = 3...10

    private let defaults: UserDefaults

    @Published var thumbnailSize: ThumbnailSize { didSet { defaults.set(thumbnailSize.rawValue, forKey: Key.thumbnailSize) } }
    @Published var loadsLargeViewerPreviews: Bool { didSet { defaults.set(loadsLargeViewerPreviews, forKey: Key.loadsLargeViewerPreviews) } }
    @Published var pixelInterpolation: PixelInterpolationPreference { didSet { defaults.set(pixelInterpolation.rawValue, forKey: Key.pixelInterpolation) } }
    @Published var videoMuted: Bool { didSet { defaults.set(videoMuted, forKey: Key.videoMuted) } }
    @Published var videoQuality: VideoQualityPreference { didSet { defaults.set(videoQuality.rawValue, forKey: Key.videoQuality) } }
    @Published var itemsPerRow: Int {
        didSet {
            let valid = itemsPerRow.clamped(to: Self.itemsPerRowRange)
            if valid != itemsPerRow { itemsPerRow = valid }
            defaults.set(valid, forKey: Key.itemsPerRow)
        }
    }
    @Published var cropsThumbnailsToSquare: Bool { didSet { defaults.set(cropsThumbnailsToSquare, forKey: Key.cropsThumbnailsToSquare) } }
    @Published var groupsByDay: Bool { didSet { defaults.set(groupsByDay, forKey: Key.groupsByDay) } }
    @Published var alwaysShowsTimeline: Bool { didSet { defaults.set(alwaysShowsTimeline, forKey: Key.alwaysShowsTimeline) } }
    @Published var showsViewerToolbarTools: Bool { didSet { defaults.set(showsViewerToolbarTools, forKey: Key.showsViewerToolbarTools) } }
    /// The cache budget as a fraction of the slider range; the stored value is bytes.
    @Published var budgetFraction: Double { didSet { defaults.set(Int(budgetBytes), forKey: Key.cacheBudget) } }

    var budgetBytes: Int64 { CacheBudget.bytes(at: budgetFraction) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thumbnailSize = defaults.string(forKey: Key.thumbnailSize).flatMap(ThumbnailSize.init(rawValue:)) ?? .m
        loadsLargeViewerPreviews = defaults.bool(forKey: Key.loadsLargeViewerPreviews)
        pixelInterpolation = defaults.string(forKey: Key.pixelInterpolation).flatMap(PixelInterpolationPreference.init(rawValue:)) ?? .off
        videoMuted = defaults.bool(forKey: Key.videoMuted)
        videoQuality = defaults.string(forKey: Key.videoQuality).flatMap(VideoQualityPreference.init(rawValue:)) ?? .automatic
        itemsPerRow = (defaults.object(forKey: Key.itemsPerRow) as? NSNumber)?.intValue.clamped(to: Self.itemsPerRowRange) ?? 6
        cropsThumbnailsToSquare = defaults.bool(forKey: Key.cropsThumbnailsToSquare)
        groupsByDay = defaults.object(forKey: Key.groupsByDay) as? Bool ?? true
        alwaysShowsTimeline = defaults.bool(forKey: Key.alwaysShowsTimeline)
        showsViewerToolbarTools = defaults.bool(forKey: Key.showsViewerToolbarTools)
        budgetFraction = CacheBudget.fraction(for: Int64(defaults.object(forKey: Key.cacheBudget) as? Int ?? Int(CacheBudget.bytes(at: 0.5))))
    }

    func adjustItemsPerRow(by amount: Int) {
        itemsPerRow = (itemsPerRow + amount).clamped(to: Self.itemsPerRowRange)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
