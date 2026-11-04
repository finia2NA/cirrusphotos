import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

@MainActor
final class PhotoViewerPresentation: ObservableObject {
    @Published private(set) var state: PhotoViewerState?
    @Published private(set) var image: NSImage?
    @Published private(set) var decodeFailure: String?
    @Published private(set) var isDecodingFullImage = false
    @Published private(set) var invalidationMessage: String?
    @Published private(set) var isClosing = false
    @Published private(set) var rotationFailure: String?
    @Published private(set) var rotationPending = false
    @Published private(set) var isDisplayingFullResolution = false
    @Published var zoom: Double = 1

    let session: PhotoViewerSession
    let source: PhotoViewerSourceAnchor
    let originalItemID: Int64
    let snapshotRevision: Int
    let canvasController = PhotoViewerCanvasController()
    var onInfoItemChanged: ((PhotoItem?) -> Void)?
    private let initialItem: PhotoItem
    let index: LibraryIndex
    let repository: CachedPhotosRepository
    let collection: PhotoCollectionDescriptor
    let isIncoming: Bool
    private let videoQuality: VideoQualityPreference

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
        self.isIncoming = isIncoming
        self.snapshotRevision = snapshotRevision
        image = request.source.image
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
        let session = session
        Task { await session.close() }
    }

    var filename: String {
        if let state { return state.item?.filename ?? "Loading photo…" }
        return initialItem.filename ?? "Untitled"
    }

    var detailLine: String {
        guard let state else {
            let date = Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(initialItem.time)))
            return "\(date) · Opening…"
        }
        let date = state.item.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0.time))) }
        let status: String
        if let invalidationMessage { status = invalidationMessage }
        else if let failure = state.favoriteFailure { status = "Favorite change failed: \(failure)" }
        else if state.favoriteUpdating { status = "Updating favorite…" }
        else if let decodeFailure { status = decodeFailure }
        else if state.item == nil, case .failure(let message) = state.metadataStatus { status = message }
        else if let video = state.videoResource {
            switch video.variant {
            case .converted(let chosen):
                if let target = videoQuality.targetQuality, chosen != target {
                    status = "\(chosen.displayName) · \(target.displayName) unavailable"
                } else {
                    status = chosen.displayName
                }
            case .original:
                status = videoQuality == .original
                    ? video.variant.displayName
                    : "Original · No converted quality available"
            }
        } else {
            switch state.fullImageStatus {
            case .idle: status = "Waiting for full resolution"
            case .loading:
                status = state.isLoadingLargePreview
                    ? "Loading large preview and full resolution"
                    : "Loading full resolution"
            case .ready(let verified, let validationFailure):
                if isDecodingFullImage { status = "Decoding full resolution…" }
                else if let validationFailure { status = "Full resolution cached · \(validationFailure)" }
                else { status = verified ? "Full resolution" : "Full resolution cached" }
            case .failure(let message): status = message
            case .unsupported(let message): status = message
            }
        }
        return [date, status].compactMap { $0 }.joined(separator: " · ")
    }

    var showsLoadingIndicator: Bool {
        guard let state else { return true }
        if isDecodingFullImage { return true }
        if case .loading = state.fullImageStatus { return true }
        return false
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
        guard canToggleFavorite else { return }
        Task { await session.toggleFavorite() }
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
        rotationFailure = nil
        let priorImage = image
        let repository = repository
        if let image { self.image = Self.rotatedImage(image, direction: direction) }
        Task { [weak self] in
            do { try await repository.rotate(action, direction: direction) }
            catch {
                self?.image = priorImage
                self?.rotationFailure = reportedFailure(error, operation: "Viewer rotation")
            }
            self?.rotationPending = false
        }
    }

    func dismissRotationFailure() { rotationFailure = nil }

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
        Task { await session.close() }
        return true
    }

    private func cancelNeighborDecodes() {
        for task in neighborDecodeTasks.values { task.cancel() }
        neighborDecodeTasks.removeAll()
        for task in neighborPreviewTasks.values { task.cancel() }
        neighborPreviewTasks.removeAll()
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
                } else if let identity = next.thumbnailIdentity {
                    image = decodedNeighborPreviews[identity] ?? decodedThumbnails[identity]
                    adoptedNeighborPreview = decodedNeighborPreviews[identity] != nil
                } else {
                    image = nil
                }
                zoom = 1
            }
            canvasController.resetForSelection(next.selection.generation, image: image,
                                               itemID: next.selection.itemID)
        }
        state = next
        onInfoItemChanged?(next.item)
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
    }

    private func decodeThumbnail(_ data: Data, selection: PhotoViewerSelection) {
        thumbnailDecodeTask?.cancel()
        thumbnailDecodeTask = Task { [weak self] in
            guard let decoded = await DecodedImages.shared.image(from: data, maxPixel: 1600),
                  !Task.isCancelled, self?.state?.selection == selection,
                  self?.hasDisplayedFullImage == false else { return }
            self?.isDisplayingFullResolution = false
            self?.image = decoded
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
