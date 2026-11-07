import AppKit
import AVFoundation
import AVKit
import PhotoCache
import SwiftUI
import SynologyAPI
import UniformTypeIdentifiers

struct VideoConfiguration {
    let repository: CachedPhotosRepository
    let resource: VideoPlaybackResource
    let generation: UInt64
    let allowNetwork: Bool
    let poster: NSImage?
    var isMuted: Bool = false
    var onMuteChanged: (Bool) -> Void = { _ in }
    /// Loading, buffering, stall and failure states of the player, for the viewer status.
    var onPlaybackStatus: (VideoPlaybackStatus) -> Void = { _ in }
}

struct LivePhotoConfiguration {
    let repository: CachedPhotosRepository
    let itemID: Int64
    let collection: PhotoCollectionDescriptor
    let generation: UInt64
    let isMuted: Bool
}

final class VideoPlayerContainerView: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onPlaybackStatus: ((VideoPlaybackStatus) -> Void)?
    var toolbarInset: CGFloat = 0 { didSet { needsLayout = true } }

    var isMotionPlayback = false {
        didSet { playerView.controlsStyle = isMotionPlayback ? .none : .floating }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isMotionPlayback ? nil : super.hitTest(point)
    }

    private let playerView = NavigatingPlayerView()
    private let posterView = VideoPosterView()
    private var loader: VideoAssetLoader?
    private(set) var player: AVPlayer?
    private var timeObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var identity: String?
    private var fallbackRequestIdentity: String?
    private var onMuteChanged: (Bool) -> Void = { _ in }
    private var isShowingFirstFrame = false
    private var reportedStatus: VideoPlaybackStatus?
    private var waitingSince: ContinuousClock.Instant?
    private var stallTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        posterView.imageScaling = .scaleProportionallyUpOrDown
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        addSubview(playerView)
        installPoster()
        playerView.onPrevious = { [weak self] in self?.onPrevious?() }
        playerView.onNext = { [weak self] in self?.onNext?() }
        playerView.onClose = { [weak self] in self?.onClose?() }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                           height: max(0, bounds.height - toolbarInset))
        playerView.frame = frame
        installPoster()
        if let overlay = playerView.contentOverlayView {
            posterView.frame = overlay.bounds
        }
    }

    private func installPoster() {
        guard let overlay = playerView.contentOverlayView, posterView.superview !== overlay else { return }
        posterView.removeFromSuperview()
        posterView.frame = overlay.bounds
        posterView.autoresizingMask = [.width, .height]
        overlay.addSubview(posterView)
    }

    func configure(repository: CachedPhotosRepository, resource: VideoPlaybackResource,
                   generation: UInt64, allowNetwork: Bool, poster: NSImage?,
                   isMuted: Bool = false, onMuteChanged: @escaping (Bool) -> Void = { _ in }) {
        posterView.image = poster
        self.onMuteChanged = onMuteChanged
        let nextIdentity = "\(resource.scope.cacheComponent)|\(generation)|\(resource.unitID)|\(resource.cacheKey)|\(resource.variant.cacheComponent)|\(allowNetwork)"
        if identity == nextIdentity || fallbackRequestIdentity == nextIdentity {
            if player?.isMuted != isMuted { player?.isMuted = isMuted }
            return
        }
        fallbackRequestIdentity = nil
        stop()
        identity = nextIdentity
        SynologyDiagnostics.videoPlayer.info(
            "Video player configured unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) generation=\(generation, privacy: .public) network_allowed=\(allowNetwork, privacy: .public) poster_available=\(poster != nil, privacy: .public)"
        )
        posterView.isHidden = false
        let loader = VideoAssetLoader(repository: repository, resource: resource,
                                      allowNetwork: allowNetwork)
        self.loader = loader
        let url = URL(string: "cirrus-video://media/\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        let playerStarted = ContinuousClock.now
        let player = AVPlayer(playerItem: item)
        self.player = player
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self, weak player] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player else { return }
                self.onPlaybackFinished?()
            }
        }
        player.isMuted = isMuted
        playerView.player = player
        muteObservation = player.observe(\.isMuted, options: [.new]) { [weak self, weak player] _, change in
            guard let muted = change.newValue else { return }
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player, self.player === player, player.isMuted == muted else { return }
                self.onMuteChanged(muted)
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            switch item.status {
            case .unknown:
                SynologyDiagnostics.videoPlayer.debug(
                    "Video player item status unknown unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public)"
                )
            case .readyToPlay:
                SynologyDiagnostics.videoPlayer.info(
                    "Video player item ready unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) duration_seconds=\(item.duration.seconds, privacy: .public)"
                )
            case .failed:
                let error = item.error as NSError?
                SynologyDiagnostics.videoPlayer.error(
                    "Video player item failed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) error_domain=\(error?.domain ?? "nil", privacy: .public) error_code=\(error?.code ?? 0, privacy: .public)"
                )
                Task { @MainActor [weak self, player] in
                    guard let self, let player, self.player === player else { return }
                    self.loader?.cancelAll()
                    if !self.isMotionPlayback, case .converted = resource.variant {
                        let original = VideoPlaybackResource(scope: resource.scope, unitID: resource.unitID,
                            cacheKey: resource.cacheKey, filename: resource.filename, variant: .original, itemID: resource.itemID)
                        self.configure(repository: repository, resource: original, generation: generation,
                                       allowNetwork: allowNetwork, poster: poster, isMuted: player.isMuted,
                                       onMuteChanged: self.onMuteChanged)
                        self.fallbackRequestIdentity = nextIdentity
                    } else {
                        if !self.isMotionPlayback {
                            self.report(.failed(item.error?.localizedDescription ?? "The video couldn't be played."))
                        }
                        self.onPlaybackFinished?()
                    }
                }
            @unknown default:
                SynologyDiagnostics.videoPlayer.error(
                    "Video player item returned unknown status unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public)"
                )
            }
        }
        displayObservation = playerView.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak player] _, change in
            let ready = change.newValue ?? false
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.posterView.isHidden = ready
                self.isShowingFirstFrame = ready
                self.refreshPlaybackStatus()
                if ready {
                    let elapsed = playerStarted.duration(to: .now).components
                    let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                    SynologyDiagnostics.videoPlayer.info("Video first frame unit_id=\(resource.unitID, privacy: .public) elapsed_ms=\(ms, privacy: .public)")
                    self.onFirstFrame?()
                }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            SynologyDiagnostics.videoPlayer.info(
                "Video player time control changed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) status=\(player.timeControlStatus.rawValue, privacy: .public) waiting_reason=\(reason, privacy: .public)"
            )
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.refreshPlaybackStatus()
            }
        }
        player.play()
    }

    /// Reports loading before the first frame, buffering while playback waits for data, and a
    /// stall when neither has received data for `ViewerStatus.stallInterval`.
    private func refreshPlaybackStatus() {
        guard let player, !isMotionPlayback else { return }
        if case .failed = reportedStatus { return }
        let status: VideoPlaybackStatus
        if !isShowingFirstFrame { status = .loading }
        else {
            switch player.timeControlStatus {
            case .playing: status = .playing
            case .paused: status = .paused
            case .waitingToPlayAtSpecifiedRate: status = .buffering
            @unknown default: status = .playing
            }
        }
        let waiting = status == .loading || status == .buffering
        if waiting {
            if waitingSince == nil { waitingSince = .now }
            if stallTask == nil { startStallCheck() }
            if reportedStatus == .stalled { return }
        } else {
            waitingSince = nil
            stallTask?.cancel()
            stallTask = nil
        }
        report(status)
    }

    private func startStallCheck() {
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let since = self.waitingSince else { return }
                let lastData = self.loader?.lastDelivery ?? since
                let quiet = max(since, lastData).duration(to: .now)
                if quiet >= ViewerStatus.stallInterval {
                    self.report(.stalled)
                } else if self.reportedStatus == .stalled {
                    self.report(self.isShowingFirstFrame ? .buffering : .loading)
                }
            }
        }
    }

    private func report(_ status: VideoPlaybackStatus) {
        guard reportedStatus != status else { return }
        reportedStatus = status
        onPlaybackStatus?(status)
    }

    func stop() {
        stallTask?.cancel()
        stallTask = nil
        waitingSince = nil
        reportedStatus = nil
        isShowingFirstFrame = false
        timeObservation = nil
        muteObservation = nil
        displayObservation = nil
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player?.pause()
        playerView.player = nil
        player = nil
        loader?.cancelAll()
        loader = nil
        identity = nil
    }
}

/// The poster sits between video and controls without intercepting their input.
private final class VideoPosterView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class NavigatingPlayerView: AVPlayerView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onClose?()
        case 123: onPrevious?()
        case 124: onNext?()
        default: super.keyDown(with: event)
        }
    }
}

final class VideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "de.richardhanss.cirrus-photos.video-loader")
    private let repository: CachedPhotosRepository
    private let resource: VideoPlaybackResource
    private let allowNetwork: Bool
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var lastDeliveryTime: ContinuousClock.Instant?

    /// When the loader last handed data to the player, from the cache or the NAS.
    var lastDelivery: ContinuousClock.Instant? { lock.withLock { lastDeliveryTime } }

    init(repository: CachedPhotosRepository, resource: VideoPlaybackResource, allowNetwork: Bool) {
        self.repository = repository
        self.resource = resource
        self.allowNetwork = allowNetwork
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        let requestedOffset = loadingRequest.dataRequest.map {
            max($0.requestedOffset, $0.currentOffset)
        } ?? 0
        let requestedLength = loadingRequest.dataRequest?.requestedLength ?? 0
        SynologyDiagnostics.videoPlayer.debug(
            "Video asset request started unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public) offset=\(requestedOffset, privacy: .public) length=\(requestedLength, privacy: .public) content_info=\(loadingRequest.contentInformationRequest != nil, privacy: .public) network_allowed=\(self.allowNetwork, privacy: .public)"
        )
        lock.lock()
        let task = Task { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            do {
                try await fulfill(loadingRequest, id: id)
                queue.sync {
                    if lock.withLock({ tasks.removeValue(forKey: id) != nil }) {
                        loadingRequest.finishLoading()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let error = error as NSError
                    SynologyDiagnostics.videoPlayer.error("Video asset request failed unit_id=\(self.resource.unitID, privacy: .public) error_domain=\(error.domain, privacy: .public) error_code=\(error.code, privacy: .public)")
                }
                queue.sync {
                    if lock.withLock({ tasks.removeValue(forKey: id) != nil }), !Task.isCancelled {
                        loadingRequest.finishLoading(with: error)
                    }
                }
            }
        }
        tasks[id] = task
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        SynologyDiagnostics.videoPlayer.debug(
            "Video asset request cancellation received unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public)"
        )
        lock.withLock { tasks.removeValue(forKey: id) }?.cancel()
    }

    func cancelAll() {
        let pending = lock.withLock { let values = Array(tasks.values); tasks.removeAll(); return values }
        if !pending.isEmpty {
            SynologyDiagnostics.videoPlayer.debug(
                "Video asset loader cancelling all unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public) request_count=\(pending.count, privacy: .public)"
            )
        }
        for task in pending { task.cancel() }
    }

    private final class LoadingState: @unchecked Sendable {
        var demand: VideoLoadingDemand
        var total: Int64?
        var contentType: String?
        var etag: String?
        var lastModified: String?
        var reportedFirstDelivery = false
        let started = ContinuousClock.now
        init(demand: VideoLoadingDemand) { self.demand = demand }
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest, id: ObjectIdentifier) async throws {
        let demand = try queue.sync { () throws -> VideoLoadingDemand in
            guard let data = request.dataRequest else {
                return try VideoLoadingDemand(requestedOffset: 0, currentOffset: 0, requestedLength: 1,
                                              allToEnd: false, informationOnly: true)
            }
            return try VideoLoadingDemand(requestedOffset: data.requestedOffset, currentOffset: data.currentOffset,
                                          requestedLength: data.requestedLength,
                                          allToEnd: data.requestsAllDataToEndOfResource)
        }
        let state = LoadingState(demand: demand)
        while let amount = state.demand.nextLength(limit: CachedPhotosRepository.videoWindowSize) {
            try Task.checkCancellation()
            let start = state.demand.offset
            try await repository.streamVideoData(resource, offset: start, length: amount, allowNetwork: allowNetwork) { [self] value in
                try Task.checkCancellation()
                try queue.sync {
                    guard lock.withLock({ tasks[id] != nil }) else { throw CancellationError() }
                    guard value.range.lowerBound == state.demand.offset,
                          state.total == nil || state.total == value.totalLength,
                          state.contentType == nil || state.contentType == value.contentType,
                          state.etag == nil || value.etag == nil || state.etag == value.etag,
                          state.lastModified == nil || value.lastModified == nil || state.lastModified == value.lastModified else {
                        throw SynologyAPIError.invalidResponse
                    }
                    if let information = request.contentInformationRequest {
                        information.contentType = UTType(mimeType: value.contentType)?.identifier ?? UTType.mpeg4Movie.identifier
                        information.contentLength = value.totalLength
                        information.isByteRangeAccessSupported = true
                    }
                    state.total = value.totalLength
                    state.contentType = value.contentType
                    if state.etag == nil { state.etag = value.etag }
                    if state.lastModified == nil { state.lastModified = value.lastModified }
                    if !state.reportedFirstDelivery {
                        state.reportedFirstDelivery = true
                        let elapsed = state.started.duration(to: .now).components
                        let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                        SynologyDiagnostics.videoPlayer.info("Video first loader response unit_id=\(self.resource.unitID, privacy: .public) elapsed_ms=\(ms, privacy: .public)")
                    }
                    if !state.demand.informationOnly { request.dataRequest?.respond(with: value.data) }
                    lock.withLock { lastDeliveryTime = .now }
                    try state.demand.advance(value.data.count)
                }
            }
            if state.demand.informationOnly || state.demand.offset >= (state.total ?? Int64.max) { return }
            guard state.demand.offset > start else { throw SynologyAPIError.invalidResponse }
        }
    }

}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }
        return operation()
    }
}
