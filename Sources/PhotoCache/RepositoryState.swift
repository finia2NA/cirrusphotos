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
    var admissionEpoch: UInt64 = 0
    var resetInProgress = false
    var successfulResetRevision: UInt64 = 0
    var resetObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    var resetJob: MetadataResetJob?
    var timelineJobs: [PhotoCollectionDescriptor: SharedJob<TimelineSnapshot>] = [:]
    var latestTimelines: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    var initialSubscribers: Set<UUID> = []
    var mutationEpochs: [PhotoCollectionDescriptor: UInt64] = [:]
    var refreshObservers: [PhotoCollectionDescriptor: [UUID: AsyncStream<ResourceEvent<TimelineSnapshot>>.Continuation]] = [:]
    var pageJobs: [String: SharedJob<[PhotoItem]>] = [:]
    var pageJobEpochs: [String: UInt64] = [:]
    var personalPageObservers: [UUID: PersonalPageObserver] = [:]
    var pendingPagePromotions: [String] = []
    var albumListJob: SharedJob<[AlbumSummary]>?
    var albumListLatest: [AlbumSummary]?
    var locationIndexWork: SharedJob<[PhotoLocationRecord]>?
    var locationIndexObservers: [UUID: AsyncStream<LocationIndexEvent>.Continuation] = [:]
    var locationRecords: [Int64: PhotoLocationRecord] = [:]
    var locationRevision: UInt64 = 0
    var mapFilterInvalidationObservers: [UUID: AsyncStream<PhotoCollectionDescriptor>.Continuation] = [:]
    var mapFilters: [UUID: MapFilterState] = [:]
    var mapFilterPages: [String: [PhotoItem]] = [:]
    var mapFilterPageOrder: [String] = []
    var libraryFilters: [UUID: LibraryFilterCollectionState] = [:]
    var libraryFilterPages: [String: [PhotoItem]] = [:]
    var libraryFilterPageOrder: [String] = []

    var hasDemand: Bool {
        !initialSubscribers.isEmpty || !timelineJobs.isEmpty || !pageJobs.isEmpty ||
            albumListJob != nil || locationIndexWork != nil
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
    /// Distinguishes a registration from a later filter that happens to reuse the
    /// same descriptor. Suspended page assembly must never publish into the latter.
    let registrationID: UUID
    let metadataEpoch: UInt64
    let locationRevision: UInt64?
    let source: PhotoCollectionDescriptor
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
    var videoSegmentJobs: [String: VideoSegmentJob] = [:]

    var hasDemand: Bool { !thumbnailJobs.isEmpty || !fullImageJobs.isEmpty || !videoSegmentJobs.isEmpty }
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


struct RepositoryItemMutationState {
    var observers: [UUID: AsyncStream<PhotoItemChange>.Continuation] = [:]
    var pendingIDs: Set<Int64> = []

    func publish(_ change: PhotoItemChange) {
        for observer in observers.values { observer.yield(change) }
    }
}
