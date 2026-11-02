import Foundation
import SynologyAPI

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
    var reconciliation: Task<Void, Error>?
    var reconciliationID: UUID?
    var reconciled = false
    var inventoryCurrent = false
    var locationProjectionLoaded = false
    var locationPublicationID: UUID?
    var locationPublicationTask: Task<Void, Never>?
    var lastPublishedInventoryVerified: Bool?
    var sourceUnavailable = false
    var revision: Int64 = 0
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
    var albumMutationInProgress = false
    var albumMutationWriting = false
    var albumMutationID: Int64?
    var albumSharingObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var albumListEpoch: UInt64 = 0
    var peopleMutationsInProgress: Set<PhotoSpace> = []
    var peopleMutationSpaces: Set<PhotoSpace> = []
    var peopleMutationCollections: Set<PhotoCollectionDescriptor> = []
    var peopleEpoch: [PhotoSpace: UInt64] = [:]
    var peopleJob: [PhotoSpace: SharedJob<[PersonSummary]>] = [:]
    var subjectsJob: [PhotoSpace: SharedJob<[SubjectSummary]>] = [:]
    var tagsJob: [PhotoSpace: SharedJob<[TagSummary]>] = [:]
    var folderJobs: [PhotoCollectionDescriptor: SharedJob<FolderDirectory>] = [:]
    var albumListJob: SharedJob<[AlbumSummary]>?
    var albumListLatest: [AlbumSummary]?
    var sharedLocations = SharedLocationState()
    var locationIndexWork: SharedJob<[PhotoLocationRecord]>?
    var locationProjectionObservers: [UUID: AsyncStream<LocationIndexEvent>.Continuation] = [:]
    var locationIndexObservers: [UUID: AsyncStream<LocationIndexEvent>.Continuation] = [:]
    var locationRecords: [Int64: PhotoLocationRecord] = [:]
    var locationRevision: UInt64 = 0
    var mapFilterInvalidationObservers: [UUID: AsyncStream<PhotoCollectionDescriptor>.Continuation] = [:]
    var selectionRetentions: [PhotoCollectionDescriptor: SelectionRegistrationRetention] = [:]
    var selectionLeases: [UUID: Set<PhotoCollectionDescriptor>] = [:]
    var deferredSelectionUnregisters: Set<PhotoCollectionDescriptor> = []
    var mapFilters: [UUID: MapFilterState] = [:]
    var sessionFilterCatalogs: [PhotoCollectionDescriptor: LibraryFilterCatalog] = [:]
    var libraryFilters: [UUID: LibraryFilterCollectionState] = [:]

    var hasDemand: Bool {
        reconciliation != nil || !detailJobs.isEmpty || !pendingPages.isEmpty || !activePages.isEmpty ||
            !directSubscribers.isEmpty || !initialSubscribers.isEmpty || !timelineJobs.isEmpty || !pageJobs.isEmpty ||
            albumListJob != nil || !peopleJob.isEmpty || !subjectsJob.isEmpty || !tagsJob.isEmpty || !folderJobs.isEmpty || locationIndexWork != nil || sharedLocations.job != nil
    }
    mutating func clearSourceWork() {
        initialized = false; reconciled = false; sourceUnavailable = false; revision = 0
        inventoryCurrent = false; locationProjectionLoaded = false; lastPublishedInventoryVerified = nil
        reconciliation = nil; reconciliationID = nil
        locationPublicationTask = nil; locationPublicationID = nil
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
