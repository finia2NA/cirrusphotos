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
    @Published var zoom: Double = 1

    let session: PhotoViewerSession
    let source: PhotoViewerSourceAnchor
    let originalItemID: Int64
    let snapshotRevision: Int
    let canvasController = PhotoViewerCanvasController()
    private let initialItem: PhotoItem
    private let index: LibraryIndex

    private var stateTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var thumbnailDecodeTask: Task<Void, Never>?
    private var currentGeneration: UInt64?
    private var lastThumbnailData: Data?
    private var lastFullData: Data?
    private var hasDisplayedFullImage = false

    init(repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor = .personalLibrary,
         index: LibraryIndex, request: PhotoViewerOpenRequest,
         thumbnailSize: ThumbnailSize, loadsLargePreviews: Bool = false,
         allowNetwork: Bool, snapshotRevision: Int) {
        source = request.source
        originalItemID = request.seed.item.id
        initialItem = request.seed.item
        self.index = index
        self.snapshotRevision = snapshotRevision
        image = request.source.image
        session = PhotoViewerSession(repository: repository, collection: collection,
                                     index: index, seed: request.seed,
                                     thumbnailSize: thumbnailSize,
                                     loadsLargePreviews: loadsLargePreviews,
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
        else {
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

    var canRetry: Bool {
        guard invalidationMessage == nil, let state else { return false }
        if decodeFailure != nil { return true }
        if case .failure = state.fullImageStatus { return true }
        return false
    }

    var showsUnsupportedVideo: Bool { state?.item?.isVideo == true }

    var canToggleFavorite: Bool {
        invalidationMessage == nil && !isClosing && state?.item != nil &&
            state?.metadataVerified == true && state?.allowNetwork == true &&
            state?.favoriteUpdating == false
    }

    func toggleFavorite() {
        guard canToggleFavorite else { return }
        Task { await session.toggleFavorite() }
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
        Task { await session.close() }
    }

    @discardableResult
    func close() -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        stateTask?.cancel()
        decodeTask?.cancel()
        thumbnailDecodeTask?.cancel()
        Task { await session.close() }
        return true
    }

    private func receive(_ next: PhotoViewerState) {
        guard !next.isClosed else { return }
        if currentGeneration != next.selection.generation {
            currentGeneration = next.selection.generation
            lastThumbnailData = nil
            lastFullData = nil
            hasDisplayedFullImage = false
            decodeTask?.cancel()
            thumbnailDecodeTask?.cancel()
            decodeFailure = nil
            isDecodingFullImage = false
            image = next.selection.itemID == originalItemID ? source.image : nil
            zoom = 1
            canvasController.resetForSelection(next.selection.generation)
        }
        state = next
        if let data = next.fullImageData, lastFullData != data {
            lastFullData = data
            decodeFull(data, selection: next.selection)
        }
        if let data = next.thumbnailData, lastThumbnailData != data,
           !hasDisplayedFullImage, next.selection == state?.selection {
            lastThumbnailData = data
            decodeThumbnail(data, selection: next.selection)
        }
    }

    private func decodeThumbnail(_ data: Data, selection: PhotoViewerSelection) {
        thumbnailDecodeTask?.cancel()
        thumbnailDecodeTask = Task { [weak self] in
            guard let decoded = await DecodedImages.shared.image(from: data, maxPixel: 1600),
                  !Task.isCancelled, self?.state?.selection == selection,
                  self?.hasDisplayedFullImage == false else { return }
            self?.image = decoded
        }
    }

    private func decodeFull(_ data: Data, selection: PhotoViewerSelection) {
        decodeTask?.cancel()
        isDecodingFullImage = true
        decodeTask = Task { [weak self] in
            do {
                let bitmap = try await FullImageDecoder.shared.decode(data)
                guard !Task.isCancelled, self?.state?.selection == selection else { return }
                self?.image = NSImage(cgImage: bitmap.image,
                                      size: NSSize(width: bitmap.image.width, height: bitmap.image.height))
                self?.hasDisplayedFullImage = true
                self?.thumbnailDecodeTask?.cancel()
                self?.decodeFailure = nil
                self?.isDecodingFullImage = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.state?.selection == selection else { return }
                self?.decodeFailure = error.localizedDescription
                self?.isDecodingFullImage = false
            }
        }
    }

    private static let dateFormatter = CaptureWallTimeFormatter.make()
}
