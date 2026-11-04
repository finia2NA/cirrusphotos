import Foundation
import PhotoCache
import SwiftUI
import SynologyAPI

/// The size of the image the viewer currently shows.
enum ViewerImageTier: Equatable, Sendable {
    case thumbnail(ThumbnailSize)
    case full

    var name: String {
        switch self {
        case .thumbnail(.sm): "Small"
        case .thumbnail(.m): "Medium"
        case .thumbnail(.xl): "Large"
        case .full: "Full"
        }
    }

    var description: String {
        switch self {
        case .thumbnail(.sm): "the small preview"
        case .thumbnail(.m): "the medium preview"
        case .thumbnail(.xl): "the large preview"
        case .full: "full resolution"
        }
    }
}

/// Playback state reported by the viewer's video player.
enum VideoPlaybackStatus: Equatable, Sendable {
    case loading
    case playing
    case paused
    case buffering
    /// Waiting for data, and none has arrived for `ViewerStatus.stallInterval`.
    case stalled
    case failed(String)
}

enum ViewerProgress: Equatable {
    case indeterminate
    case determinate(Double)
}

/// The viewer's status as "what's shown · what's happening", with a longer description for
/// hover and the progress bar's state. Progress is reported only for network work; cached
/// loads and local decoding finish too quickly to need it.
struct ViewerStatus: Equatable {
    var short: String
    var help: String
    var progress: ViewerProgress?
    /// The item is fully shown: full resolution, or video playing or paused.
    var isComplete = false

    /// How long a load may receive no data before it is reported as stalled.
    static let stallInterval: Duration = .seconds(8)
    /// The share of the progress bar given to the large preview when it loads alongside full
    /// resolution. Larger than its byte share, so its arrival is visible.
    static let largePreviewShare = 0.2

    static let opening = ViewerStatus(short: "Opening", help: "Opening the photo")

    static func message(_ text: String) -> ViewerStatus { ViewerStatus(short: text, help: text) }

    struct Video: Equatable {
        var variant: VideoPlaybackVariant
        var preference: VideoQualityPreference
        var playback: VideoPlaybackStatus?
    }

    struct Inputs: Equatable {
        var displayed: ViewerImageTier?
        var fullStatus: PhotoViewerResourceStatus
        var isLoadingLargePreview = false
        /// Large previews are enabled and smaller than the configured library rendition.
        var largePreviews = false
        var isDecoding = false
        var decodeFailure: String?
        var transfer: TransferProgress?
        /// Full-resolution bytes arrived from the NAS for this item, so decoding continues a
        /// network load.
        var networkLoaded = false
        var stalled = false
        var allowNetwork = true
        var video: Video?
    }

    static func make(_ inputs: Inputs) -> ViewerStatus {
        if let video = inputs.video { return make(video) }
        let shown = inputs.displayed
        func status(_ happening: String?, _ detail: String?, _ progress: ViewerProgress? = nil) -> ViewerStatus {
            let short = [shown?.name, happening].compactMap { $0 }.joined(separator: " · ")
            let showing = shown.map { "Showing \($0.description)" }
            let help = [showing, detail].compactMap { $0 }.joined(separator: "; ")
            return ViewerStatus(short: short.isEmpty ? "Loading" : short, help: capitalized(help), progress: progress)
        }
        if let failure = inputs.decodeFailure {
            return status("Full couldn't be decoded", failure)
        }
        // After a network load the bar stays full while decoding; a cached original decodes without it.
        let decoding = status("Decoding", "decoding full resolution", inputs.networkLoaded ? .determinate(1) : nil)
        if inputs.isDecoding { return decoding }
        switch inputs.fullStatus {
        case .ready(let verified, let validationFailure):
            guard shown == .full else { return decoding }
            let source: String
            if let validationFailure {
                source = "Showing full resolution from the cache; checking it against the NAS failed: \(validationFailure)"
            } else if verified {
                source = "Showing full resolution"
            } else {
                source = "Showing full resolution from the cache; not yet checked against the NAS"
            }
            return ViewerStatus(short: "Full", help: source, isComplete: true)
        case .loading:
            let what = inputs.isLoadingLargePreview ? "the large preview and full resolution" : "full resolution"
            // With large previews, the bar covers both: the preview's arrival fills the first
            // `largePreviewShare`, and full resolution the rest. Without one, full resolution is all of it.
            let hasPreview = shown == .thumbnail(.xl)
            let previewCounts = inputs.largePreviews && (hasPreview || inputs.isLoadingLargePreview)
            let previewPart = previewCounts && hasPreview ? largePreviewShare : 0
            let fullShare = previewCounts ? 1 - largePreviewShare : 1
            // Bytes reach the progress stream only from the NAS, so their arrival marks network work.
            let networkBytes = inputs.transfer.map { $0.completedBytes > 0 } ?? false
            let fullFraction = networkBytes ? inputs.transfer?.fractionCompleted : nil
            let combined = fullFraction.map { previewPart + fullShare * $0 }
            let reached = networkBytes ? (combined ?? (previewPart > 0 ? previewPart : nil)).map(ViewerProgress.determinate) : nil
            if inputs.stalled {
                let seconds = Int(stallInterval.components.seconds)
                return status("Stalled", "loading \(what), but no data has arrived for \(seconds) seconds", reached)
            }
            guard let transfer = inputs.transfer, networkBytes else {
                return status("Loading", "loading \(what)")
            }
            let received = bytes(transfer.completedBytes)
            if let combined, let total = transfer.totalBytes {
                let percent = Int((combined * 100).rounded(.down))
                return status("Loading \(percent)%", "loading \(what): \(received) of \(bytes(total))",
                              .determinate(combined))
            }
            return status("Loading", "loading \(what): \(received) received", reached ?? .indeterminate)
        case .idle:
            return status("Waiting", "waiting to load full resolution")
        case .failure(let message):
            let unavailable = inputs.allowNetwork ? "Full unavailable" : "Full unavailable offline"
            return status(unavailable, message)
        case .unsupported(let message):
            return status(shown == nil ? "Unavailable" : nil, message)
        }
    }

    private static func make(_ video: Video) -> ViewerStatus {
        let name = video.variant.displayName
        var notes: [String] = []
        let fallbackNote: String?
        switch video.variant {
        case .converted(let chosen):
            notes.append("Playing the NAS-converted \(chosen.displayName) version")
            if let target = video.preference.targetQuality, chosen != target {
                fallbackNote = "\(target.displayName) unavailable"
                notes.append("\(target.displayName) has not been converted on the NAS")
            } else {
                fallbackNote = nil
            }
        case .original:
            notes.append("Playing the original file")
            if video.preference != .original {
                fallbackNote = "No converted quality available"
                notes.append("the NAS has no converted version")
            } else {
                fallbackNote = nil
            }
        }
        let happening: String?
        let progress: ViewerProgress?
        switch video.playback {
        case nil, .loading:
            happening = "Loading"; progress = .indeterminate
            notes.append("loading the video")
        case .buffering:
            happening = "Buffering"; progress = .indeterminate
            notes.append("waiting for more of the video to load")
        case .stalled:
            happening = "Stalled"; progress = nil
            notes.append("no video data has arrived for \(Int(stallInterval.components.seconds)) seconds")
        case .failed(let message):
            happening = "Can't play"; progress = nil
            notes.append(message)
        case .playing, .paused:
            happening = fallbackNote; progress = nil
        }
        let short = [name, happening].compactMap { $0 }.joined(separator: " · ")
        let complete = video.playback == .playing || video.playback == .paused
        return ViewerStatus(short: short, help: capitalized(notes.joined(separator: "; ")), progress: progress,
                            isComplete: complete)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What the progress bar shows.
enum ViewerBarState: Equatable {
    case hidden
    case progress(ViewerProgress)
    /// A visible load finished: a full green bar, briefly.
    case completed
}

/// Holds the viewer's status apart from the presentation so frequent progress updates only
/// redraw the title and progress bar. It also decides what the bar shows: indeterminate progress
/// appears only after `indeterminateDelay`, so quick cached work never flashes a bar, and a load
/// whose bar was visible ends with a green bar for `completionDuration`.
@MainActor
final class ViewerStatusModel: ObservableObject {
    @Published private(set) var status: ViewerStatus = .opening
    @Published private(set) var bar: ViewerBarState = .hidden

    static let indeterminateDelay: Duration = .milliseconds(500)
    static let completionDuration: Duration = .milliseconds(500)

    private var generation: UInt64?
    private var pendingIndeterminate: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?

    /// `generation` identifies the shown item; a new item never inherits the previous bar.
    func update(_ next: ViewerStatus, generation: UInt64?) {
        if status != next { status = next }
        if generation != self.generation {
            self.generation = generation
            cancelPending()
            completionTask?.cancel()
            completionTask = nil
            setBar(.hidden)
        }
        if bar == .completed { return }
        if next.isComplete {
            cancelPending()
            if case .progress = bar { complete() }
            return
        }
        switch next.progress {
        case .determinate(let fraction):
            cancelPending()
            setBar(.progress(.determinate(fraction)))
        case .indeterminate:
            if case .progress = bar { setBar(.progress(.indeterminate)); return }
            guard pendingIndeterminate == nil else { return }
            pendingIndeterminate = Task { [weak self] in
                do { try await Task.sleep(for: Self.indeterminateDelay) } catch { return }
                guard let self, self.generation == generation, self.status.progress == .indeterminate else { return }
                self.pendingIndeterminate = nil
                self.setBar(.progress(.indeterminate))
            }
        case nil:
            cancelPending()
            setBar(.hidden)
        }
    }

    private func complete() {
        setBar(.completed)
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.completionDuration) } catch { return }
            guard let self, self.bar == .completed else { return }
            self.completionTask = nil
            self.setBar(.hidden)
        }
    }

    private func cancelPending() {
        pendingIndeterminate?.cancel()
        pendingIndeterminate = nil
    }

    private func setBar(_ next: ViewerBarState) {
        if bar != next { bar = next }
    }
}

/// A thin bar under the viewer status in the toolbar title. It keeps its space when idle, so
/// the title does not move.
struct ViewerProgressBar: View {
    @ObservedObject var model: ViewerStatusModel
    let reduceMotion: Bool

    /// Opaque: the accent color at full strength at the leading head, blended toward the window
    /// background (not made transparent) along the tail.
    private var fill: LinearGradient {
        let tail = Color.accentColor.mix(with: Color(nsColor: .windowBackgroundColor), by: 0.6)
        let middle = Color.accentColor.mix(with: Color(nsColor: .windowBackgroundColor), by: 0.35)
        return LinearGradient(stops: [.init(color: tail, location: 0),
                                      .init(color: middle, location: 0.6),
                                      .init(color: .accentColor, location: 1)],
                              startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                switch model.bar {
                case .progress(.determinate(let fraction)):
                    Capsule()
                        .fill(fill)
                        .frame(width: max(3, geometry.size.width * fraction))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                case .progress(.indeterminate):
                    if reduceMotion {
                        Capsule().fill(Color.accentColor.mix(with: Color(nsColor: .windowBackgroundColor), by: 0.35))
                    } else {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                            let period = 1.4
                            let phase = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: period) / period
                            let width = geometry.size.width * 0.3
                            Capsule()
                                .fill(fill)
                                .frame(width: width)
                                .offset(x: (geometry.size.width + width) * phase - width)
                        }
                    }
                case .completed:
                    Capsule().fill(Color.green)
                case .hidden:
                    EmptyView()
                }
            }
            .clipShape(Capsule())
            .opacity(model.bar == .hidden ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: model.bar == .hidden)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
