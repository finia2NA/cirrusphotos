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
final class LibraryModel: ObservableObject {
    private enum TimelineUpdateReason: Equatable {
        case authoritativeLoad
        case favoriteMutationRefresh
    }

    private var filterAuthorities: [PhotoCollectionDescriptor: [[Bool]]] = [:]
    private var filterMemberships: [PhotoCollectionDescriptor: [[Int64]]] = [:]
    @Published private var snapshots: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    @Published private var snapshotRevisions: [PhotoCollectionDescriptor: Int] = [:]
    @Published private var viewerSnapshotRevisions: [PhotoCollectionDescriptor: Int] = [:]
    @Published private var timelineVerifications: [PhotoCollectionDescriptor: Bool] = [:]
    @Published private var collectionErrors: [PhotoCollectionDescriptor: String] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var authenticationStatus: AuthenticationStatus = .notStarted
    @Published private(set) var retryRevision = 0
    @Published private(set) var canToggleViewerFavorite = false
    @Published var showsFilmstrip = false
    @Published var showsHistogram = false
    @Published var showsHighlightPeaking = false
    @Published private(set) var canCloseViewer = false
    @Published private(set) var canNavigateBack = false
    @Published private(set) var canOpenSelectedPhoto = false
    @Published private(set) var browserCommandsActive = false
    /// Whether the browser selection-favorite action may begin (selection non-empty, no active write).
    @Published private(set) var canToggleBrowserFavorite = false
    /// Pending confirmation for a large selection-favorite action; nil when no confirmation is needed.
    @Published private(set) var pendingFavoriteConfirmation: SelectionFavoriteConfirmation?
    @Published private(set) var browserFavoriteFailure: String?
    @Published private(set) var rotationFailure: String?
    @Published private(set) var rotationBusy = false
    @Published private(set) var thumbnailRotationProgress: ThumbnailRotationProgress?
    @Published private(set) var isFixingThumbnailRotations = false
    @Published private(set) var metadataInvalidationRevision: UInt64 = 0
    @Published private(set) var cacheResetInProgress = false
    @Published private(set) var cacheResetError: String?
    @Published private(set) var mapFilterInvalidationRevision: UInt64 = 0
    private(set) var invalidatedMapFilter: PhotoCollectionDescriptor?
    private var browserSelectionStates: [PhotoCollectionDescriptor: BrowserSelectionState] = [:]
    private var browserCommandHandler: ((BrowserSelectionCommand) -> Void)?
    private var browserCommandOwner: UUID?
    private var browserCommandSnapshot: BrowserCommandSnapshot = .inactive
    private weak var activeViewer: PhotoViewerPresentation?
    private var viewerCloseHandler: (() -> Void)?
    private var backHandler: (() -> Void)?
    private var thumbnailPolicyRevision: UInt64 = 0
    private var thumbnailRotationTask: Task<Void, Never>?
    /// True while a selection-favorite write (or resolution) is in progress.
    private(set) var browserFavoriteBusy = false
    var authenticationFailed: Bool {
        if case .failed = authenticationStatus { return true }
        return false
    }
    @Published var thumbnailSize: ThumbnailSize = ThumbnailSize(rawValue: UserDefaults.standard.string(forKey: "thumbnailSize") ?? "m") ?? .m {
        didSet {
            UserDefaults.standard.set(thumbnailSize.rawValue, forKey: "thumbnailSize")
            if let repository {
                thumbnailPolicyRevision &+= 1
                let revision = thumbnailPolicyRevision
                let size = thumbnailSize
                Task { [weak self] in
                    guard self?.thumbnailPolicyRevision == revision else { return }
                    try? await repository.setConfiguredThumbnailSize(size)
                }
            }
        }
    }
    @Published var loadsLargeViewerPreviews: Bool = UserDefaults.standard.bool(forKey: "loadsLargeViewerPreviews") {
        didSet { UserDefaults.standard.set(loadsLargeViewerPreviews, forKey: "loadsLargeViewerPreviews") }
    }
    @Published var pixelInterpolation: PixelInterpolationPreference = PixelInterpolationPreference(
        rawValue: UserDefaults.standard.string(forKey: "pixelInterpolation") ?? "off"
    ) ?? .off {
        didSet { UserDefaults.standard.set(pixelInterpolation.rawValue, forKey: "pixelInterpolation") }
    }
    @Published var videoMuted: Bool = UserDefaults.standard.bool(forKey: "videoMuted") {
        didSet { UserDefaults.standard.set(videoMuted, forKey: "videoMuted") }
    }
    @Published var videoQuality: VideoQualityPreference = VideoQualityPreference(
        rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "automatic"
    ) ?? .automatic {
        didSet { UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality") }
    }
    @Published var itemsPerRow: Int = LibraryModel.persistedItemsPerRow() {
        didSet {
            let valid = min(10, max(3, itemsPerRow))
            if valid != itemsPerRow { itemsPerRow = valid }
            UserDefaults.standard.set(valid, forKey: "itemsPerRow")
        }
    }
    @Published var cropsThumbnailsToSquare: Bool = UserDefaults.standard.bool(forKey: "cropsThumbnailsToSquare") {
        didSet { UserDefaults.standard.set(cropsThumbnailsToSquare, forKey: "cropsThumbnailsToSquare") }
    }
    @Published var alwaysShowsTimeline: Bool = UserDefaults.standard.bool(forKey: "alwaysShowsTimeline") {
        didSet { UserDefaults.standard.set(alwaysShowsTimeline, forKey: "alwaysShowsTimeline") }
    }
    @Published var budgetFraction: Double = CacheBudget.fraction(for: Int64(UserDefaults.standard.object(forKey: "cacheBudget") as? Int ?? Int(CacheBudget.bytes(at: 0.5)))) {
        didSet {
            let bytes = CacheBudget.bytes(at: budgetFraction)
            UserDefaults.standard.set(Int(bytes), forKey: "cacheBudget")
            if let repository { Task { try? await repository.setBudget(bytes) } }
        }
    }
    @Published private(set) var cacheUsage: Int64 = 0
    @Published private(set) var albums: [AlbumSummary] = []
    @Published private(set) var albumsVerified = false
    @Published private(set) var albumListError: String?
    private(set) var repository: CachedPhotosRepository?
    private var started = false
    private var authenticationTask: Task<Void, Never>?
    private var refreshTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]
    private var albumsTask: Task<Void, Never>?
    private var metadataResetTask: Task<Void, Never>?
    private var mapFilterInvalidationTask: Task<Void, Never>?
    private var albumListRequested = false
    private var openedCollections: Set<PhotoCollectionDescriptor> = []
    private var collectionFetchTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]

    init(repository: CachedPhotosRepository? = nil) {
        self.repository = repository
    }

    var snapshot: TimelineSnapshot? { snapshot(for: .personalLibrary) }
    var snapshotRevision: Int { snapshotRevision(for: .personalLibrary) }
    var timelineVerified: Bool { timelineVerified(for: .personalLibrary) }
    var error: String? { error(for: .personalLibrary) }

    func snapshot(for collection: PhotoCollectionDescriptor) -> TimelineSnapshot? { snapshots[collection] }
    func snapshotRevision(for collection: PhotoCollectionDescriptor) -> Int { snapshotRevisions[collection, default: 0] }
    func viewerSnapshotRevision(for collection: PhotoCollectionDescriptor) -> Int {
        viewerSnapshotRevisions[collection, default: 0]
    }
    func timelineVerified(for collection: PhotoCollectionDescriptor) -> Bool { timelineVerifications[collection] == true }
    func error(for collection: PhotoCollectionDescriptor) -> String? { collectionErrors[collection] }

    func albumName(for collection: PhotoCollectionDescriptor) -> String? {
        guard let albumID = collection.albumID else { return nil }
        return albums.first(where: { $0.id == albumID })?.name
    }

    /// Starts loading the Personal Space album list on first demand.
    func ensureAlbumsLoaded() {
        albumListRequested = true
        startAlbumListFetchIfNeeded()
    }

    private func startAlbumListFetchIfNeeded() {
        guard let repository, albumsTask == nil else { return }
        albumsTask = Task { [weak self] in
            for await event in await repository.albums() {
                guard !Task.isCancelled else { return }
                self?.receiveAlbums(event)
            }
        }
    }

    /// Starts loading an album timeline lazily. Non-album collections are ignored;
    /// Personal Library and Favorites are loaded eagerly by `load()`, and session
    /// collections (map filters) own their snapshots.
    func ensureCollectionLoaded(_ collection: PhotoCollectionDescriptor) {
        guard collection.albumID != nil else { return }
        openedCollections.insert(collection)
        startCollectionFetchIfNeeded(collection)
    }

    /// Resolves every persistent collection that participates in explicit metadata
    /// warming. Album discovery and unopened album timeline scans begin only after
    /// the user presses Start in the warming window.
    func discoverTimelineWarmingTargets() async -> TimelineWarmingTargetDiscovery {
        guard repository != nil else {
            return .init(targets: [], failures: ["The photo repository is unavailable."])
        }

        for collection in PhotoCollectionDescriptor.allCases {
            startCollectionFetchIfNeeded(collection)
        }
        for collection in PhotoCollectionDescriptor.allCases {
            await collectionFetchTasks[collection]?.value
        }

        ensureAlbumsLoaded()
        await albumsTask?.value

        let albumCollections = albums.map { PhotoCollectionDescriptor.album($0.id) }
        for collection in albumCollections {
            guard !Task.isCancelled else { break }
            ensureCollectionLoaded(collection)
            await collectionFetchTasks[collection]?.value
        }

        let persistentCollections = PhotoCollectionDescriptor.allCases + albumCollections
        var targets: [TimelineWarmingTarget] = []
        var failures: [String] = []
        for collection in persistentCollections {
            guard !Task.isCancelled else { break }
            let title: String
            switch collection {
            case .personalLibrary: title = "Personal Library"
            case .favorites: title = "Favorites"
            case .album(let id): title = albumName(for: collection) ?? "Album \(id)"
            case .mapFilter, .libraryFilter: continue
            }
            if timelineVerified(for: collection), let snapshot = snapshot(for: collection) {
                targets.append(.init(collection: collection, snapshot: snapshot,
                                     revision: snapshotRevision(for: collection), title: title))
            } else {
                failures.append("\(title): \(error(for: collection) ?? "timeline could not be loaded")")
            }
        }
        if !albumsVerified {
            failures.append("Albums: \(albumListError ?? "album list could not be loaded")")
        }
        return .init(targets: targets, failures: failures)
    }

    // MARK: - Session Collections

    /// Publishes a session-only collection snapshot (a map filter) without fetching.
    func filterAuthority(for collection: PhotoCollectionDescriptor) -> [[Bool]]? { filterAuthorities[collection] }

    func filterMembership(for collection: PhotoCollectionDescriptor) -> [[Int64]]? { filterMemberships[collection] }

    func registerSessionCollection(_ collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot,
                                   filterMembership: [[Int64]]? = nil, filterAuthority: [[Bool]]? = nil) {
        filterAuthorities[collection] = filterAuthority
        filterMemberships[collection] = filterMembership
        snapshots[collection] = snapshot
        snapshotRevisions[collection, default: 0] += 1
        timelineVerifications[collection] = true
    }

    /// Removes a session-only collection after the repository state is unregistered.
    func unregisterSessionCollection(_ collection: PhotoCollectionDescriptor) {
        snapshots.removeValue(forKey: collection)
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
            registerSessionCollection(registration.descriptor, snapshot: registration.snapshot)
            return registration.descriptor
        } catch {
            collectionErrors[.personalLibrary] = error.localizedDescription
            return nil
        }
    }

    func closeMapFilter(_ collection: PhotoCollectionDescriptor) async {
        if let repository { await repository.unregisterMapFilter(collection) }
        unregisterSessionCollection(collection)
    }

    private func startCollectionFetchIfNeeded(_ collection: PhotoCollectionDescriptor) {
        guard let repository, collectionFetchTasks[collection] == nil else { return }
        collectionFetchTasks[collection] = Task { [weak self] in
            for await event in await repository.timeline(collection: collection) {
                guard !Task.isCancelled else { return }
                self?.receive(event, collection: collection)
            }
        }
    }

    private static func persistedItemsPerRow() -> Int {
        guard let value = (UserDefaults.standard.object(forKey: "itemsPerRow") as? NSNumber)?.intValue else { return 6 }
        return min(10, max(3, value))
    }

    func adjustItemsPerRow(by amount: Int) {
        itemsPerRow = min(10, max(3, itemsPerRow + amount))
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
        updateBrowserFavoriteAvailability()
        if !active { browserCommandOwner = nil }
    }

    func installBrowserCommands(
        owner: UUID,
        active: Bool,
        canOpen: Bool,
        canToggleFavorite: Bool = false,
        collection: PhotoCollectionDescriptor = .personalLibrary,
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

    private func updateBrowserFavoriteAvailability() {
        let available = browserCommandsActive &&
            browserCommandSnapshot.canToggleFavorite &&
            !browserCommandSnapshot.selectedOrdinals.isEmpty &&
            pendingFavoriteConfirmation == nil &&
            !browserFavoriteBusy &&
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
        canToggleViewerFavorite = activeViewer?.canToggleFavorite == true
    }

    func toggleViewerFavorite() {
        guard canToggleViewerFavorite else { return }
        activeViewer?.toggleFavorite()
        updateViewerCommands()
    }

    func downloadSelection(_ selection: BrowserCommandSnapshot, kind: PhotoDownloadKind, choose: Bool) {
        guard let repository, let timeline = snapshots[selection.collection] else { return }
        PhotoDownloadManager.shared.start(repository: repository, snapshot: timeline, selection: selection,
                                          item: nil, kind: kind, choose: choose)
    }

    func downloadViewerItem(_ item: PhotoItem, repository: CachedPhotosRepository,
                            kind: PhotoDownloadKind, choose: Bool) {
        PhotoDownloadManager.shared.start(repository: repository, snapshot: nil, selection: nil,
                                          item: item, kind: kind, choose: choose)
    }

    var canRotate: Bool {
        if let activeViewer { return activeViewer.canRotate }
        return browserCommandsActive && !browserCommandSnapshot.selectedOrdinals.isEmpty &&
            timelineVerified(for: browserCommandSnapshot.collection) && !rotationBusy
    }

    func rotateSelection(_ direction: PhotoRotationDirection) {
        if let activeViewer {
            activeViewer.rotate(direction)
            updateViewerCommands()
            return
        }
        guard canRotate, let repository else { return }
        rotationBusy = true
        rotationFailure = nil
        let snapshot = browserCommandSnapshot
        Task { [weak self] in
            guard let self else { return }
            defer { rotationBusy = false }
            guard let action = await resolveRotation(snapshot, repository: repository) else {
                rotationFailure = "The selected photos could not be verified or do not support rotation."
                return
            }
            do { try await repository.rotate(action, direction: direction) }
            catch { rotationFailure = error.localizedDescription }
        }
    }

    func rotateThumbnailPreviews(_ direction: PhotoRotationDirection) {
        guard thumbnailRotationTask == nil, let repository else { return }
        isFixingThumbnailRotations = false
        let snapshot = browserCommandSnapshot
        thumbnailRotationProgress = .init(completedItems: 0, totalItems: 0, itemID: nil, stage: .preparing)
        thumbnailRotationTask = Task { [weak self] in
            guard let self else { return }
            let action: SelectionRotationAction?
            if let viewer = activeViewer { action = viewer.rotationAction() }
            else { action = await resolveRotation(snapshot, repository: repository) }
            guard let action, !action.itemIDs.isEmpty else {
                thumbnailRotationProgress = .init(completedItems: 0, totalItems: 0, itemID: nil,
                    stage: .finished, failures: ["No selected photos support thumbnail rotation."])
                thumbnailRotationTask = nil
                return
            }
            for await progress in await repository.rotateThumbnails(action, direction: direction) {
                thumbnailRotationProgress = progress
            }
            DecodedImages.shared.clear()
            thumbnailRotationTask = nil
        }
    }

    func fixThumbnailRotations() {
        guard thumbnailRotationTask == nil, let repository else { return }
        isFixingThumbnailRotations = true
        let snapshot = browserCommandSnapshot
        thumbnailRotationProgress = .init(completedItems: 0, totalItems: 0,
                                          itemID: nil, stage: .preparing)
        thumbnailRotationTask = Task { [weak self] in
            guard let self else { return }
            let action: SelectionRotationAction?
            if let viewer = activeViewer { action = viewer.rotationAction() }
            else { action = await resolveRotation(snapshot, repository: repository) }
            guard let action, !action.itemIDs.isEmpty else {
                thumbnailRotationProgress = .init(
                    completedItems: 0, totalItems: 0, itemID: nil, stage: .finished,
                    failures: ["No selected photos support thumbnail rotation repair."]
                )
                thumbnailRotationTask = nil
                return
            }
            for await progress in await repository.fixThumbnailRotations(action) {
                thumbnailRotationProgress = progress
            }
            DecodedImages.shared.clear()
            thumbnailRotationTask = nil
        }
    }

    func cancelThumbnailRotation() {
        thumbnailRotationTask?.cancel()
        thumbnailRotationTask = nil
    }

    func dismissThumbnailRotation() {
        if thumbnailRotationProgress?.stage != .finished { cancelThumbnailRotation() }
        thumbnailRotationProgress = nil
        isFixingThumbnailRotations = false
    }

    func dismissRotationFailure() { rotationFailure = nil }

    private func resolveRotation(_ snapshot: BrowserCommandSnapshot,
                                 repository: CachedPhotosRepository) async -> SelectionRotationAction? {
        guard snapshot.active, let timeline = snapshots[snapshot.collection] else { return nil }
        return await SelectionRotationResolver(repository: repository).resolve(
            collection: snapshot.collection, snapshot: timeline,
            selectedOrdinals: snapshot.selectedOrdinals,
            knownItemIDsByOrdinal: snapshot.knownItemIDsByOrdinal,
            expectedTimelineFingerprint: snapshot.indexFingerprint
        )
    }

    // MARK: - Selection Favorites

    /// Begins a selection favorite operation for the active browser. Routes through
    /// the viewer if it is open; otherwise resolves the full browser selection.
    func toggleSelectionFavorite() {
        if activeViewer != nil {
            toggleViewerFavorite()
            return
        }
        guard canToggleBrowserFavorite, !browserFavoriteBusy,
              let repository else { return }
        browserFavoriteFailure = nil
        let snap = browserCommandSnapshot
        guard snap.active, !snap.selectedOrdinals.isEmpty else { return }
        browserFavoriteBusy = true
        updateBrowserFavoriteAvailability()
        Task { [weak self] in
            await self?.resolveThenMutateFavorites(snapshot: snap, repository: repository)
        }
    }

    private func resolveThenMutateFavorites(snapshot: BrowserCommandSnapshot,
                                             repository: CachedPhotosRepository) async {
        defer {
            browserFavoriteBusy = false
            updateBrowserFavoriteAvailability()
        }
        guard let timelineSnapshot = snapshots[snapshot.collection] else { return }
        let selectedEntireCollection = !snapshot.selectedOrdinals.isEmpty &&
            snapshot.selectedOrdinals.count == LibraryIndex(snapshot: timelineSnapshot).totalCount
        let resolver = SelectionFavoriteResolver(repository: repository)
        guard let action = await resolver.resolve(
            collection: snapshot.collection,
            snapshot: timelineSnapshot,
            selectedOrdinals: snapshot.selectedOrdinals,
            knownItemIDsByOrdinal: snapshot.knownItemIDsByOrdinal,
            expectedTimelineFingerprint: snapshot.indexFingerprint
        ) else {
            browserFavoriteFailure = "The selected photos could not be verified. Try again."
            return
        }

        guard !action.affectedIDs.isEmpty else { return }

        if selectedEntireCollection || action.affectedIDs.count > 5 {
            let confirmation = SelectionFavoriteConfirmation(action: action)
            pendingFavoriteConfirmation = confirmation
            return
        }
        await executeFavoriteAction(action, repository: repository)
    }

    func confirmBrowserFavorite() {
        guard let confirmation = pendingFavoriteConfirmation,
              let repository else {
            pendingFavoriteConfirmation = nil
            return
        }
        let action = confirmation.action
        pendingFavoriteConfirmation = nil
        browserFavoriteBusy = true
        updateBrowserFavoriteAvailability()
        Task { [weak self] in
            defer {
                self?.browserFavoriteBusy = false
                self?.updateBrowserFavoriteAvailability()
            }
            await self?.executeFavoriteAction(action, repository: repository)
        }
    }

    func cancelBrowserFavorite() {
        pendingFavoriteConfirmation = nil
        browserFavoriteBusy = false
        updateBrowserFavoriteAvailability()
    }

    func dismissBrowserFavoriteFailure() {
        browserFavoriteFailure = nil
    }

    private func executeFavoriteAction(_ action: SelectionFavoriteAction,
                                       repository: CachedPhotosRepository) async {
        do {
            try await repository.setFavoritesBatch(action: action)
        } catch {
            browserFavoriteFailure = error.localizedDescription
        }
    }

    // MARK: - Lifecycle

    func load() async {
        guard !started else { return }
        started = true
        isLoading = true
        collectionErrors.removeAll()
        do {
            if repository == nil {
                let credentials = try CredentialStore.load()
                repository = try CachedPhotosRepository(credentials: credentials,
                    budget: CacheBudget.bytes(at: budgetFraction))
            }
            guard let repository else { return }
            try await repository.setConfiguredThumbnailSize(thumbnailSize)
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
            for collection in PhotoCollectionDescriptor.allCases where refreshTasks[collection] == nil {
                refreshTasks[collection] = Task { [weak self] in
                    for await event in await repository.timelineRefreshes(collection: collection) {
                        guard !Task.isCancelled else { return }
                        self?.receive(event, collection: collection,
                                      reason: .favoriteMutationRefresh)
                    }
                }
            }
            if albumListRequested { startAlbumListFetchIfNeeded() }
            for collection in openedCollections {
                startCollectionFetchIfNeeded(collection)
            }
            for collection in PhotoCollectionDescriptor.allCases {
                startCollectionFetchIfNeeded(collection)
            }
            for collection in PhotoCollectionDescriptor.allCases {
                await collectionFetchTasks[collection]?.value
            }
            await refreshUsage()
        } catch {
            collectionErrors[.personalLibrary] = error.localizedDescription
        }
        isLoading = false
    }

    private func receiveAlbums(_ event: ResourceEvent<[AlbumSummary]>) {
        switch event {
        case .value(let list, let verified):
            albums = list
            albumsVerified = verified
            if verified { albumListError = nil }
        case .failure(let message):
            albumListError = message
        }
    }

    private func receive(_ event: ResourceEvent<TimelineSnapshot>, collection: PhotoCollectionDescriptor,
                         reason: TimelineUpdateReason = .authoritativeLoad) {
        switch event {
        case .value(let snapshot, let verified):
            let changed = snapshots[collection]?.sections != snapshot.sections
            if reason == .favoriteMutationRefresh || changed {
                snapshots[collection] = snapshot
                snapshotRevisions[collection, default: 0] += 1
                if changed, reason == .authoritativeLoad {
                    viewerSnapshotRevisions[collection, default: 0] += 1
                }
            }
            timelineVerifications[collection] = verified
            if verified { collectionErrors.removeValue(forKey: collection) }
            updateBrowserFavoriteAvailability()
        case .failure(let message):
            collectionErrors[collection] = message
            updateBrowserFavoriteAvailability()
        }
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        albumsTask?.cancel()
        albumsTask = nil
        albumsVerified = false
        albumListError = nil
        for task in collectionFetchTasks.values { task.cancel() }
        collectionFetchTasks.removeAll()
        if let repository { await repository.retryAuthentication() }
        retryRevision += 1
        started = false
        await load()
    }

    func refreshUsage() async {
        if let repository { cacheUsage = (try? await repository.usage()) ?? 0 }
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
            cacheResetError = error.localizedDescription
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
            cacheResetError = error.localizedDescription
        }
    }

    private func handleMetadataInvalidation(_ revision: UInt64) {
        guard revision > metadataInvalidationRevision else { return }
        albumsTask?.cancel()
        albumsTask = nil
        for task in collectionFetchTasks.values { task.cancel() }
        collectionFetchTasks.removeAll()
        let affected = Set(snapshots.keys).union(PhotoCollectionDescriptor.allCases)
        snapshots.removeAll()
        filterAuthorities.removeAll()
        filterMemberships.removeAll()
        for collection in affected {
            snapshotRevisions[collection, default: 0] += 1
            viewerSnapshotRevisions[collection, default: 0] += 1
        }
        timelineVerifications.removeAll()
        collectionErrors.removeAll()
        albums = []
        albumsVerified = false
        albumListError = nil
        browserSelectionStates.removeAll()
        pendingFavoriteConfirmation = nil
        browserFavoriteFailure = nil
        browserFavoriteBusy = false
        metadataInvalidationRevision = revision
        updateBrowserFavoriteAvailability()

        guard repository != nil else { return }
        for collection in PhotoCollectionDescriptor.allCases {
            startCollectionFetchIfNeeded(collection)
        }
        for collection in openedCollections where collection.albumID != nil {
            startCollectionFetchIfNeeded(collection)
        }
        if albumListRequested { startAlbumListFetchIfNeeded() }
        Task { [weak self] in await self?.refreshUsage() }
    }

    private func handleMapFilterInvalidation(_ collection: PhotoCollectionDescriptor) {
        guard collection.isMapFilter, snapshots[collection] != nil else { return }
        unregisterSessionCollection(collection)
        invalidatedMapFilter = collection
        mapFilterInvalidationRevision &+= 1
        updateBrowserFavoriteAvailability()
    }
}

/// Carries the resolved action while awaiting user confirmation.
struct SelectionFavoriteConfirmation: Identifiable, Sendable {
    var id: String { "\(action.targetFavorite):\(action.affectedIDs.count)" }
    let action: SelectionFavoriteAction

    var title: String {
        let count = action.affectedIDs.count
        let noun = count == 1 ? "Photo" : "Photos"
        if action.targetFavorite {
            return "Add \(count) \(noun) to Favorites?"
        } else {
            return "Remove \(count) \(noun) from Favorites?"
        }
    }

    var actionButtonTitle: String {
        if action.targetFavorite {
            return "Add to Favorites"
        } else {
            return "Remove from Favorites"
        }
    }
}
