import Foundation
import PhotoCache
import SynologyAPI

/// Every persisted user preference and its key. Views that bind with `@AppStorage`
/// use the keys declared here so no preference name is spelled twice.
@MainActor
final class AppPreferences: ObservableObject {
    enum Key {
        static let thumbnailSize = "thumbnailSize"
        static let viewerImageQuality = "viewerImageQuality"
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
        static let showsFilmstrip = "showsFilmstrip"
        static let showsHistogram = "showsHistogram"
        static let showsHighlightPeaking = "showsHighlightPeaking"
        static let showsFocusEdges = "showsFocusEdges"
        static let setupPreferencesConfirmed = "setupPreferencesConfirmed"
    }

    static let itemsPerRowRange = 3...10

    private let defaults: UserDefaults

    /// Whether the sign-in setup's thumbnail and cache size page was completed on this Mac.
    /// Later sign-ins skip it.
    var hasConfirmedSetupPreferences: Bool {
        get { defaults.bool(forKey: Key.setupPreferencesConfirmed) }
        set { defaults.set(newValue, forKey: Key.setupPreferencesConfirmed) }
    }

    @Published var thumbnailSize: ThumbnailSize { didSet { defaults.set(thumbnailSize.rawValue, forKey: Key.thumbnailSize) } }
    @Published var viewerImageQuality: ViewerImageQuality { didSet { defaults.set(viewerImageQuality.rawValue, forKey: Key.viewerImageQuality) } }
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
    /// Hiding the toolbar buttons also turns their overlays off, so none stays on without a visible control.
    @Published var showsViewerToolbarTools: Bool {
        didSet {
            defaults.set(showsViewerToolbarTools, forKey: Key.showsViewerToolbarTools)
            guard oldValue, !showsViewerToolbarTools else { return }
            showsFilmstrip = false
            showsHistogram = false
            showsHighlightPeaking = false
            showsFocusEdges = false
        }
    }
    @Published var showsFilmstrip: Bool { didSet { defaults.set(showsFilmstrip, forKey: Key.showsFilmstrip) } }
    @Published var showsHistogram: Bool { didSet { defaults.set(showsHistogram, forKey: Key.showsHistogram) } }
    @Published var showsHighlightPeaking: Bool { didSet { defaults.set(showsHighlightPeaking, forKey: Key.showsHighlightPeaking) } }
    @Published var showsFocusEdges: Bool { didSet { defaults.set(showsFocusEdges, forKey: Key.showsFocusEdges) } }
    /// The cache budget as a fraction of the slider range; the stored value is bytes.
    @Published var budgetFraction: Double { didSet { defaults.set(Int(budgetBytes), forKey: Key.cacheBudget) } }

    var budgetBytes: Int64 { CacheBudget.bytes(at: budgetFraction) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thumbnailSize = defaults.string(forKey: Key.thumbnailSize).flatMap(ThumbnailSize.init(rawValue:)) ?? .m
        viewerImageQuality = defaults.string(forKey: Key.viewerImageQuality).flatMap(ViewerImageQuality.init(rawValue:)) ?? .original
        pixelInterpolation = defaults.string(forKey: Key.pixelInterpolation).flatMap(PixelInterpolationPreference.init(rawValue:)) ?? .off
        videoMuted = defaults.bool(forKey: Key.videoMuted)
        videoQuality = defaults.string(forKey: Key.videoQuality).flatMap(VideoQualityPreference.init(rawValue:)) ?? .automatic
        itemsPerRow = (defaults.object(forKey: Key.itemsPerRow) as? NSNumber)?.intValue.clamped(to: Self.itemsPerRowRange) ?? 6
        cropsThumbnailsToSquare = defaults.bool(forKey: Key.cropsThumbnailsToSquare)
        groupsByDay = defaults.object(forKey: Key.groupsByDay) as? Bool ?? true
        alwaysShowsTimeline = defaults.bool(forKey: Key.alwaysShowsTimeline)
        showsViewerToolbarTools = defaults.bool(forKey: Key.showsViewerToolbarTools)
        showsFilmstrip = defaults.bool(forKey: Key.showsFilmstrip)
        showsHistogram = defaults.bool(forKey: Key.showsHistogram)
        showsHighlightPeaking = defaults.bool(forKey: Key.showsHighlightPeaking)
        showsFocusEdges = defaults.bool(forKey: Key.showsFocusEdges)
        budgetFraction = CacheBudget.fraction(for: Int64(defaults.object(forKey: Key.cacheBudget) as? Int ?? Int(CacheBudget.bytes(at: 0.5))))
    }

    func adjustItemsPerRow(by amount: Int) {
        itemsPerRow = (itemsPerRow + amount).clamped(to: Self.itemsPerRowRange)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
