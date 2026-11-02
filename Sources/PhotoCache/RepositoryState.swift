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



enum MetadataResetScope: Sendable {
    case metadata
    case all
}

struct MetadataResetJob {
    let id: UUID
    let scope: MetadataResetScope
    let task: Task<UInt64, Error>
}

/// Session-only state behind one `.mapFilter` collection.
struct MapFilterState {
    let space: PhotoSpace
    /// Distinguishes a registration from a later filter that happens to reuse the
    /// same descriptor. Suspended page assembly must never publish into the latter.
    let registrationID: UUID
    let metadataEpoch: UInt64
    let locationRevision: UInt64
    let snapshot: TimelineSnapshot
    let itemIDsBySection: [[Int64]]
    let idsBySection: [TimelineSection: [Int64]]
}

struct LibraryFilterCollectionState {
    let registrationID: UUID
    let metadataEpoch: UInt64
    let registration: LibraryFilterRegistration
    let referencesBySection: [TimelineSection: [LibraryFilterReference]]
}

struct RepositoryImageWork {
    var thumbnailJobs: [String: SharedJob<ImageResolution>] = [:]
    var fullImageJobs: [String: SharedJob<FullImageResolution>] = [:]
    var thumbnailFinishWithoutSubscribers: Set<String> = []
    var fullImageFinishWithoutSubscribers: Set<String> = []
    var fullImageProgressObservers: [String: [UUID: @Sendable (TransferProgress) -> Void]] = [:]
    var fullImageProgress: [String: TransferProgress] = [:]
    var videoWindowJobs: [String: VideoWindowJob] = [:]

    var hasDemand: Bool { !thumbnailJobs.isEmpty || !fullImageJobs.isEmpty || !videoWindowJobs.isEmpty }
}

final class RepositoryFavoriteState {
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

    func publish(values: [Int64: Bool], section: TimelineSection? = nil, collection: PhotoCollectionDescriptor = .library(.personal)) {
        for (itemID, favorite) in values {
            overrides[itemID] = favorite
        }
        let change = FavoriteChange(values: values, sourceSection: section, sourceCollection: collection)
        for observer in observers.values { observer.yield(change) }
    }
}


struct RepositoryItemMutationState {
    var observers: [UUID: AsyncStream<PhotoItemChange>.Continuation] = [:]
    var pendingIDs: Set<PhotoItemIdentity> = []

    func publish(_ change: PhotoItemChange) {
        for observer in observers.values { observer.yield(change) }
    }
}
