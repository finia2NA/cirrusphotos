import Foundation
import SynologyAPI

/// Reconciliation of one space's Diff feed for the current run.
struct MetadataSourceState {
    var reconciliation: Task<Void, Error>?
    var reconciliationID: UUID?
    var reconciled = false
    var sourceUnavailable = false
    var revision: Int64 = 0
}

/// Fixed state owned by CachedPhotosRepository, never an independent actor or provider cursor.
struct MetadataEngineState {
    var expectedPageDemands: [UUID: Set<DayPageAddress>] = [:]
    var collectionRecoveries: [PhotoCollectionDescriptor: MetadataCollectionRecovery] = [:]
    var detailJobs: [UUID: MetadataDetailJob] = [:]
    var detailJobByID: [PhotoItemIdentity: UUID] = [:]
    var pendingPages: [DayPageAddress: MetadataPendingPage] = [:]
    var activePages: [DayPageAddress: MetadataPendingPage] = [:]
    var batchJobs: [UUID: Task<Void, Never>] = [:]
    var flushJob: Task<Void, Never>?
    var initialized = false
    /// One Diff source per space; each space has its own cursor and feed.
    var sources: [PhotoSpace: MetadataSourceState] = [:]
    var inventoryCurrent = false
    var directSubscribers: Set<UUID> = []

    var collectionObservers: [UUID: MetadataCollectionObserver] = [:]
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
    var pageJobs: [String: SharedJob<PhotoPageSnapshot>] = [:]
    var forcedMembershipJobs: Set<String> = []
    var pageJobSourceRevisions: [String: Int64] = [:]
    var pageJobEpochs: [String: UInt64] = [:]
    var collectionPageObservers: [UUID: CollectionPageObserver] = [:]
    var pendingPagePromotions: [String] = []
    var collectionIndexJobs: [CollectionIndexJobKey: SharedJob<[CollectionIndexEntry]>] = [:]
    var folderJobs: [PhotoCollectionDescriptor: SharedJob<FolderDirectory>] = [:]
    var albums = AlbumEngineState()
    var people = PeopleEngineState()
    /// Personal Space location projection. Shared Space has its own inventory scan.
    var locations = LocationEngineState()
    var sharedLocations = SharedLocationState()
    var sessions = SessionCollectionState()

    subscript(source space: PhotoSpace) -> MetadataSourceState {
        get { sources[space] ?? MetadataSourceState() }
        set { sources[space] = newValue }
    }

    var hasDemand: Bool {
        sources.values.contains { $0.reconciliation != nil } || !detailJobs.isEmpty || !pendingPages.isEmpty || !activePages.isEmpty ||
            !directSubscribers.isEmpty || !initialSubscribers.isEmpty || !timelineJobs.isEmpty || !pageJobs.isEmpty ||
            albums.listJob != nil || !collectionIndexJobs.isEmpty || !folderJobs.isEmpty || locations.work != nil || sharedLocations.job != nil
    }
    mutating func clearSourceWork() {
        initialized = false; sources.removeAll()
        inventoryCurrent = false; locations.projectionLoaded = false; locations.lastPublishedInventoryVerified = nil
        locations.publicationTask = nil; locations.publicationID = nil
        collectionRecoveries.removeAll(); directSubscribers.removeAll()
    }
}


struct MetadataPendingPage {
    let id = UUID()
    let read: DayPageRead
    var priority: RequestPriority
    var batchID: UUID?
    var waiters: [UUID: CheckedContinuation<PhotoPageSnapshot, Error>]
}

struct AlbumCatalogMembership {
    let grouped: DayGroupedTimeline
    let times: [Int64: Int64]
}

struct MetadataDetailJob {
    let scope: PhotoContentScope
    let task: Task<[Int64: PhotoItem], Error>
    let itemIDs: [Int64]
    var subscribers: Set<UUID>
}

struct CollectionCatalogRead {
    let catalog: CollectionDayCatalog
    let membership: AlbumCatalogMembership?
}

struct MetadataMembershipReadFailure: Error {
    let revision: Int64
    let cause: any Error
}
struct MetadataCollectionRecovery {
    let id: UUID
    let recoveryRevision: Int64
    let task: Task<TimelineSnapshot, Error>
    var active: Bool
}

/// Album-list state and the album write in progress. The `.album` mutation lane
/// serializes writes; `mutationWriting` fences reads of the album being written.
struct AlbumEngineState {
    var mutationWriting = false
    var mutationID: Int64?
    var sharingObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var listEpoch: UInt64 = 0
    var listJob: SharedJob<[AlbumSummary]>?
    var listLatest: [AlbumSummary]?
}

/// People rename and merge fencing, per space.
struct PeopleEngineState {
    var mutationSpaces: Set<PhotoSpace> = []
    var mutationCollections: Set<PhotoCollectionDescriptor> = []
    var epoch: [PhotoSpace: UInt64] = [:]
}

/// The Personal Space location projection and its observers.
struct LocationEngineState {
    var work: SharedJob<[PhotoLocationRecord]>?
    var projectionObservers: [UUID: AsyncStream<LocationIndexEvent>.Continuation] = [:]
    var indexObservers: [UUID: AsyncStream<LocationIndexEvent>.Continuation] = [:]
    var records: [Int64: PhotoLocationRecord] = [:]
    var revision: UInt64 = 0
    var projectionLoaded = false
    var publicationID: UUID?
    var publicationTask: Task<Void, Never>?
    var lastPublishedInventoryVerified: Bool?
}

/// Session-only collections derived from Map pins and metadata filters, and the
/// selection retentions and leases that keep them alive during an operation.
struct SessionCollectionState {
    var mapFilters: [UUID: MapFilterState] = [:]
    var libraryFilters: [UUID: LibraryFilterCollectionState] = [:]
    var filterCatalogs: [PhotoCollectionDescriptor: LibraryFilterCatalog] = [:]
    var selectionRetentions: [PhotoCollectionDescriptor: SelectionRegistrationRetention] = [:]
    var selectionLeases: [UUID: Set<PhotoCollectionDescriptor>] = [:]
    var deferredUnregisters: Set<PhotoCollectionDescriptor> = []
    var mapFilterInvalidationObservers: [UUID: AsyncStream<PhotoCollectionDescriptor>.Continuation] = [:]
}
