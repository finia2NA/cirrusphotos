import Foundation
import SynologyAPI

/// Encoded image state and task lifetimes, mutated only by the owning viewer actor.
/// Cancelling current work invalidates its request tokens while preserving reusable bytes.
struct ViewerImageWork {
    static let enhancementDelay: Duration = .milliseconds(100)

    struct FullJob {
        let id: UUID
        let location: PhotoViewerLocation
        let resource: FullImageResource
        let allowNetwork: Bool
        let task: Task<Void, Never>
        var data: Data?
        var verified = false
        var failure: String?
        var completed = false
    }
    struct ThumbnailJob {
        let id: UUID
        let allowNetwork: Bool
        let task: Task<Void, Never>
    }
    enum ThumbnailTier: Int, Hashable, Sendable {
        case configured
        case largePreview
    }
    struct ThumbnailRequest: Sendable {
        let tier: ThumbnailTier
        let size: ThumbnailSize
        let purpose: ThumbnailCachePurpose
    }

    var thumbnailData: Data?
    var bestThumbnailTier: ThumbnailTier?
    var thumbnailFailures: [ThumbnailTier: String] = [:]
    var fullImageData: Data?
    var thumbnailStatus: PhotoViewerResourceStatus = .idle
    var fullImageStatus: PhotoViewerResourceStatus = .idle
    var thumbnailJobs: [ThumbnailTier: ThumbnailJob] = [:]
    var thumbnailPrefetchJobs: [String: ThumbnailJob] = [:]
    var fullTask: Task<Void, Never>?
    var fullAttempt: UUID?
    var fullTaskAllowsNetwork = false
    var fullJobs: [String: FullJob] = [:]
    var prefetchEnabledGeneration: UInt64?
    var enhancementTask: Task<Void, Never>?
    var enhancementAttempt: UUID?
    var enhancementsReleasedGeneration: UInt64?

    mutating func cancelCurrent() {
        cancelEnhancementDelay()
        for job in thumbnailJobs.values { job.task.cancel() }
        thumbnailJobs.removeAll()
        fullTask?.cancel()
        fullTask = nil
        fullAttempt = nil
        fullTaskAllowsNetwork = false
        prefetchEnabledGeneration = nil
    }

    mutating func restartCurrent(keeping resource: FullImageResource?) {
        cancelCurrent()
        thumbnailFailures.removeAll()
        cancelFullJobsExcept(resource: resource)
    }

    mutating func resetSelection(keeping resource: FullImageResource?) {
        restartCurrent(keeping: resource)
        thumbnailData = nil
        bestThumbnailTier = nil
        fullImageData = nil
        thumbnailStatus = .idle
        fullImageStatus = .idle
    }

    mutating func cancelAll() {
        cancelCurrent()
        for job in thumbnailPrefetchJobs.values { job.task.cancel() }
        thumbnailPrefetchJobs.removeAll()
        cancelFullJobsExcept(resource: nil)
    }

    private mutating func cancelEnhancementDelay() {
        enhancementTask?.cancel()
        enhancementTask = nil
        enhancementAttempt = nil
        enhancementsReleasedGeneration = nil
    }

    private mutating func cancelFullJobsExcept(resource: FullImageResource?) {
        let keep = resource.map(PhotoViewerSession.resourceKey)
        for (key, job) in fullJobs where key != keep {
            job.task.cancel()
            fullJobs.removeValue(forKey: key)
        }
    }
}
