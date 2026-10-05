import Foundation
import SynologyAPI

// These values are owned exclusively by CachedPhotosRepository. None introduces a
// separate executor, so read/modify/write sequences remain on the repository actor.

struct RepositoryAuthenticationState {
    var task: Task<Void, Error>?
    var attempt: UUID?
    var connected = false
    var status: AuthenticationStatus = .notStarted
    var observers: [UUID: AsyncStream<AuthenticationStatus>.Continuation] = [:]

    mutating func setStatus(_ next: AuthenticationStatus) {
        guard status != next else { return }
        status = next
        for observer in observers.values { observer.yield(next) }
    }

    mutating func resetAttempt() {
        task = nil
        attempt = nil
        setStatus(.notStarted)
    }

    mutating func cancelIfUnconnected() {
        guard !connected else { return }
        task?.cancel()
        task = nil
        attempt = nil
        if case .loggingIn = status { setStatus(.notStarted) }
    }
}

struct RepositoryMetadataWork {
    var timelineJobs: [PhotoCollectionDescriptor: SharedJob<TimelineSnapshot>] = [:]
    var latestTimelines: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    var initialSubscribers: Set<UUID> = []
    var mutationEpochs: [PhotoCollectionDescriptor: UInt64] = [:]
    var refreshObservers: [PhotoCollectionDescriptor: [UUID: AsyncStream<ResourceEvent<TimelineSnapshot>>.Continuation]] = [:]
    var pageJobs: [String: SharedJob<[PhotoItem]>] = [:]
    var pageJobEpochs: [String: UInt64] = [:]
    var pendingPagePromotions: [String] = []

    var hasDemand: Bool {
        !initialSubscribers.isEmpty || !timelineJobs.isEmpty || !pageJobs.isEmpty
    }
}

struct RepositoryImageWork {
    var thumbnailJobs: [String: SharedJob<ImageResolution>] = [:]
    var fullImageJobs: [String: SharedJob<FullImageResolution>] = [:]

    var hasDemand: Bool { !thumbnailJobs.isEmpty || !fullImageJobs.isEmpty }
}

struct RepositoryFavoriteState {
    var observers: [UUID: AsyncStream<FavoriteChange>.Continuation] = [:]
    var overrides: [Int64: Bool] = [:]
    var pendingIDs: Set<Int64> = []
    var writeTail: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var metadataDirty = false

    func applyingOverrides(_ items: [PhotoItem]) -> [PhotoItem] {
        items.map { item in
            guard let favorite = overrides[item.id] else { return item }
            return item.withFavorite(favorite)
        }
    }

    mutating func publish(values: [Int64: Bool], section: TimelineSection? = nil, collection: PhotoCollectionDescriptor = .personalLibrary) {
        for (itemID, favorite) in values {
            overrides[itemID] = favorite
        }
        let change = FavoriteChange(values: values, sourceSection: section, sourceCollection: collection)
        for observer in observers.values { observer.yield(change) }
    }
}
