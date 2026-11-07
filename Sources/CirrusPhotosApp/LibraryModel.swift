import Combine
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

struct TimelineWarmingTarget {
    let collection: PhotoCollectionDescriptor
    let snapshot: TimelineSnapshot
    let revision: Int
    let title: String
}

struct TimelineWarmingTargetDiscovery {
    let targets: [TimelineWarmingTarget]
    let failures: [String]
}

@MainActor
@Observable
final class LibraryModel {
    enum TimelineUpdateReason: Equatable {
        case authoritativeLoad
        case favoriteMutationRefresh
    }

    @ObservationIgnored var selectionAuthorities: [PhotoCollectionDescriptor: PhotoSelectionAuthority] = [:]
    @ObservationIgnored var sessionSources: [PhotoCollectionDescriptor: PhotoCollectionDescriptor] = [:]
    var albumOperation: AlbumOperation?
    var itemDeletion: ItemDeletion?
    @ObservationIgnored var itemDeletionTask: Task<Void, Never>?
    @ObservationIgnored var albumOperationTask: Task<Void, Never>?
    @ObservationIgnored var filterAuthorities: [PhotoCollectionDescriptor: [[Bool]]] = [:]
    @ObservationIgnored var filterMemberships: [PhotoCollectionDescriptor: [[Int64]]] = [:]
    // Per-collection timeline state. Untracked storage: every write bumps the tracked
    // `collectionStateRevision` through `collectionStateChanged()`, immediately, or coalesced
    // while background warming delivers timelines that no view displays yet. Readers go
    // through the accessors below, which register the revision as their dependency.
    @ObservationIgnored private(set) var snapshots: [PhotoCollectionDescriptor: TimelineSnapshot] = [:] { didSet { collectionStateChanged() } }
    @ObservationIgnored private(set) var snapshotRevisions: [PhotoCollectionDescriptor: Int] = [:] { didSet { collectionStateChanged() } }
    @ObservationIgnored private(set) var viewerSnapshotRevisions: [PhotoCollectionDescriptor: Int] = [:] { didSet { collectionStateChanged() } }
    @ObservationIgnored private(set) var timelineVerifications: [PhotoCollectionDescriptor: Bool] = [:] { didSet { collectionStateChanged() } }
    @ObservationIgnored private(set) var collectionErrors: [PhotoCollectionDescriptor: String] = [:] { didSet { collectionStateChanged(); noteConnectionState() } }
    private(set) var collectionStateRevision: UInt64 = 0
    @ObservationIgnored private var quietCollectionUpdates = false
    @ObservationIgnored private var pendingCollectionAnnouncement: Task<Void, Never>?
    private static let quietAnnouncementDelay: Duration = .seconds(1)
    private(set) var isLoading = true
    private(set) var authenticationStatus: AuthenticationStatus = .notStarted { didSet { noteConnectionState() } }
    private(set) var retryRevision = 0
    private(set) var canToggleViewerFavorite = false
    var showsFilmstrip = false
    var showsHistogram = false
    var showsHighlightPeaking = false
    var showsFocusEdges = false
    private(set) var canCloseViewer = false
    private(set) var canNavigateBack = false
    private(set) var canOpenSelectedPhoto = false
    private(set) var browserCommandsActive = false
    /// Whether the browser selection-favorite action may begin (selection non-empty, no confirmation pending).
    private(set) var canToggleBrowserFavorite = false
    /// True when every item of a small browser selection is a favorite; fills the toolbar heart.
    var browserSelectionFavorited = false
    @ObservationIgnored var favoriteStateKey: String?
    @ObservationIgnored var favoriteStateTask: Task<Void, Never>?
    @ObservationIgnored var favoriteObserverTasks: [Task<Void, Never>] = []
    @ObservationIgnored var favoriteObserverRepository: ObjectIdentifier?
    /// Pending confirmation for a large selection-favorite action; nil when no confirmation is needed.
    var pendingFavoriteConfirmation: SelectionFavoriteConfirmation?
    var rotationBusy = false
    var annotationBusy = false
    var thumbnailRotationProgress: ThumbnailRotationProgress?
    var isFixingThumbnailRotations = false
    private(set) var metadataInvalidationRevision: UInt64 = 0
    private(set) var cacheResetInProgress = false
    private(set) var cacheResetError: String?
    private(set) var isRefreshing = false
    private(set) var refreshFailure: String? { didSet { noteConnectionState() } }
    /// The last state `noteConnectionState` saw, and whether a lost-connection notice is showing.
    @ObservationIgnored var lastConnectionState: ConnectionState?
    @ObservationIgnored var connectionLossNoticed = false
    /// Whether the NAS has been reached this session. Until then, failing to reach it is
    /// expected (offline launch) and posts no notice.
    @ObservationIgnored var hasConnected = false
    var albumMembershipRevision: UInt64 = 0
    @ObservationIgnored var changedAlbumID: Int64?
    private(set) var mapFilterInvalidationRevision: UInt64 = 0
    @ObservationIgnored private(set) var invalidatedMapFilter: PhotoCollectionDescriptor?
    @ObservationIgnored var browserSelectionStates: [PhotoCollectionDescriptor: BrowserSelectionState] = [:]
    @ObservationIgnored var browserCommandHandler: ((BrowserSelectionCommand) -> Void)?
    @ObservationIgnored var browserCommandOwner: UUID?
    @ObservationIgnored var browserCommandSnapshot: BrowserCommandSnapshot = .inactive
    /// The last snapshot published while the browser was the key responder. Kept after the
    /// Info panel takes key so its rating control can still act on the selection.
    @ObservationIgnored var lastActiveBrowserSnapshot: BrowserCommandSnapshot?
    @ObservationIgnored weak var activeViewer: PhotoViewerPresentation?
    @ObservationIgnored var viewerCloseHandler: (() -> Void)?
    @ObservationIgnored var backHandler: (() -> Void)?
    @ObservationIgnored var thumbnailRotationTask: Task<Void, Never>?
    /// Browser and Info panel favorite changes run one after another.
    @ObservationIgnored var favoriteWriteTail: Task<Void, Never>?
    /// Resumes the queued favorite change waiting for the confirmation alert.
    @ObservationIgnored var favoriteConfirmationReply: CheckedContinuation<Bool, Never>?
    var authenticationFailed: Bool {
        switch authenticationStatus {
        case .failed, .unreachable, .needsSignIn, .untrustedCertificate: true
        case .notStarted, .loggingIn, .signedIn: false
        }
    }
    private(set) var cacheUsage: Int64 = 0
    private(set) var albums: [AlbumSummary] = []
    private(set) var albumsVerified = false
    private(set) var albumListError: String?
    private(set) var presentationNamespace: String?
    let session: AppSession
    /// The session's Activity panel, where tracked changes report progress and failures.
    var activity: ActivityCenter { session.activity }
    /// Album writes run one at a time; the repository rejects concurrent album mutations.
    @ObservationIgnored var albumWriteTail: Task<Void, Never>?
    /// Tracked so observers that check it (warming, command availability) re-run once
    /// `load()` opens the repository.
    private(set) var repository: CachedPhotosRepository?
    @ObservationIgnored var started = false
    @ObservationIgnored var authenticationTask: Task<Void, Never>?
    @ObservationIgnored var refreshTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]
    @ObservationIgnored var albumsTask: Task<Void, Never>?
    @ObservationIgnored var incomingAlbumsTask: Task<Void, Never>?
    @ObservationIgnored var ownedAlbums: [AlbumSummary] = []
    @ObservationIgnored var receivedIncomingAlbums: [AlbumSummary] = []
    @ObservationIgnored var ownedAlbumsVerified = false
    @ObservationIgnored var incomingAlbumsVerified = false
    @ObservationIgnored var metadataResetTask: Task<Void, Never>?
    @ObservationIgnored var albumSharingObservationTask: Task<Void, Never>?
    @ObservationIgnored var mapFilterInvalidationTask: Task<Void, Never>?
    @ObservationIgnored var albumListRequested = false
    @ObservationIgnored var openedCollections: Set<PhotoCollectionDescriptor> = []
    @ObservationIgnored var collectionFetchTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]

    var preferences: AppPreferences { session.preferences }
    @ObservationIgnored var preferenceObservations: Set<AnyCancellable> = []
    @ObservationIgnored var thumbnailPolicyRevision: UInt64 = 0

    convenience init(repository: CachedPhotosRepository? = nil, preferences: AppPreferences = AppPreferences(),
                     activity: ActivityCenter = ActivityCenter()) {
        self.init(session: AppSession(preferences: preferences, repository: repository, activity: activity))
    }

    init(session: AppSession) {
        self.session = session
        self.repository = session.repository
        self.presentationNamespace = session.repository?.namespace
        let preferences = session.preferences
        // The repository applies the thumbnail and budget preferences; latest change wins.
        preferences.$thumbnailSize.dropFirst().removeDuplicates().sink { [weak self] size in
            guard let self, let repository = self.repository else { return }
            self.thumbnailPolicyRevision &+= 1
            let revision = self.thumbnailPolicyRevision
            Task { [weak self] in
                guard self?.thumbnailPolicyRevision == revision else { return }
                try? await repository.setConfiguredThumbnailSize(size)
            }
        }.store(in: &preferenceObservations)
        preferences.$budgetFraction.dropFirst().removeDuplicates().sink { [weak self] fraction in
            guard let repository = self?.repository else { return }
            Task { try? await repository.setBudget(CacheBudget.bytes(at: fraction)) }
        }.store(in: &preferenceObservations)
    }


    private func collectionStateChanged() {
        guard quietCollectionUpdates else {
            pendingCollectionAnnouncement?.cancel()
            pendingCollectionAnnouncement = nil
            collectionStateRevision &+= 1
            return
        }
        guard pendingCollectionAnnouncement == nil else { return }
        pendingCollectionAnnouncement = Task { [weak self] in
            try? await Task.sleep(for: Self.quietAnnouncementDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingCollectionAnnouncement = nil
            self.collectionStateRevision &+= 1
        }
    }

    func snapshot(for collection: PhotoCollectionDescriptor) -> TimelineSnapshot? {
        _ = collectionStateRevision
        return snapshots[collection]
    }
    func snapshotRevision(for collection: PhotoCollectionDescriptor) -> Int {
        _ = collectionStateRevision
        return snapshotRevisions[collection, default: 0]
    }
    func viewerSnapshotRevision(for collection: PhotoCollectionDescriptor) -> Int {
        _ = collectionStateRevision
        return viewerSnapshotRevisions[collection, default: 0]
    }
    func timelineVerified(for collection: PhotoCollectionDescriptor) -> Bool {
        _ = collectionStateRevision
        return timelineVerifications[collection] == true
    }
    func error(for collection: PhotoCollectionDescriptor) -> String? {
        _ = collectionStateRevision
        return collectionErrors[collection]
    }

    func albumName(for collection: PhotoCollectionDescriptor) -> String? {
        album(for: collection)?.name
    }

    func album(for collection: PhotoCollectionDescriptor) -> AlbumSummary? {
        let source = sessionSources[collection] ?? collection
        return albums.first { $0.collection == source }
    }

    /// Starts loading the Personal Space album list on first demand.
    func ensureAlbumsLoaded() {
        albumListRequested = true
        startAlbumListFetchIfNeeded()
    }

    func startAlbumListFetchIfNeeded() {
        guard let repository else { return }
        if albumsTask == nil {
            albumsTask = Task { [weak self] in
                for await event in await repository.albums() {
                    guard !Task.isCancelled else { return }
                    self?.receiveAlbums(event, incoming: false)
                }
            }
        }
        if incomingAlbumsTask == nil {
            incomingAlbumsTask = Task { [weak self] in
                for await event in await repository.incomingAlbums() {
                    guard !Task.isCancelled else { return }
                    self?.receiveAlbums(event, incoming: true)
                }
            }
        }
    }

    /// Starts loading a persistent collection lazily. Session-derived collections
    /// own their snapshots and are registered separately.
    /// `quiet` coalesces the resulting change announcements; background warming uses it.
    func ensureCollectionLoaded(_ collection: PhotoCollectionDescriptor, quiet: Bool = false) {
        guard !collection.isSessionDerived else { return }
        openedCollections.insert(collection)
        startCollectionFetchIfNeeded(collection, quiet: quiet)
    }

    /// Resolves every persistent collection that participates in explicit metadata
    /// warming. Album discovery and unopened album timeline scans begin only after
    /// the user presses Start in the warming window.
    func discoverTimelineWarmingTargets(includeSharedSpace: Bool = false) async -> TimelineWarmingTargetDiscovery {
        guard repository != nil else {
            return .init(targets: [], failures: ["The photo repository is unavailable."])
        }

        let baseCollections: [PhotoCollectionDescriptor] = [.library(.personal), .favorites(.personal)] + (includeSharedSpace ? [.library(.shared), .favorites(.shared)] : [])
        for collection in baseCollections {
            startCollectionFetchIfNeeded(collection)
        }
        for collection in baseCollections {
            await collectionFetchTasks[collection]?.value
        }

        ensureAlbumsLoaded()
        await albumsTask?.value

        let albumCollections = ownedAlbums.compactMap(\.collection)
        for collection in albumCollections {
            guard !Task.isCancelled else { break }
            ensureCollectionLoaded(collection, quiet: true)
            await collectionFetchTasks[collection]?.value
        }

        let persistentCollections = baseCollections + albumCollections
        var targets: [TimelineWarmingTarget] = []
        var failures: [String] = []
        for collection in persistentCollections {
            guard !Task.isCancelled else { break }
            let title: String
            switch collection {
            case .library(.personal): title = "Personal Library"
            case .library(.shared): title = "Shared Library"
            case .favorites(.personal): title = "Favorites"
            case .favorites(.shared): title = "Shared Favorites"
            case .album(let id): title = albumName(for: collection) ?? "Album \(id)"
            case .folder, .person, .subject, .tag, .recentlyAdded, .incomingAlbum, .mapFilter, .libraryFilter: continue
            }
            if timelineVerified(for: collection), let snapshot = snapshot(for: collection) {
                targets.append(.init(collection: collection, snapshot: snapshot,
                                     revision: snapshotRevision(for: collection), title: title))
            } else {
                failures.append("\(title): \(error(for: collection) ?? "timeline could not be loaded")")
            }
        }
        if !ownedAlbumsVerified {
            failures.append("Albums: \(albumListError ?? "album list could not be loaded")")
        }
        return .init(targets: targets, failures: failures)
    }

    // MARK: - Session Collections

    /// Publishes a session-only collection snapshot (a map filter) without fetching.
    func filterAuthority(for collection: PhotoCollectionDescriptor) -> [[Bool]]? { filterAuthorities[collection] }

    func filterMembership(for collection: PhotoCollectionDescriptor) -> [[Int64]]? { filterMemberships[collection] }

    func selectionAuthority(for collection: PhotoCollectionDescriptor) -> PhotoSelectionAuthority? { selectionAuthorities[collection] }
    func capabilities(for collection: PhotoCollectionDescriptor) -> CollectionCapabilities {
        let source = sessionSources[collection] ?? collection
        return CollectionCapabilities(source: source, incomingAlbums: receivedIncomingAlbums,
                                      incomingAlbumsVerified: incomingAlbumsVerified)
    }

    func registerSessionCollection(_ collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot,
                                   authority: PhotoSelectionAuthority? = nil, source: PhotoCollectionDescriptor? = nil,
                                   filterMembership: [[Int64]]? = nil, filterAuthority: [[Bool]]? = nil) {
        selectionAuthorities[collection] = authority
        sessionSources[collection] = source.map { sessionSources[$0] ?? $0 }
        filterAuthorities[collection] = filterAuthority
        filterMemberships[collection] = filterMembership
        snapshots[collection] = snapshot
        snapshotRevisions[collection, default: 0] += 1
        timelineVerifications[collection] = true
    }

    /// Removes a session-only collection after the repository state is unregistered.
    func unregisterSessionCollection(_ collection: PhotoCollectionDescriptor) {
        snapshots.removeValue(forKey: collection)
        selectionAuthorities.removeValue(forKey: collection)
        sessionSources.removeValue(forKey: collection)
        filterAuthorities.removeValue(forKey: collection)
        filterMemberships.removeValue(forKey: collection)
        snapshotRevisions.removeValue(forKey: collection)
        viewerSnapshotRevisions.removeValue(forKey: collection)
        timelineVerifications.removeValue(forKey: collection)
        collectionErrors.removeValue(forKey: collection)
        browserSelectionStates.removeValue(forKey: collection)
    }

    /// Registers a location-filtered collection for the given records and returns its
    /// descriptor, or nil without a repository.
    func openMapFilter(itemIDs: [Int64],
                       locationRevision: LocationIndexRevision) async -> PhotoCollectionDescriptor? {
        guard let repository else { return nil }
        do {
            let registration = try await repository.registerMapFilter(
                itemIDs: itemIDs, locationRevision: locationRevision
            )
            let source = await repository.mediaCollection(for: registration.descriptor)
            registerSessionCollection(registration.descriptor, snapshot: registration.snapshot, authority: registration.authority, source: source)
            return registration.descriptor
        } catch {
            collectionErrors[.library(.personal)] = reportedFailure(error, operation: "Session collection registration")
            return nil
        }
    }

    func closeMapFilter(_ collection: PhotoCollectionDescriptor) async {
        if let repository { await repository.unregisterMapFilter(collection) }
        unregisterSessionCollection(collection)
    }

    func startCollectionFetchIfNeeded(_ collection: PhotoCollectionDescriptor,
                                              reason: TimelineUpdateReason = .authoritativeLoad,
                                              quiet: Bool = false) {
        guard let repository, collectionFetchTasks[collection] == nil else { return }
        collectionFetchTasks[collection] = Task { [weak self] in
            let started = ContinuousClock.now
            var events = 0
            for await event in await repository.timeline(collection: collection) {
                guard !Task.isCancelled else { return }
                if let folder = collection.folderID {
                    events += 1
                    SynologyDiagnostics.folders.info("timeline folder=\(folder, privacy: .public) event=\(events, privacy: .public) elapsed=\(String(describing: ContinuousClock.now - started), privacy: .public)")
                }
                await self?.receive(event, collection: collection, reason: reason, quiet: quiet)
            }
        }
    }

    func selectionState(for collection: PhotoCollectionDescriptor) -> BrowserSelectionState {
        browserSelectionStates[collection] ?? BrowserSelectionState()
    }

    func setSelectionState(_ state: BrowserSelectionState, for collection: PhotoCollectionDescriptor) {
        browserSelectionStates[collection] = state
    }

    func installBrowserCommands(snapshot: BrowserCommandSnapshot, handler: ((BrowserSelectionCommand) -> Void)?) {
        let active = snapshot.active
        let owner = snapshot.owner
        if active { browserCommandOwner = owner }
        else if browserCommandOwner != nil && browserCommandOwner != owner { return }
        let canOpen = active && snapshot.canOpen
        if browserCommandsActive != active { browserCommandsActive = active }
        if canOpenSelectedPhoto != canOpen { canOpenSelectedPhoto = canOpen }
        browserCommandHandler = active ? handler : nil
        browserCommandSnapshot = active ? snapshot : .inactive
        if active { lastActiveBrowserSnapshot = snapshot }
        updateBrowserFavoriteAvailability()
        refreshBrowserSelectionFavorite()
        if !active { browserCommandOwner = nil }
    }

    func installBrowserCommands(
        owner: UUID,
        active: Bool,
        canOpen: Bool,
        canToggleFavorite: Bool = false,
        collection: PhotoCollectionDescriptor,
        selectedOrdinals: IndexSet = IndexSet(),
        handler: ((BrowserSelectionCommand) -> Void)? = nil
    ) {
        let snapshot = BrowserCommandSnapshot(
            owner: owner,
            active: active,
            canOpen: canOpen,
            canToggleFavorite: canToggleFavorite,
            collection: collection,
            indexFingerprint: nil,
            selectionGeneration: nil,
            selectedOrdinals: selectedOrdinals,
            knownItemIDsByOrdinal: [:]
        )
        installBrowserCommands(snapshot: snapshot, handler: handler)
    }

    var browserSelectionCount: Int { browserCommandSnapshot.selectedOrdinals.count }

    var canToggleFavorite: Bool {
        if activeViewer != nil {
            return canToggleViewerFavorite
        } else {
            return canToggleBrowserFavorite
        }
    }

    func updateBrowserFavoriteAvailability() {
        let available = browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsSpaceItemActions &&
            browserCommandSnapshot.canToggleFavorite &&
            !browserCommandSnapshot.selectedOrdinals.isEmpty &&
            pendingFavoriteConfirmation == nil &&
            timelineVerified(for: browserCommandSnapshot.collection)
        if canToggleBrowserFavorite != available { canToggleBrowserFavorite = available }
    }

    func performBrowserCommand(_ command: BrowserSelectionCommand) {
        guard browserCommandsActive else { return }
        browserCommandHandler?(command)
    }

    func installBackHandler(_ handler: (() -> Void)?) {
        backHandler = handler
        if canNavigateBack != (handler != nil) { canNavigateBack = handler != nil }
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        backHandler?()
    }

    func setActiveViewer(_ viewer: PhotoViewerPresentation?) {
        activeViewer = viewer
        if viewer == nil { installViewerCloseHandler(nil) }
        updateViewerCommands()
    }

    func installViewerCloseHandler(_ handler: (() -> Void)?) {
        viewerCloseHandler = handler
        if canCloseViewer != (handler != nil) { canCloseViewer = handler != nil }
    }

    func closeViewer() {
        guard canCloseViewer else { return }
        viewerCloseHandler?()
    }

    func updateViewerCommands() {
        canToggleViewerFavorite = activeViewer.map { capabilities(for: $0.collection).allowsSpaceItemActions && $0.canToggleFavorite } ?? false
    }

    func toggleViewerFavorite() {
        guard canToggleViewerFavorite else { return }
        activeViewer?.toggleFavorite()
        updateViewerCommands()
    }

    func downloadSelection(_ selection: BrowserCommandSnapshot, kind: PhotoDownloadKind, choose: Bool) {
        guard capabilities(for: selection.collection).allowsDownloads, let repository, let captured = selection.captureSelection(timeline: selection.timeline) else { return }
        session.downloads.start(repository: repository, source: .selection(captured), kind: kind, choose: choose)
    }

    func editSelection(_ selection: BrowserCommandSnapshot, application: URL) {
        guard capabilities(for: selection.collection).allowsPersonalActions, let repository, let timeline = selection.timeline else { return }
        session.downloads.edit(repository: repository, snapshot: timeline, selection: selection,
                               item: nil, collection: selection.collection, applicationURL: application)
    }

    func editViewerItem(_ item: PhotoItem, repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor, application: URL) {
        session.downloads.edit(repository: repository, snapshot: nil, selection: nil,
                               item: item, collection: collection, applicationURL: application)
    }

    func downloadViewerItem(_ item: PhotoItem, repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor,
                            kind: PhotoDownloadKind, choose: Bool) {
        session.downloads.start(repository: repository, source: .item(item, collection: collection), kind: kind, choose: choose)
    }

    // MARK: - Lifecycle

    /// Stops observing the repository and cancels this model's work, for sign-out or an
    /// account switch. The session's `end()` and the repository's `shutdown()` follow.
    func end() {
        var tasks: [Task<Void, Never>?] = [
            itemDeletionTask, albumOperationTask, pendingCollectionAnnouncement, favoriteStateTask,
            thumbnailRotationTask, favoriteWriteTail, albumWriteTail, authenticationTask, albumsTask,
            incomingAlbumsTask, metadataResetTask, albumSharingObservationTask, mapFilterInvalidationTask
        ]
        tasks += favoriteObserverTasks.map { $0 }
        tasks += refreshTasks.values.map { $0 }
        tasks += collectionFetchTasks.values.map { $0 }
        for task in tasks { task?.cancel() }
        favoriteObserverTasks.removeAll()
        refreshTasks.removeAll()
        collectionFetchTasks.removeAll()
        favoriteConfirmationReply?.resume(returning: false)
        favoriteConfirmationReply = nil
        session.end()
    }

    func load() async {
        guard !started else { return }
        started = true
        isLoading = true
        collectionErrors.removeAll()
        do {
            let repository = try session.start()
            if self.repository !== repository { self.repository = repository }
            presentationNamespace = repository.namespace
            try await repository.setConfiguredThumbnailSize(preferences.thumbnailSize)
            if albumSharingObservationTask == nil {
                albumSharingObservationTask = Task { [weak self] in
                    for await _ in await repository.albumSharingChanges() {
                        guard !Task.isCancelled, let self else { return }
                        self.albumsTask?.cancel()
                        self.albumsTask = nil
                        self.albumsVerified = false
                        if self.albumListRequested { self.startAlbumListFetchIfNeeded() }
                    }
                }
            }
            if metadataResetTask == nil {
                metadataResetTask = Task { [weak self] in
                    for await revision in await repository.metadataCacheResets() {
                        guard !Task.isCancelled else { return }
                        guard revision > 0 else { continue }
                        self?.handleMetadataInvalidation(revision)
                    }
                }
            }
            if mapFilterInvalidationTask == nil {
                mapFilterInvalidationTask = Task { [weak self] in
                    for await collection in await repository.mapFilterInvalidations() {
                        guard !Task.isCancelled else { return }
                        self?.handleMapFilterInvalidation(collection)
                    }
                }
            }
            if authenticationTask == nil {
                authenticationTask = Task { [weak self] in
                    for await status in await repository.authentication() {
                        guard !Task.isCancelled else { return }
                        self?.authenticationStatus = status
                    }
                }
            }
            for collection in PhotoCollectionDescriptor.bootstrapCollections where refreshTasks[collection] == nil {
                refreshTasks[collection] = Task { [weak self] in
                    for await event in await repository.timelineRefreshes(collection: collection) {
                        guard !Task.isCancelled else { return }
                        await self?.receive(event, collection: collection,
                                      reason: .favoriteMutationRefresh)
                    }
                }
            }
            if albumListRequested { startAlbumListFetchIfNeeded() }
            for collection in openedCollections {
                startCollectionFetchIfNeeded(collection)
            }
            for collection in PhotoCollectionDescriptor.bootstrapCollections {
                startCollectionFetchIfNeeded(collection)
            }
            for collection in PhotoCollectionDescriptor.bootstrapCollections {
                await collectionFetchTasks[collection]?.value
            }
            await refreshUsage()
        } catch {
            collectionErrors[.library(.personal)] = reportedFailure(error, operation: "Startup")
        }
        isLoading = false
    }

    func receiveAlbums(_ event: ResourceEvent<[AlbumSummary]>, incoming: Bool) {
        switch event {
        case .value(let list, let verified):
            if incoming { receivedIncomingAlbums = list; incomingAlbumsVerified = verified }
            else { ownedAlbums = list; ownedAlbumsVerified = verified }
            let combined = ownedAlbums + receivedIncomingAlbums
            let combinedVerified = ownedAlbumsVerified && incomingAlbumsVerified
            // Never expose a provisional replacement under the preceding list’s authority.
            // Unchanged values are not reassigned: each publish re-renders the whole window.
            if albums != combined {
                if albumsVerified { albumsVerified = false }
                albums = combined
            }
            if albumsVerified != combinedVerified { albumsVerified = combinedVerified }
            if verified {
                if albumListError != nil { albumListError = nil }
                if incoming {
                    for collection in openedCollections where collection.incomingAlbumIdentity != nil {
                        collectionFetchTasks.removeValue(forKey: collection)?.cancel()
                        startCollectionFetchIfNeeded(collection)
                    }
                }
            }
        case .failure(let message):
            let description = message.localizedDescription
            if albumListError != description { albumListError = description }
        }
    }

    func receive(_ event: ResourceEvent<TimelineSnapshot>, collection: PhotoCollectionDescriptor,
                         reason: TimelineUpdateReason = .authoritativeLoad, quiet: Bool = false) async {
        var authority: PhotoSelectionAuthority?
        if case .value(let snapshot, _) = event {
            authority = await repository?.selectionAuthority(collection: collection, snapshot: snapshot)
        }
        // No suspension below: the flag covers exactly this event's writes.
        quietCollectionUpdates = quiet
        defer { quietCollectionUpdates = false }
        switch event {
        case .value(let snapshot, let verified):
            selectionAuthorities[collection] = authority
            let changed = snapshots[collection]?.sections != snapshot.sections
            if reason == .favoriteMutationRefresh || changed {
                snapshots[collection] = snapshot
                snapshotRevisions[collection, default: 0] += 1
                if changed, reason == .authoritativeLoad {
                    viewerSnapshotRevisions[collection, default: 0] += 1
                }
            }
            // App-wide warming streams many collections; unchanged values are not reassigned.
            if timelineVerifications[collection] != verified { timelineVerifications[collection] = verified }
            if verified, collectionErrors[collection] != nil { collectionErrors.removeValue(forKey: collection) }
            updateBrowserFavoriteAvailability()
        case .failure(let message):
            let description = message.localizedDescription
            if collectionErrors[collection] != description { collectionErrors[collection] = description }
            updateBrowserFavoriteAvailability()
        }
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        albumsTask?.cancel()
        albumsTask = nil
        incomingAlbumsTask?.cancel()
        incomingAlbumsTask = nil
        ownedAlbumsVerified = false
        incomingAlbumsVerified = false
        albumsVerified = false
        albumListError = nil
        for task in collectionFetchTasks.values { task.cancel() }
        collectionFetchTasks.removeAll()
        if let repository { await repository.retryAuthentication() }
        retryRevision += 1
        started = false
        await load()
    }

    /// Reads changes from the NAS now and reloads open views. A failed sign-in or an
    /// unloaded library is retried from the start instead.
    func refresh() async {
        guard let repository, !isRefreshing, !isLoading else { return }
        if !started || authenticationFailed || error(for: .library(.personal)) != nil {
            refreshFailure = nil
            await reload()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let handle = activity.begin(.refresh, retry: { [weak self] _ in
            guard let self else { return false }
            Task { await self.refresh() }
            return true
        })
        do {
            try await repository.refreshMetadata()
            refreshFailure = nil
            handle.succeed()
            activity.resolveFailures(of: .refresh)
            resubscribeAfterRefresh()
        } catch {
            activity.resolveFailures(of: .refresh)
            refreshFailure = handle.fail(error, operation: "Refresh")
        }
    }

    /// Posts a notice when the NAS becomes unavailable and when it is reachable again. A failed
    /// Refresh is already reported as a failure, so it gets no lost-connection notice of its own.
    func noteConnectionState() {
        let state = connectionState
        guard state != lastConnectionState else { return }
        lastConnectionState = state
        switch state {
        case .connected:
            activity.connectionIsHealthy = true
            hasConnected = true
            if connectionLossNoticed {
                connectionLossNoticed = false
                activity.notice("Connected to the NAS again", key: "connection")
            }
        case .degraded(let label, let detail), .failed(let label, let detail):
            activity.connectionIsHealthy = false
            let onlyRefreshFailed = refreshFailure != nil && error(for: .library(.personal)) == nil
            if case .degraded = state, onlyRefreshFailed { return }
            if case .unreachable = authenticationStatus, !hasConnected { return }
            guard !connectionLossNoticed else { return }
            connectionLossNoticed = true
            activity.notice(label, detail: "\(detail) Showing cached content.", key: "connection")
        case .connecting:
            break
        }
    }


    /// Re-runs the album and collection streams without clearing what they show. Each starts
    /// from its cached value, which equals the current one, and merges the re-read result.
    private func resubscribeAfterRefresh() {
        albumsTask?.cancel()
        albumsTask = nil
        incomingAlbumsTask?.cancel()
        incomingAlbumsTask = nil
        if albumListRequested { startAlbumListFetchIfNeeded() }
        let collections = openedCollections.union(PhotoCollectionDescriptor.bootstrapCollections)
        for collection in collections where !collection.isSessionDerived {
            collectionFetchTasks.removeValue(forKey: collection)?.cancel()
            startCollectionFetchIfNeeded(collection)
        }
    }

    func refreshUsage() async {
        if let repository {
            let usage = (try? await repository.usage()) ?? 0
            if cacheUsage != usage { cacheUsage = usage }
        }
    }

    func clearCache() async {
        guard let repository, !cacheResetInProgress else { return }
        cacheResetInProgress = true
        cacheResetError = nil
        defer { cacheResetInProgress = false }
        do {
            try await repository.clearCache()
            DecodedImages.shared.clear()
            await refreshUsage()
        } catch {
            cacheResetError = reportedFailure(error, operation: "Cache clear")
        }
    }

    func clearMetadataCache() async {
        guard let repository, !cacheResetInProgress else { return }
        cacheResetInProgress = true
        cacheResetError = nil
        defer { cacheResetInProgress = false }
        do {
            try await repository.clearMetadataCache()
            await refreshUsage()
        } catch {
            cacheResetError = reportedFailure(error, operation: "Metadata cache clear")
        }
    }

    func revalidateAllMetadata() async {
        guard let repository, !cacheResetInProgress else { return }
        cacheResetInProgress = true
        cacheResetError = nil
        defer { cacheResetInProgress = false }
        do {
            try await repository.revalidateAllMetadata()
        } catch {
            cacheResetError = reportedFailure(error, operation: "Metadata revalidation")
        }
    }

    func handleMetadataInvalidation(_ revision: UInt64) {
        guard revision > metadataInvalidationRevision else { return }
        albumsTask?.cancel()
        albumsTask = nil
        incomingAlbumsTask?.cancel()
        incomingAlbumsTask = nil
        ownedAlbums = []
        receivedIncomingAlbums = []
        ownedAlbumsVerified = false
        incomingAlbumsVerified = false
        for task in collectionFetchTasks.values { task.cancel() }
        collectionFetchTasks.removeAll()
        let affected = Set(snapshots.keys).union(PhotoCollectionDescriptor.bootstrapCollections)
        snapshots.removeAll()
        selectionAuthorities.removeAll()
        sessionSources.removeAll()
        filterAuthorities.removeAll()
        filterMemberships.removeAll()
        for collection in affected {
            snapshotRevisions[collection, default: 0] += 1
            viewerSnapshotRevisions[collection, default: 0] += 1
        }
        timelineVerifications.removeAll()
        collectionErrors.removeAll()
        albumsVerified = false
        albums = []
        albumListError = nil
        browserSelectionStates.removeAll()
        answerFavoriteConfirmation(false)
        metadataInvalidationRevision = revision
        updateBrowserFavoriteAvailability()

        guard repository != nil else { return }
        for collection in PhotoCollectionDescriptor.bootstrapCollections {
            startCollectionFetchIfNeeded(collection)
        }
        for collection in openedCollections {
            startCollectionFetchIfNeeded(collection)
        }
        if albumListRequested { startAlbumListFetchIfNeeded() }
        Task { [weak self] in await self?.refreshUsage() }
    }

    func handleMapFilterInvalidation(_ collection: PhotoCollectionDescriptor) {
        guard collection.isMapFilter, snapshots[collection] != nil else { return }
        unregisterSessionCollection(collection)
        invalidatedMapFilter = collection
        mapFilterInvalidationRevision &+= 1
        updateBrowserFavoriteAvailability()
    }
}
