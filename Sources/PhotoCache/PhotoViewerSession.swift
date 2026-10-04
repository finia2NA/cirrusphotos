import Foundation
import SynologyAPI

/// Owns one viewer's bounded metadata and encoded-image work for one immutable LibraryIndex.
/// Recreate the session when the app replaces that index during cached-to-server validation.
/// All callbacks are checked against request identities in addition to task cancellation,
/// so a late result cannot replace a newer selection.
public actor PhotoViewerSession {
    var metadata: ViewerMetadataWindow
    var images = ViewerImageWork()

    let repository: CachedPhotosRepository
    let collection: PhotoCollectionDescriptor
    let index: LibraryIndex
    let thumbnailSize: ThumbnailSize
    let loadsLargePreviews: Bool

    var allowNetwork: Bool
    var desired: PhotoViewerLocation
    var generation: UInt64 = 1
    var currentItem: PhotoItem?
    var currentIdentity: String?
    var metadataVerified = false
    var metadataStatus: PhotoViewerResourceStatus = .loading
    var started = false
    var closed = false
    var retryRevision = 0
    var pendingFavoriteIDs: Set<Int64> = []
    var favoriteFailures: [Int64: String] = [:]
    var favoriteValues: [Int64: Bool] = [:]
    var favoriteTask: Task<Void, Never>?
    var playlist = ViewerPlaylist()
    var playlistRevision: UInt64 = 0

    var observers: [UUID: AsyncStream<PhotoViewerState>.Continuation] = [:]

    public init(repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor = .personalLibrary,
                index: LibraryIndex,
                seed: PhotoViewerSeed, thumbnailSize: ThumbnailSize = .xl,
                loadsLargePreviews: Bool = false,
                allowNetwork: Bool, maximumPages: Int = 3) {
        self.repository = repository
        self.collection = collection
        self.index = index
        self.thumbnailSize = thumbnailSize
        self.loadsLargePreviews = loadsLargePreviews
        self.allowNetwork = allowNetwork
        metadata = ViewerMetadataWindow(index: index, maximumPages: maximumPages)
        desired = metadata.seedLocation(sectionIndex: seed.sectionIndex, pageOffset: seed.pageOffset)
        currentItem = seed.item
        currentIdentity = Self.identity(of: seed.item)
        metadataVerified = seed.pageVerified
        metadataStatus = seed.pageVerified ? .ready(verified: true, validationFailure: nil) : .loading
        if let page = seed.page {
            metadata.pages[desired.sectionIndex] = ViewerMetadataWindow.PageEntry(
                items: Array(page.prefix(max(1, metadata.spans.indices.contains(desired.sectionIndex)
                    ? metadata.spans[desired.sectionIndex].count : 0))),
                verified: seed.pageVerified
            )
        }
    }

    public func states() -> AsyncStream<PhotoViewerState> {
        let id = UUID()
        let stream = AsyncStream<PhotoViewerState>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(makeState())
            if closed {
                continuation.finish()
            } else {
                continuation.onTermination = { @Sendable _ in
                    Task { await self.removeObserver(id) }
                }
            }
        }
        startIfNeeded()
        return stream
    }

    public func state() -> PhotoViewerState {
        startIfNeeded()
        return makeState()
    }

    public func navigatePrevious() { navigate(by: -1) }

    public func navigateNext() { navigate(by: 1) }

    public func navigate(by delta: Int) {
        guard !closed, metadata.totalCount > 0, delta != 0 else { return }
        startIfNeeded()
        let sum = desired.ordinal.addingReportingOverflow(delta)
        let candidate: Int
        if sum.overflow { candidate = delta > 0 ? metadata.totalCount - 1 : 0 }
        else { candidate = min(metadata.totalCount - 1, max(0, sum.partialValue)) }
        guard candidate != desired.ordinal, let location = metadata.location(for: candidate) else { return }
        select(location)
    }

    public func updateAllowNetwork(_ enabled: Bool) {
        guard !closed, allowNetwork != enabled else { return }
        allowNetwork = enabled
        retryRevision &+= 1
        metadata.cancelJobs()
        if !enabled {
            metadataVerified = metadata.pages[desired.sectionIndex]?.verified == true
        }
        restartCurrentAssets()
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        publish()
    }

    public func retry() {
        guard !closed else { return }
        retryRevision &+= 1
        metadata.pageJobs.removeValue(forKey: desired.sectionIndex)?.task.cancel()
        restartCurrentAssets()
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        publish()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        images.cancelAll()
        metadata.cancelJobs()
        favoriteTask?.cancel()
        publish()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    func retainedPageCount() -> Int { metadata.pages.count }

    func speculativeThumbnailCount() -> Int { images.thumbnailPrefetchJobs.count }

    func speculativeFullImageCount() -> Int { images.fullJobs.count }

    func startIfNeeded() {
        guard !started, !closed else { return }
        started = true
        let repository = repository
        favoriteTask = Task { [weak self] in
            for await change in await repository.favoriteChanges() {
                guard !Task.isCancelled else { return }
                await self?.applyFavorite(itemID: change.itemID, value: change.favorite)
            }
        }
        startAssetsForCurrentMetadata()
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        publish()
    }

    func select(_ location: PhotoViewerLocation) {
        let targetResource = metadata.pages[location.sectionIndex]
            .flatMap { $0.items.indices.contains(location.pageOffset) ? $0.items[location.pageOffset] : nil }?
            .fullImageResource
        generation &+= 1
        desired = location
        currentItem = nil
        currentIdentity = nil
        metadataVerified = false
        metadataStatus = .loading
        images.resetSelection(keeping: targetResource)
        metadata.trimPages(around: location)
        if let page = metadata.pages[location.sectionIndex] {
            applyCurrentPage(page, at: location)
        }
        ensurePage(location.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        metadata.trimPageJobs(around: location)
        publish()
    }

    func makeState() -> PhotoViewerState {
        let currentItemID = currentItem?.id
        return PhotoViewerState(
            selection: PhotoViewerSelection(generation: generation, itemID: currentItem?.id),
            desiredLocation: desired,
            item: currentItem,
            metadataVerified: metadataVerified,
            thumbnailData: images.thumbnailData,
            fullImageData: images.fullImageData,
            metadataStatus: metadataStatus,
            thumbnailStatus: images.thumbnailStatus,
            fullImageStatus: images.fullImageStatus,
            isLoadingLargePreview: isLargePreviewLoading(),
            canNavigatePrevious: desired.ordinal > 0,
            canNavigateNext: desired.ordinal + 1 < metadata.totalCount,
            allowNetwork: allowNetwork,
            favoriteUpdating: currentItemID.map(pendingFavoriteIDs.contains) ?? false,
            favoriteFailure: currentItemID.flatMap { favoriteFailures[$0] },
            isClosed: closed
        )
    }

    func publish() {
        let state = makeState()
        for observer in observers.values { observer.yield(state) }
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    static func identity(of item: PhotoItem) -> String {
        let thumbnail = item.additional?.thumbnail
        return "\(item.id)|\(item.type)|\(item.liveType ?? "")|\(thumbnail?.unitID ?? -1)|\(thumbnail?.cacheKey ?? "")"
    }

    static func resourceKey(_ resource: FullImageResource) -> String {
        "\(resource.unitID)|\(resource.cacheKey)"
    }

    static func thumbnailKey(_ descriptor: ThumbnailInfo, size: ThumbnailSize) -> String {
        "\(descriptor.unitID):\(descriptor.cacheKey):\(size.rawValue)"
    }
}
