import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

@MainActor
final class PhotoViewerPresentation: ObservableObject {
    @Published private(set) var state: PhotoViewerState? { didSet { updateStatus() } }
    @Published private(set) var image: NSImage?
    @Published private(set) var decodeFailure: String? { didSet { updateStatus() } }
    @Published private(set) var isDecodingFullImage = false { didSet { updateStatus() } }
    @Published private(set) var invalidationMessage: String? { didSet { updateStatus() } }
    @Published private(set) var isClosing = false
    @Published private(set) var rotationPending = false
    @Published private(set) var isDisplayingFullResolution = false
    @Published var zoom: Double = 1

    let session: PhotoViewerSession
    let source: PhotoViewerSourceAnchor
    let originalItemID: Int64
    let snapshotRevision: Int
    let canvasController = PhotoViewerCanvasController()
    /// The short status, hover text and progress line state, kept apart so progress updates
    /// don't redraw the whole viewer.
    let statusModel = ViewerStatusModel()
    var onInfoItemChanged: ((PhotoItem?) -> Void)?
    private let initialItem: PhotoItem
    let index: LibraryIndex
    let repository: CachedPhotosRepository
    let collection: PhotoCollectionDescriptor
    let isIncoming: Bool
    /// Where favorite and rotation changes report progress and failures.
    var activity: ActivityCenter = .shared
    private let videoQuality: VideoQualityPreference
    private let thumbnailSize: ThumbnailSize
    private let loadsLargePreviews: Bool
    /// The size of the image on screen.
    private(set) var displayedTier: ViewerImageTier? { didSet { updateStatus() } }
    private var transfer: TransferProgress? { didSet { updateStatus() } }
    private var transferStalled = false { didSet { updateStatus() } }
    /// Full-resolution bytes arrived from the NAS for the current item.
    private var networkLoaded = false { didSet { updateStatus() } }
    private var videoPlayback: VideoPlaybackStatus? { didSet { updateStatus() } }
    private var transferResource: FullImageResource?
    private var transferTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var lastTransferActivity = ContinuousClock.now

    private var stateTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var thumbnailDecodeTask: Task<Void, Never>?
    private var neighborDecodeTasks: [String: Task<Void, Never>] = [:]
    private var neighborPreviewTasks: [String: Task<Void, Never>] = [:]
    @Published private var decodedNeighborPreviews: [String: NSImage] = [:]
    private var neighborPreviewData: [String: Data] = [:]
    @Published private(set) var decodedThumbnails: [String: NSImage] = [:]
    private var currentGeneration: UInt64?
    private var lastThumbnailData: Data?
    private var lastFullData: Data?
    private var hasDisplayedFullImage = false
    private var adoptedNeighborPreview = false
    private var lastFullImageFailureItemID: Int64?

    init(repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor,
         index: LibraryIndex, request: PhotoViewerOpenRequest,
         thumbnailSize: ThumbnailSize, loadsLargePreviews: Bool = false,
         videoQuality: VideoQualityPreference = .automatic,
         isIncoming: Bool = false,
         allowNetwork: Bool, snapshotRevision: Int) {
        source = request.source
        originalItemID = request.seed.item.id
        initialItem = request.seed.item
        self.index = index
        self.repository = repository
        self.collection = collection
        self.videoQuality = videoQuality
        self.thumbnailSize = thumbnailSize
        self.loadsLargePreviews = loadsLargePreviews && thumbnailSize != .xl
        self.isIncoming = isIncoming
        self.snapshotRevision = snapshotRevision
        image = request.source.image
        displayedTier = request.source.image == nil ? nil : .thumbnail(thumbnailSize)
        session = PhotoViewerSession(repository: repository, collection: collection,
                                     index: index, seed: request.seed,
                                     thumbnailSize: thumbnailSize,
                                     loadsLargePreviews: loadsLargePreviews,
                                     videoQuality: videoQuality,
                                     allowNetwork: allowNetwork,
                                     maximumPages: 3)
        let session = session
        stateTask = Task { [weak self] in
            for await next in await session.states() {
                guard !Task.isCancelled else { return }
                self?.receive(next)
            }
        }
    }

    deinit {
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        for task in neighborDecodeTasks.values { task.cancel() }
        for task in neighborPreviewTasks.values { task.cancel() }
        transferTask?.cancel()
        stallTask?.cancel()
        let session = session
        Task { await session.close() }
    }

    var filename: String {
        if let state { return state.item?.filename ?? "Loading photo…" }
        return initialItem.filename ?? "Untitled"
    }

    /// The capture date shown before the status in the toolbar title.
    var dateText: String {
        let time: Int64? = state == nil ? initialItem.time : state?.item?.time
        return time.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? ""
    }

    /// The date followed by the short status, e.g. "12 Mar 2024 · Medium · Loading".
    var detailLine: String {
        [dateText, statusModel.status.short].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func updateStatus() {
        statusModel.update(currentStatus(), generation: state?.selection.generation)
    }

    private func currentStatus() -> ViewerStatus {
        if let invalidationMessage { return .message(invalidationMessage) }
        guard let state else { return .opening }
        if state.item == nil {
            if case .failure(let message) = state.metadataStatus { return .message(message) }
            return .opening
        }
        return ViewerStatus.make(ViewerStatus.Inputs(
            displayed: displayedTier, fullStatus: state.fullImageStatus,
            isLoadingLargePreview: state.isLoadingLargePreview, largePreviews: loadsLargePreviews,
            isDecoding: isDecodingFullImage, decodeFailure: decodeFailure,
            transfer: transfer, networkLoaded: networkLoaded, stalled: transferStalled,
            allowNetwork: state.allowNetwork,
            video: state.videoResource.map {
                ViewerStatus.Video(variant: $0.variant, preference: videoQuality, playback: videoPlayback)
            }))
    }

    var decodedThumbnailIdentities: Set<String> { Set(decodedThumbnails.keys) }

    var previousNeighborImage: NSImage? { neighborImage(state?.previousNeighbor) }
    var nextNeighborImage: NSImage? { neighborImage(state?.nextNeighbor) }
    var previousNeighborItemID: Int64? { state?.previousNeighbor?.itemID }
    var nextNeighborItemID: Int64? { state?.nextNeighbor?.itemID }
    var previousNeighborIsLivePhoto: Bool { state?.previousNeighbor?.isLivePhoto == true }
    var nextNeighborIsLivePhoto: Bool { state?.nextNeighbor?.isLivePhoto == true }

    private func neighborImage(_ neighbor: PhotoViewerNeighbor?) -> NSImage? {
        guard let identity = neighbor?.thumbnailIdentity else { return nil }
        return decodedNeighborPreviews[identity] ?? decodedThumbnails[identity]
    }

    var canRetry: Bool {
        invalidationMessage == nil && state != nil && decodeFailure != nil
    }

    var showsUnsupportedVideo: Bool { state?.item?.isVideo == true && state?.videoResource == nil }

    var canToggleFavorite: Bool {
        !isIncoming && invalidationMessage == nil && !isClosing && state?.item != nil &&
            state?.metadataVerified == true && state?.allowNetwork == true &&
            state?.favoriteUpdating == false
    }

    func toggleFavorite() {
        guard canToggleFavorite, let item = state?.item, let state,
              index.sections.indices.contains(state.desiredLocation.sectionIndex) else { return }
        let section = index.sections[state.desiredLocation.sectionIndex]
        let action = SelectionFavoriteAction(affectedIDs: [item.id], targetFavorite: !item.isFavorite,
                                             sectionsByID: [item.id: section], collection: collection,
                                             itemsByID: [item.id: item])
        let handle = activity.begin(.favorite(!item.isFavorite), items: [ActivityItem(photo: item, collection: collection)],
                                    retry: FavoriteActivity.retry(action, repository: repository, activity: activity))
        Task {
            switch await session.toggleFavorite() {
            case nil: handle.discard()
            case .success: handle.succeed()
            case .failure(let error): handle.fail(error, operation: "Viewer favorite")
            }
        }
    }

    var canRotate: Bool {
        !isIncoming && invalidationMessage == nil && !isClosing && !rotationPending &&
            state?.metadataVerified == true && state?.allowNetwork == true &&
            state?.item?.hasDisplayableStillImage == true
    }

    var canAnnotate: Bool {
        !isIncoming && invalidationMessage == nil && !isClosing && state?.item != nil &&
            state?.metadataVerified == true && state?.allowNetwork == true
    }

    /// The displayed item as a rating or tag target.
    func annotationAction() -> SelectionAnnotationAction? {
        guard canAnnotate, let item = state?.item else { return nil }
        return SelectionAnnotationAction(itemIDs: [item.id], collection: collection, itemsByID: [item.id: item],
                                         expectedTimelineFingerprint: index.fingerprint)
    }

    func rotationAction() -> SelectionRotationAction? {
        guard canRotate, let state, let item = state.item,
              index.sections.indices.contains(state.desiredLocation.sectionIndex) else { return nil }
        let section = index.sections[state.desiredLocation.sectionIndex]
        return SelectionRotationAction(itemIDs: [item.id], sectionsByID: [item.id: section],
                                       collection: collection, itemsByID: [item.id: item],
                                       expectedTimelineFingerprint: index.fingerprint)
    }

    func rotate(_ direction: PhotoRotationDirection) {
        guard let action = rotationAction() else { return }
        rotationPending = true
        let priorImage = image
        let repository = repository
        if let image { self.image = Self.rotatedImage(image, direction: direction) }
        let handle = activity.begin(.rotate(direction), items: action.activityItems)
        Task { [weak self] in
            do {
                try await repository.rotate(action, direction: direction)
                handle.succeed()
            } catch {
                self?.image = priorImage
                handle.fail(error, operation: "Viewer rotation")
            }
            self?.rotationPending = false
        }
    }

    func sectionOffsetHint(for location: PhotoViewerLocation) -> Int? {
        guard index.sections.indices.contains(location.sectionIndex) else { return nil }
        return index.sections[location.sectionIndex].offset
    }

    var emptyStateMessage: String? {
        guard image == nil, let state else { return nil }
        if let decodeFailure { return decodeFailure }
        if state.item == nil, case .failure(let message) = state.metadataStatus { return message }
        let thumbnailFailure: String?
        switch state.thumbnailStatus {
        case .failure(let message), .unsupported(let message): thumbnailFailure = message
        default: thumbnailFailure = nil
        }
        guard let thumbnailFailure else { return nil }
        switch state.fullImageStatus {
        case .failure(let message), .unsupported(let message): return message
        case .idle: return thumbnailFailure
        case .loading, .ready: return nil
        }
    }

    func setFilmstripEnabled(_ enabled: Bool) {
        Task { await session.setFilmstripEnabled(enabled) }
    }

    func navigateToOrdinal(_ ordinal: Int) {
        guard invalidationMessage == nil, !isClosing, let current = state?.desiredLocation.ordinal else { return }
        Task { await session.navigate(by: ordinal - current) }
    }

    func navigatePrevious() {
        guard invalidationMessage == nil, !isClosing else { return }
        Task { await session.navigatePrevious() }
    }

    func navigateNext() {
        guard invalidationMessage == nil, !isClosing else { return }
        Task { await session.navigateNext() }
    }

    func updateAllowNetwork(_ allow: Bool) { Task { await session.updateAllowNetwork(allow) } }

    func retry() {
        guard !isClosing else { return }
        decodeFailure = nil
        lastFullData = nil
        Task { await session.retry() }
    }

    func invalidateForNewIndex() {
        guard invalidationMessage == nil else { return }
        invalidationMessage = "Library changed. Return to the library and reopen this photo."
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        cancelNeighborDecodes()
        stopTransferTracking()
        Task { await session.close() }
    }

    @discardableResult
    func close() -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        cancelNeighborDecodes()
        stopTransferTracking()
        Task { await session.close() }
        return true
    }

    private func cancelNeighborDecodes() {
        for task in neighborDecodeTasks.values { task.cancel() }
        neighborDecodeTasks.removeAll()
        for task in neighborPreviewTasks.values { task.cancel() }
        neighborPreviewTasks.removeAll()
    }

    /// Follows byte progress of the displayed photo's full-resolution transfer while it loads,
    /// and marks the load stalled when no data arrives for `ViewerStatus.stallInterval`.
    private func trackTransfer(_ next: PhotoViewerState) {
        let resource: FullImageResource? = if next.videoResource == nil, next.fullImageStatus == .loading {
            next.item?.fullImageResource(in: next.contentScope)
        } else { nil }
        guard resource != transferResource else { return }
        stopTransferTracking()
        guard let resource else { return }
        transferResource = resource
        lastTransferActivity = .now
        let repository = repository
        transferTask = Task { [weak self] in
            for await progress in await repository.fullImageProgress(resource) {
                guard !Task.isCancelled, let self, self.transferResource == resource else { return }
                self.receiveTransfer(progress)
            }
        }
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.transferResource == resource else { return }
                let stalled = self.lastTransferActivity.duration(to: .now) >= ViewerStatus.stallInterval
                if self.transferStalled != stalled { self.transferStalled = stalled }
            }
        }
    }

    /// Progress callbacks can arrive out of order; only forward movement counts.
    private func receiveTransfer(_ progress: TransferProgress) {
        guard progress.completedBytes > (transfer?.completedBytes ?? -1) else { return }
        lastTransferActivity = .now
        if transferStalled { transferStalled = false }
        if progress.completedBytes > 0, !networkLoaded { networkLoaded = true }
        let percent = { (value: TransferProgress?) in value?.fractionCompleted.map { Int($0 * 100) } }
        // Without a known size the status shows received bytes; limit updates to about 100 kB steps.
        if let current = transfer, progress.totalBytes != nil, percent(current) == percent(progress) { return }
        if let current = transfer, progress.totalBytes == nil,
           progress.completedBytes - current.completedBytes < 100_000 { return }
        transfer = progress
    }

    private func stopTransferTracking() {
        transferTask?.cancel()
        stallTask?.cancel()
        transferTask = nil
        stallTask = nil
        transferResource = nil
        if transfer != nil { transfer = nil }
        if transferStalled { transferStalled = false }
    }

    /// Video player state for the displayed item. A final playback failure is noted once per item.
    func noteVideoPlayback(_ status: VideoPlaybackStatus, generation: UInt64) {
        guard let state, state.selection.generation == generation, !isClosing else { return }
        videoPlayback = status
        guard case .failed(let message) = status, let item = state.item,
              item.id != lastFullImageFailureItemID else { return }
        lastFullImageFailureItemID = item.id
        guard activity.connectionIsHealthy else { return }
        activity.notice("Couldn't play \(item.filename ?? "video")", detail: message, key: "viewer:\(item.id)")
    }

    /// Notes, once per photo, that the opened photo's full resolution failed to load. Skipped
    /// unless the NAS is connected, and for cache-only attempts (signing in, metadata not yet
    /// verified, or offline), where a missing original is expected and a network attempt follows.
    private func noteFullImageFailure(_ next: PhotoViewerState) {
        guard case .failure(let message) = next.fullImageStatus, let item = next.item,
              next.allowNetwork, next.metadataVerified,
              item.id != lastFullImageFailureItemID else { return }
        lastFullImageFailureItemID = item.id
        guard activity.connectionIsHealthy else { return }
        activity.notice("Couldn't load full resolution of \(item.filename ?? "photo")", detail: message,
                        key: "viewer:\(item.id)")
    }

    private func receive(_ next: PhotoViewerState) {
        guard !next.isClosed else { return }
        if currentGeneration != next.selection.generation {
            let sameItem = state?.selection.itemID != nil && state?.selection.itemID == next.selection.itemID
            currentGeneration = next.selection.generation
            lastThumbnailData = nil
            lastFullData = nil
            hasDisplayedFullImage = false
            adoptedNeighborPreview = false
            decodeTask?.cancel()
            thumbnailDecodeTask?.cancel()
            decodeFailure = nil
            isDecodingFullImage = false
            if !sameItem {
                isDisplayingFullResolution = false
                if next.selection.itemID == originalItemID {
                    image = source.image
                    displayedTier = image == nil ? nil : .thumbnail(thumbnailSize)
                } else if let identity = next.thumbnailIdentity {
                    image = decodedNeighborPreviews[identity] ?? decodedThumbnails[identity]
                    adoptedNeighborPreview = decodedNeighborPreviews[identity] != nil
                    displayedTier = image == nil ? nil : .thumbnail(adoptedNeighborPreview ? .xl : thumbnailSize)
                } else {
                    image = nil
                    displayedTier = nil
                }
                zoom = 1
            }
            canvasController.resetForSelection(next.selection.generation, image: image,
                                               itemID: next.selection.itemID)
            videoPlayback = nil
            networkLoaded = false
        }
        state = next
        onInfoItemChanged?(next.item)
        noteFullImageFailure(next)
        trackTransfer(next)
        if let data = next.fullImageData, lastFullData != data {
            lastFullData = data
            decodeFull(data, selection: next.selection)
        }
        if let data = next.thumbnailData, lastThumbnailData != data,
           !hasDisplayedFullImage, next.selection == state?.selection,
           !adoptedNeighborPreview || next.thumbnailIsLargePreview {
            lastThumbnailData = data
            decodeThumbnail(data, selection: next.selection)
        }
        prepareNeighborThumbnails(next)
    }

    private func prepareNeighborThumbnails(_ state: PhotoViewerState) {
        var wanted: Set<String> = []
        if let identity = state.thumbnailIdentity { wanted.insert(identity) }
        let neighbors = [state.previousNeighbor, state.nextNeighbor].compactMap { $0 }
            + state.thumbnailLookahead
        for neighbor in neighbors {
            let identity = neighbor.thumbnailIdentity
            wanted.insert(identity)
            if let data = neighbor.largePreviewData, neighborPreviewData[identity] != data {
                neighborPreviewTasks[identity]?.cancel()
                neighborPreviewData[identity] = data
                neighborPreviewTasks[identity] = Task { [weak self] in
                    let decoded = await DecodedImages.shared.image(from: data, maxPixel: 1600)
                    guard !Task.isCancelled, let self else { return }
                    self.neighborPreviewTasks[identity] = nil
                    if let decoded { self.decodedNeighborPreviews[identity] = decoded }
                }
            }
            guard let data = neighbor.thumbnailData,
                  decodedThumbnails[identity] == nil,
                  neighborDecodeTasks[identity] == nil else { continue }
            neighborDecodeTasks[identity] = Task { [weak self] in
                let decoded = await DecodedImages.shared.image(from: data, maxPixel: 1600)
                guard !Task.isCancelled, let self else { return }
                self.neighborDecodeTasks[identity] = nil
                guard let decoded else { return }
                self.finishNeighborThumbnailDecode(decoded, identity: identity)
            }
        }
        for (identity, task) in neighborDecodeTasks where !wanted.contains(identity) {
            task.cancel()
            neighborDecodeTasks[identity] = nil
        }
        for identity in decodedThumbnails.keys where !wanted.contains(identity) {
            decodedThumbnails[identity] = nil
        }
        for (identity, task) in neighborPreviewTasks where !wanted.contains(identity) {
            task.cancel()
            neighborPreviewTasks[identity] = nil
        }
        for identity in neighborPreviewData.keys where !wanted.contains(identity) {
            neighborPreviewData[identity] = nil
            decodedNeighborPreviews[identity] = nil
        }
    }

    func finishNeighborThumbnailDecode(_ decoded: NSImage, identity: String) {
        decodedThumbnails[identity] = decoded
        guard state?.thumbnailIdentity == identity, !hasDisplayedFullImage,
              image == nil else { return }
        isDisplayingFullResolution = false
        image = decoded
        displayedTier = .thumbnail(thumbnailSize)
    }

    private func decodeThumbnail(_ data: Data, selection: PhotoViewerSelection) {
        thumbnailDecodeTask?.cancel()
        let tier = ViewerImageTier.thumbnail(state?.thumbnailIsLargePreview == true ? .xl : thumbnailSize)
        thumbnailDecodeTask = Task { [weak self] in
            guard let decoded = await DecodedImages.shared.image(from: data, maxPixel: 1600),
                  !Task.isCancelled, self?.state?.selection == selection,
                  self?.hasDisplayedFullImage == false else { return }
            self?.isDisplayingFullResolution = false
            self?.image = decoded
            self?.displayedTier = tier
            if let identity = self?.state?.thumbnailIdentity {
                self?.decodedThumbnails[identity] = decoded
            }
        }
    }

    private func decodeFull(_ data: Data, selection: PhotoViewerSelection) {
        decodeTask?.cancel()
        isDecodingFullImage = true
        SynologyDiagnostics.decoding.debug(
            "Starting full-size decode item_id=\(selection.itemID ?? -1, privacy: .public) bytes=\(data.count, privacy: .public) generation=\(selection.generation, privacy: .public)"
        )
        decodeTask = Task { [weak self] in
            do {
                let bitmap = try await FullImageDecoder.shared.decode(data)
                guard !Task.isCancelled, self?.state?.selection == selection else { return }
                let displayBitmap = try bitmap.rotatedForDisplay(
                    quarterTurns: self?.state?.item?.displayQuarterTurns(fileOrientation: FullImageDecoder.fileOrientation(data)) ?? 0
                )
                SynologyDiagnostics.decoding.info(
                    "Full-size decode succeeded item_id=\(selection.itemID ?? -1, privacy: .public) width=\(bitmap.image.width, privacy: .public) height=\(bitmap.image.height, privacy: .public) generation=\(selection.generation, privacy: .public)"
                )
                self?.isDisplayingFullResolution = true
                self?.displayedTier = .full
                self?.image = NSImage(cgImage: displayBitmap.image,
                                      size: NSSize(width: displayBitmap.image.width,
                                                   height: displayBitmap.image.height))
                self?.hasDisplayedFullImage = true
                self?.thumbnailDecodeTask?.cancel()
                self?.decodeFailure = nil
                self?.isDecodingFullImage = false
            } catch is CancellationError {
                SynologyDiagnostics.decoding.debug(
                    "Full-size decode cancelled item_id=\(selection.itemID ?? -1, privacy: .public) generation=\(selection.generation, privacy: .public)"
                )
                return
            } catch {
                guard !Task.isCancelled, self?.state?.selection == selection else { return }
                SynologyDiagnostics.decoding.error(
                    "Full-size decode failed item_id=\(selection.itemID ?? -1, privacy: .public) generation=\(selection.generation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                self?.decodeFailure = reportedFailure(error, operation: "Image decoding")
                self?.isDecodingFullImage = false
            }
        }
    }

    private static let dateFormatter = CaptureWallTimeFormatter.make()

    private static func rotatedImage(_ source: NSImage, direction: PhotoRotationDirection) -> NSImage {
        let output = NSImage(size: NSSize(width: source.size.height, height: source.size.width))
        output.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: output.size.width / 2, yBy: output.size.height / 2)
        transform.rotate(byDegrees: direction == .clockwise ? -90 : 90)
        transform.translateX(by: -source.size.width / 2, yBy: -source.size.height / 2)
        transform.concat()
        source.draw(in: NSRect(origin: .zero, size: source.size))
        output.unlockFocus()
        return output
    }
}
