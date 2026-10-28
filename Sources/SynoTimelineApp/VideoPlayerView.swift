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
}

struct LivePhotoConfiguration {
    let repository: CachedPhotosRepository
    let itemID: Int64
    let generation: UInt64
    let isMuted: Bool
}

final class VideoPlayerContainerView: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onPlaybackFinished: (() -> Void)?
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
    private var onMuteChanged: (Bool) -> Void = { _ in }

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
        let nextIdentity = "\(generation)|\(resource.unitID)|\(resource.cacheKey)|\(resource.variant.cacheComponent)|\(allowNetwork)"
        if identity == nextIdentity {
            if player?.isMuted != isMuted { player?.isMuted = isMuted }
            return
        }
        stop()
        identity = nextIdentity
        SynologyDiagnostics.videoPlayer.info(
            "Video player configured unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) generation=\(generation, privacy: .public) network_allowed=\(allowNetwork, privacy: .public) poster_available=\(poster != nil, privacy: .public)"
        )
        posterView.isHidden = false
        let loader = VideoAssetLoader(repository: repository, resource: resource,
                                      allowNetwork: allowNetwork)
        self.loader = loader
        let url = URL(string: "synotimeline-video://media/\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak player] _ in
            guard let self, let player, self.player === player else { return }
            self.onPlaybackFinished?()
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
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
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
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, self.player === player else { return }
                    self.loader?.cancelAll()
                    self.onPlaybackFinished?()
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
                if ready { self.onFirstFrame?() }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            SynologyDiagnostics.videoPlayer.info(
                "Video player time control changed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) status=\(player.timeControlStatus.rawValue, privacy: .public) waiting_reason=\(reason, privacy: .public)"
            )
        }
        player.play()
    }

    func stop() {
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
    let queue = DispatchQueue(label: "local.cirrus.syno-timeline.video-loader")
    private let repository: CachedPhotosRepository
    private let resource: VideoPlaybackResource
    private let allowNetwork: Bool
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

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
        let task = Task { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            do {
                try await fulfill(loadingRequest)
                guard !Task.isCancelled else { return }
                loadingRequest.finishLoading()
                SynologyDiagnostics.videoPlayer.debug(
                    "Video asset request finished unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public) offset=\(requestedOffset, privacy: .public) length=\(requestedLength, privacy: .public)"
                )
            } catch is CancellationError {
                SynologyDiagnostics.videoPlayer.debug(
                    "Video asset request cancelled unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public) offset=\(requestedOffset, privacy: .public) length=\(requestedLength, privacy: .public)"
                )
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain,
                                                            code: NSURLErrorCancelled))
            } catch {
                let nsError = error as NSError
                SynologyDiagnostics.videoPlayer.error(
                    "Video asset request failed unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public) offset=\(requestedOffset, privacy: .public) length=\(requestedLength, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)"
                )
                loadingRequest.finishLoading(with: error)
            }
            removeTask(id)
        }
        lock.withLock { tasks[id] = task }
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

    private func fulfill(_ request: AVAssetResourceLoadingRequest) async throws {
        let dataRequest = request.dataRequest
        var offset = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        var remaining = dataRequest?.requestedLength ?? 1
        repeat {
            let amount = min(max(1, remaining), 4 * 1_024 * 1_024)
            let value = try await repository.videoData(resource, offset: offset,
                                                       length: amount,
                                                       allowNetwork: allowNetwork)
            if let information = request.contentInformationRequest {
                information.contentType = UTType(mimeType: value.contentType)?.identifier
                    ?? UTType.mpeg4Movie.identifier
                information.contentLength = value.totalLength
                information.isByteRangeAccessSupported = true
                SynologyDiagnostics.videoPlayer.debug(
                    "Video asset content information supplied unit_id=\(self.resource.unitID, privacy: .public) quality=\(self.resource.variant.cacheComponent, privacy: .public) total=\(value.totalLength, privacy: .public) content_type=\(value.contentType, privacy: .public)"
                )
            }
            guard let dataRequest else { return }
            dataRequest.respond(with: value.data)
            offset += Int64(value.data.count)
            remaining -= value.data.count
            if offset >= value.totalLength || value.data.isEmpty { return }
        } while remaining > 0
    }

    private func removeTask(_ id: ObjectIdentifier) {
        _ = lock.withLock { tasks.removeValue(forKey: id) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }
        return operation()
    }
}
