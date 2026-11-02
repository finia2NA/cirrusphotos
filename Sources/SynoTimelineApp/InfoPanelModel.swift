import Foundation
import PhotoCache
import SynologyAPI
import TimelineCore

/// One info-panel map pin. `id` is the item id when known, otherwise the selection index.
struct InfoPanelPin: Equatable {
    let id: Int64
    let coordinate: PhotoCoordinate
}

struct InfoPanelContent: Equatable {
    enum Kind: Equatable {
        case empty
        case multiple
        case single
        case failure(String)
    }

    var kind: Kind = .empty
    var isLoading = false
    var countText = ""
    var dateRangeText = ""
    var sizeText: String?
    var isResolvingSize = false
    var filename: String?
    var mediaKind: PhotoMediaKind?
    var itemIDText: String?
    var folderPath: String?
    var dateTimeText: String?
    var camera: String?
    var lens: String?
    var metrics: [String] = []
    var formatBadge: String?
    var exposure: [String] = []
    var durationText: String?
    var pins: [InfoPanelPin] = []
}

@MainActor
final class InfoPanelModel: ObservableObject {
    @Published private(set) var content = InfoPanelContent()
    @Published private(set) var isVisible = false

    private struct ResolutionKey: Equatable {
        var repositoryID: ObjectIdentifier?
        var collection: PhotoCollectionDescriptor
        var selection: IndexSet
        var fingerprint: String?
    }

    private var visible = false
    private var viewerActive = false
    private var viewerItem: PhotoItem?
    private var browserRepository: CachedPhotosRepository?
    private var browserSnapshot: TimelineSnapshot?
    private var browserIndex: LibraryIndex?
    private var browserCollection: PhotoCollectionDescriptor = .library(.personal)
    private var browserSelection = IndexSet()
    private var lastKey: ResolutionKey?
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        isVisible = value
        if value {
            refreshBrowser(resolveImmediately: true)
        } else {
            generation &+= 1
            // Closing the panel cancels resolution. Force the same context to restart
            // when the panel reopens instead of treating the canceled key as complete.
            lastKey = nil
            cancelBrowserWork()
        }
    }

    func updateBrowserContext(repository: CachedPhotosRepository?, snapshot: TimelineSnapshot?,
                              collection: PhotoCollectionDescriptor, selection: IndexSet) {
        browserRepository = repository
        browserCollection = collection
        browserSelection = selection
        if browserSnapshot?.sections != snapshot?.sections {
            browserSnapshot = snapshot
            browserIndex = snapshot.map(LibraryIndex.init(snapshot:))
        }
        refreshBrowser(resolveImmediately: false)
    }

    /// Clears browser state for the albums overview, where no collection is being browsed.
    func clearBrowserContext() {
        browserRepository = nil
        browserSnapshot = nil
        browserIndex = nil
        browserSelection = []
        lastKey = nil
        generation &+= 1
        cancelBrowserWork()
        if !viewerActive { content = InfoPanelContent() }
    }

    func updateViewer(active: Bool, item: PhotoItem?) {
        guard active else {
            guard viewerActive else { return }
            viewerActive = false
            viewerItem = nil
            lastKey = nil
            refreshBrowser(resolveImmediately: true)
            return
        }
        // The viewer re-emits the same identity when cached metadata is replaced by
        // verified metadata. Compare the complete item so EXIF and size updates reach
        // the panel even though navigation did not change.
        let unchanged = viewerActive && viewerItem == item
        cancelBrowserWork()
        guard !unchanged else { return }
        generation &+= 1
        lastKey = nil
        viewerActive = true
        viewerItem = item
        content = item.map(Self.singleContent(from:)) ?? Self.loadingContent()
    }

    private func refreshBrowser(resolveImmediately: Bool) {
        guard visible, !viewerActive else {
            cancelBrowserWork()
            return
        }
        let key = ResolutionKey(repositoryID: browserRepository.map(ObjectIdentifier.init),
                                collection: browserCollection,
                                selection: browserSelection,
                                fingerprint: browserIndex?.fingerprint)
        guard key != lastKey else { return }
        lastKey = key
        generation &+= 1
        cancelBrowserWork()
        publishBrowserSummary()
        guard browserRepository != nil, browserSnapshot != nil, !browserSelection.isEmpty else { return }
        let current = generation
        if resolveImmediately {
            startResolution(generation: current)
        } else {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.startResolution(generation: current)
            }
        }
    }

    private func publishBrowserSummary() {
        guard !browserSelection.isEmpty else {
            content = InfoPanelContent()
            return
        }
        guard browserRepository != nil, let index = browserIndex else {
            content = Self.failureContent("Library unavailable")
            return
        }
        if browserSelection.count == 1 {
            content = Self.loadingContent()
            return
        }
        let locations = browserSelection.compactMap { index.location(forOrdinal: $0) }
        var summary = InfoPanelContent()
        summary.kind = .multiple
        summary.countText = "\(browserSelection.count) Items"
        summary.dateRangeText = InfoPanelFormatting.dayRange(newest: locations.map(\.dayID).max(),
                                                             oldest: locations.map(\.dayID).min()) ?? ""
        summary.isResolvingSize = true
        content = summary
    }

    private func startResolution(generation expected: UInt64) {
        guard visible, !viewerActive, expected == generation,
              let repository = browserRepository, let snapshot = browserSnapshot,
              !browserSelection.isEmpty else { return }
        let stream = SelectionInfoResolver(repository: repository).resolve(
            collection: browserCollection, snapshot: snapshot,
            selectedOrdinals: browserSelection)
        resolveTask = Task { [weak self] in
            for await info in stream {
                guard !Task.isCancelled else { return }
                self?.apply(info, generation: expected)
            }
        }
    }

    private func cancelBrowserWork() {
        debounceTask?.cancel()
        debounceTask = nil
        resolveTask?.cancel()
        resolveTask = nil
    }

    private func apply(_ info: SelectionInfo, generation expected: UInt64) {
        guard expected == generation, visible, !viewerActive else { return }
        guard info.itemCount == browserSelection.count else { return }
        if info.itemCount <= 1 {
            if let item = info.singleItem {
                content = Self.singleContent(from: item)
            } else if info.isComplete && info.hadFailure {
                content = Self.failureContent("Info unavailable")
            }
            return
        }
        var next = content
        next.kind = .multiple
        next.countText = "\(info.itemCount) \(Self.countNoun(for: info))"
        if let range = InfoPanelFormatting.dayRange(newest: info.newestDayID, oldest: info.oldestDayID) {
            next.dateRangeText = range
        }
        if let size = info.cumulativeSize {
            next.sizeText = InfoPanelFormatting.byteCount(size)
            next.isResolvingSize = false
        } else if info.isComplete {
            next.sizeText = "—"
            next.isResolvingSize = false
        } else {
            next.sizeText = nil
            next.isResolvingSize = true
        }
        next.pins = info.coordinates.enumerated().map {
            InfoPanelPin(id: Int64($0.offset), coordinate: $0.element)
        }
        content = next
    }

    private static func countNoun(for info: SelectionInfo) -> String {
        guard info.isComplete, !info.hadFailure, info.resolvedCount == info.itemCount else { return "Items" }
        if info.videoCount == info.itemCount { return "Videos" }
        if info.photoCount == info.itemCount { return "Photos" }
        return "Items"
    }

    private static func loadingContent() -> InfoPanelContent {
        var content = InfoPanelContent()
        content.kind = .single
        content.isLoading = true
        return content
    }

    private static func failureContent(_ message: String) -> InfoPanelContent {
        var content = InfoPanelContent()
        content.kind = .failure(message)
        return content
    }

    private static func singleContent(from item: PhotoItem) -> InfoPanelContent {
        var content = InfoPanelContent()
        content.kind = .single
        content.filename = item.filename
        content.mediaKind = item.mediaKind
        content.itemIDText = String(item.id)
        content.folderPath = item.additional?.folderPath
        content.dateTimeText = InfoPanelFormatting.singleDateTime(item.time)
        content.formatBadge = item.filename.flatMap(InfoPanelFormatting.formatBadge(filename:))
        content.metrics = metrics(for: item)
        content.pins = item.coordinate.map { [InfoPanelPin(id: item.id, coordinate: $0)] } ?? []
        if item.isVideo {
            content.durationText = item.additional?.videoMeta?.duration.map(InfoPanelFormatting.duration)
            return content
        }
        let exif = item.additional?.exif
        content.camera = exif?.camera
        content.lens = exif?.lens
        content.exposure = exposureValues(from: exif)
        return content
    }

    private static func metrics(for item: PhotoItem) -> [String] {
        var values: [String] = []
        if let resolution = item.additional?.resolution {
            if let megapixels = InfoPanelFormatting.megapixels(width: resolution.width,
                                                               height: resolution.height) {
                values.append(megapixels)
            }
            values.append("\(resolution.width) × \(resolution.height)")
        }
        if let size = item.filesize, size > 0 {
            values.append(InfoPanelFormatting.byteCount(size))
        }
        return values
    }

    private static func exposureValues(from exif: ExifInfo?) -> [String] {
        guard let exif else { return [] }
        var values: [String] = []
        if let iso = exif.iso { values.append("ISO \(iso)") }
        if let focalLength = exif.focalLength { values.append(focalLength) }
        if let aperture = exif.aperture { values.append(InfoPanelFormatting.apertureValue(aperture)) }
        if let shutter = exif.exposureTime { values.append(shutter) }
        return values
    }
}
