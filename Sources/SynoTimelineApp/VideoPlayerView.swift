import AppKit
import AVFoundation
import AVKit
import PhotoCache
import SwiftUI
import SynologyAPI
import UniformTypeIdentifiers

struct VideoPlayerView: NSViewRepresentable {
    let repository: CachedPhotosRepository
    let resource: VideoPlaybackResource
    let selectionGeneration: UInt64
    let allowNetwork: Bool
    let poster: NSImage?
    let toolbarInset: CGFloat
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> VideoPlayerContainerView {
        VideoPlayerContainerView()
    }

    func updateNSView(_ view: VideoPlayerContainerView, context: Context) {
        view.toolbarInset = toolbarInset
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        view.configure(repository: repository, resource: resource,
                       generation: selectionGeneration, allowNetwork: allowNetwork,
                       poster: poster)
    }

    static func dismantleNSView(_ view: VideoPlayerContainerView, coordinator: ()) {
        view.stop()
    }
}

final class VideoPlayerContainerView: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    var toolbarInset: CGFloat = 0 { didSet { needsLayout = true } }

    private let playerView = NavigatingPlayerView()
    private let posterView = NSImageView()
    private var loader: VideoAssetLoader?
    private var player: AVPlayer?
    private var timeObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var identity: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        posterView.imageScaling = .scaleProportionallyUpOrDown
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        addSubview(posterView)
        addSubview(playerView)
        playerView.onPrevious = { [weak self] in self?.onPrevious?() }
        playerView.onNext = { [weak self] in self?.onNext?() }
        playerView.onClose = { [weak self] in self?.onClose?() }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                           height: max(0, bounds.height - toolbarInset))
        posterView.frame = frame
        playerView.frame = frame
    }

    func configure(repository: CachedPhotosRepository, resource: VideoPlaybackResource,
                   generation: UInt64, allowNetwork: Bool, poster: NSImage?) {
        posterView.image = poster
        let nextIdentity = "\(generation)|\(resource.unitID)|\(resource.cacheKey)|\(resource.variant.cacheComponent)|\(allowNetwork)"
        guard identity != nextIdentity else { return }
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
        playerView.player = player
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
                Task { @MainActor [weak self] in self?.loader?.cancelAll() }
            @unknown default:
                SynologyDiagnostics.videoPlayer.error(
                    "Video player item returned unknown status unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public)"
                )
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                if player.timeControlStatus == .playing { self?.posterView.isHidden = true }
            }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            SynologyDiagnostics.videoPlayer.info(
                "Video player time control changed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) status=\(player.timeControlStatus.rawValue, privacy: .public) waiting_reason=\(reason, privacy: .public)"
            )
        }
        player.play()
    }

    func stop() {
        timeObservation = nil
        itemStatusObservation = nil
        player?.pause()
        playerView.player = nil
        player = nil
        loader?.cancelAll()
        loader = nil
        identity = nil
    }
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
