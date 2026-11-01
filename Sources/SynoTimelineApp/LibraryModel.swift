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

func permitsAlbumDownloads(source: PhotoCollectionDescriptor, incomingVerified: Bool, albums: [AlbumSummary]) -> Bool {
    guard source.incomingAlbumIdentity != nil else { return true }
    return incomingVerified && albums.contains { $0.collection == source && $0.recipientCanDownload }
}

@MainActor
final class LibraryModel: ObservableObject {
    private enum TimelineUpdateReason: Equatable {
        case authoritativeLoad
        case favoriteMutationRefresh
    }

    private var selectionAuthorities: [PhotoCollectionDescriptor: PhotoSelectionAuthority] = [:]
    private var sessionSources: [PhotoCollectionDescriptor: PhotoCollectionDescriptor] = [:]
    @Published var albumOperation: AlbumOperation?
    @Published var albumOperationError: String?
    @Published private(set) var deletingAlbumID: Int64?
    private var albumOperationTask: Task<Void, Never>?
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
    @Published private(set) var albumMembershipRevision: UInt64 = 0
    private(set) var changedAlbumID: Int64?
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
    @Published private(set) var presentationNamespace: String?
    private(set) var repository: CachedPhotosRepository?
    private var started = false
    private var authenticationTask: Task<Void, Never>?
    private var refreshTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]
    private var albumsTask: Task<Void, Never>?
    private var incomingAlbumsTask: Task<Void, Never>?
    private var ownedAlbums: [AlbumSummary] = []
    private var receivedIncomingAlbums: [AlbumSummary] = []
    private var ownedAlbumsVerified = false
    private var incomingAlbumsVerified = false
    private var metadataResetTask: Task<Void, Never>?
    private var albumSharingObservationTask: Task<Void, Never>?
    private var mapFilterInvalidationTask: Task<Void, Never>?
    private var albumListRequested = false
    private var openedCollections: Set<PhotoCollectionDescriptor> = []
    private var collectionFetchTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]

    init(repository: CachedPhotosRepository? = nil) {
        self.repository = repository
        self.presentationNamespace = repository?.namespace
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

    private func startAlbumListFetchIfNeeded() {
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

    /// Starts loading an album timeline lazily. Non-album collections are ignored;
    /// Personal Library and Favorites are loaded eagerly by `load()`, and session
    /// collections (map filters) own their snapshots.
    func ensureCollectionLoaded(_ collection: PhotoCollectionDescriptor) {
        guard collection.usesItemCatalog else { return }
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

        let albumCollections = ownedAlbums.compactMap(\.collection)
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
            case .incomingAlbum, .folder, .person, .subject, .mapFilter, .libraryFilter: continue
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
    func isIncomingCollection(_ collection: PhotoCollectionDescriptor) -> Bool {
        (sessionSources[collection] ?? collection).incomingAlbumIdentity != nil
    }

    func canDownload(in collection: PhotoCollectionDescriptor) -> Bool {
        let source = sessionSources[collection] ?? collection
        return permitsAlbumDownloads(source: source, incomingVerified: incomingAlbumsVerified, albums: receivedIncomingAlbums)
    }

    func sourceAlbumID(for collection: PhotoCollectionDescriptor) -> Int64? {
        (sessionSources[collection] ?? collection).albumID
    }

    func registerSessionCollection(_ collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot,
                                   authority: PhotoSelectionAuthority? = nil, source: PhotoCollectionDescriptor? = nil,
                                   filterMembership: [[Int64]]? = nil, filterAuthority: [[Bool]]? = nil) {
        selectionAuthorities[collection] = authority
        sessionSources[collection] = source
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
            registerSessionCollection(registration.descriptor, snapshot: registration.snapshot, authority: registration.authority)
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

    private func startCollectionFetchIfNeeded(_ collection: PhotoCollectionDescriptor,
                                              reason: TimelineUpdateReason = .authoritativeLoad) {
        guard let repository, collectionFetchTasks[collection] == nil else { return }
        collectionFetchTasks[collection] = Task { [weak self] in
            for await event in await repository.timeline(collection: collection) {
                guard !Task.isCancelled else { return }
                await self?.receive(event, collection: collection, reason: reason)
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
        let available = browserCommandsActive && !isIncomingCollection(browserCommandSnapshot.collection) &&
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
        canToggleViewerFavorite = activeViewer.map { !isIncomingCollection($0.collection) && $0.canToggleFavorite } ?? false
    }

    func toggleViewerFavorite() {
        guard canToggleViewerFavorite else { return }
        activeViewer?.toggleFavorite()
        updateViewerCommands()
    }

    func downloadSelection(_ selection: BrowserCommandSnapshot, kind: PhotoDownloadKind, choose: Bool) {
        guard canDownload(in: selection.collection), let repository, let captured = selection.captureSelection(timeline: selection.timeline) else { return }
        PhotoDownloadManager.shared.start(repository: repository, source: .selection(captured), kind: kind, choose: choose)
    }

    func editSelection(_ selection: BrowserCommandSnapshot, application: URL) {
        guard !isIncomingCollection(selection.collection), let repository, let timeline = selection.timeline else { return }
        PhotoDownloadManager.shared.edit(repository: repository, snapshot: timeline, selection: selection,
                                        item: nil, applicationURL: application)
    }

    func editViewerItem(_ item: PhotoItem, repository: CachedPhotosRepository, application: URL) {
        PhotoDownloadManager.shared.edit(repository: repository, snapshot: nil, selection: nil,
                                        item: item, applicationURL: application)
    }

    func downloadViewerItem(_ item: PhotoItem, repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor,
                            kind: PhotoDownloadKind, choose: Bool) {
        PhotoDownloadManager.shared.start(repository: repository, source: .item(item, collection: collection), kind: kind, choose: choose)
    }

    var canRotate: Bool {
        if let activeViewer { return !isIncomingCollection(activeViewer.collection) && activeViewer.canRotate }
        return browserCommandsActive && !isIncomingCollection(browserCommandSnapshot.collection) && !browserCommandSnapshot.selectedOrdinals.isEmpty &&
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

    var canManageAlbumSelection: Bool {
        browserCommandsActive && !isIncomingCollection(browserCommandSnapshot.collection) && !browserCommandSnapshot.selectedOrdinals.isEmpty &&
        browserCommandSnapshot.timeline != nil && browserCommandSnapshot.authority != nil &&
        albumOperation == nil && !canCloseViewer
    }

    var canRemoveAlbumSelection: Bool {
        canManageAlbumSelection && isNormalAlbum(browserCommandSnapshot.sourceAlbumID)
    }

    func beginAlbumOperation(_ kind: AlbumOperation.Kind) {
        guard canManageAlbumSelection else { return }
        beginAlbumOperation(kind, captured: browserCommandSnapshot)
    }

    func beginEmptyAlbumCreation() {
        guard albumOperation == nil, repository != nil else { return }
        var operation = AlbumOperation(kind: .create, sourceAlbumID: nil)
        operation.createsEmptyAlbum = true
        operation.loading = false
        albumOperation = operation
    }

    func deleteAlbum(_ id: Int64) {
        guard deletingAlbumID == nil, albumOperation == nil, let repository else { return }
        deletingAlbumID = id
        Task { [weak self] in
            do { try await repository.deleteAlbum(id: id) }
            catch { self?.albumOperationError = error.localizedDescription }
            guard let self else { return }
            self.deletingAlbumID = nil
            self.albumsTask?.cancel()
            self.albumsTask = nil
            self.ensureAlbumsLoaded()
        }
    }

    func isNormalAlbum(_ id: Int64?) -> Bool {
        isKnownNormalAlbum(id, in: albums)
    }

    func beginAlbumOperation(_ kind: AlbumOperation.Kind, captured: BrowserCommandSnapshot) {
        guard !isIncomingCollection(captured.collection), albumOperation == nil, let timeline = captured.timeline,
              let fingerprint = captured.indexFingerprint, let authority = captured.authority,
              repository != nil else { return }
        if kind == .remove && !isNormalAlbum(captured.sourceAlbumID) { return }
        let selection = PhotoSelectionSnapshot(collection: captured.collection, timeline: timeline,
            timelineFingerprint: fingerprint, selectedOrdinals: captured.selectedOrdinals,
            knownItemIDsByOrdinal: captured.knownItemIDsByOrdinal, authority: authority)
        beginAlbumOperation(kind, selection: selection, sourceAlbumID: captured.sourceAlbumID)
    }

    func beginAlbumOperation(_ kind: AlbumOperation.Kind, selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?) {
        guard !isIncomingCollection(selection.collection), albumOperation == nil, let repository, selection.authority != nil,
              !selection.selectedOrdinals.isEmpty else { return }
        if kind == .remove && !isNormalAlbum(sourceAlbumID) { return }
        let operation = AlbumOperation(kind: kind, sourceAlbumID: sourceAlbumID)
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection)
            guard !Task.isCancelled, let self, self.albumOperation?.id == operation.id else { return }
            guard let resolved, !resolved.items.isEmpty else {
                self.albumOperation = nil
                self.albumOperationError = "The selected items could not be verified. Try again."
                return
            }
            self.albumOperation?.selection = resolved
            if kind == .add {
                do {
                    let albums = try await repository.addableAlbums()
                    guard !Task.isCancelled, self.albumOperation?.id == operation.id else { return }
                    self.albumOperation?.albums = albums
                } catch {
                    guard !Task.isCancelled else { return }
                    self.albumOperation = nil
                    self.albumOperationError = error.localizedDescription
                }
            }
            self.albumOperation?.loading = false
        }
    }

    /// Adds a captured selection independently of browser focus.
    @discardableResult
    func addCapturedSelection(_ selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?, to albumID: Int64) -> Bool {
        guard !isIncomingCollection(selection.collection), albumOperation == nil, let repository, selection.authority != nil,
              (sessionSources[selection.collection] ?? selection.collection).incomingAlbumIdentity == nil,
              !selection.selectedOrdinals.isEmpty else { return false }
        let operation = AlbumOperation(kind: .add, sourceAlbumID: sourceAlbumID)
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            do {
                let addable = try await repository.addableAlbums()
                guard !Task.isCancelled, addable.contains(where: { $0.id == albumID }) else {
                    throw SynologyAPIError.unsupported("This album is no longer available for adding items.")
                }
                guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
                      !resolved.items.isEmpty, !Task.isCancelled else {
                    throw SynologyAPIError.unsupported("The selected items could not be verified. Try again.")
                }
                guard let self, self.albumOperation?.id == operation.id else { return }
                if sourceAlbumID == albumID {
                    self.albumOperation = nil
                    return
                }
                self.albumOperation?.writing = true
                try await repository.addMissingItems(resolved, toAlbum: albumID)
                guard self.albumOperation?.id == operation.id else { return }
                self.refreshAfterAlbumOperation(operation, destinationID: albumID)
                self.albumOperation = nil
            } catch {
                guard let self, self.albumOperation?.id == operation.id else { return }
                if self.albumOperation?.writing == true { self.refreshAfterAlbumOperation(operation, destinationID: albumID) }
                self.albumOperation = nil
                if !Task.isCancelled { self.albumOperationError = error.localizedDescription }
            }
        }
        return true
    }

    @discardableResult
    func addCapturedSelection(_ selection: PhotoSelectionSnapshot, sourceAlbumID: Int64?, to collection: PhotoCollectionDescriptor) -> Bool {
        if let id = collection.albumID { return addCapturedSelection(selection, sourceAlbumID: sourceAlbumID, to: id) }
        guard collection.incomingAlbumIdentity != nil, albumOperation == nil, let repository,
              (sessionSources[selection.collection] ?? selection.collection).incomingAlbumIdentity == nil,
              selection.authority != nil, !selection.selectedOrdinals.isEmpty else { return false }
        let operation = AlbumOperation(kind: .add, sourceAlbumID: sourceAlbumID)
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            do {
                guard let resolved = await SelectionItemResolver(repository: repository).resolveWithReceipt(selection),
                      !resolved.items.isEmpty, !Task.isCancelled else {
                    throw SynologyAPIError.unsupported("The selected items could not be verified. Try again.")
                }
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.albumOperation?.writing = true
                try await repository.addItems(resolved, toIncomingAlbum: collection)
                guard self.albumOperation?.id == operation.id else { return }
                self.albumOperation = nil
                self.incomingAlbumsTask?.cancel()
                self.incomingAlbumsTask = nil
                self.startAlbumListFetchIfNeeded()
                self.collectionFetchTasks.removeValue(forKey: collection)?.cancel()
                if self.openedCollections.contains(collection) { self.startCollectionFetchIfNeeded(collection) }
            } catch {
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.albumOperation = nil
                if !Task.isCancelled { self.albumOperationError = error.localizedDescription }
            }
        }
        return true
    }

    func cancelAlbumOperation() {
        albumOperationTask?.cancel()
        albumOperationTask = nil
        albumOperation = nil
    }

    func submitAlbumOperation(name: String = "", albumID: Int64? = nil) {
        guard var operation = albumOperation, !operation.loading,
              operation.selection != nil || operation.createsEmptyAlbum,
              let repository else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation.kind == .create && trimmed.isEmpty { return }
        if operation.kind == .add && albumID == nil { return }
        operation.loading = true
        operation.writing = true
        albumOperation = operation
        albumOperationTask = Task { [weak self] in
            do {
                switch operation.kind {
                case .create:
                    if operation.createsEmptyAlbum {
                        _ = try await repository.createEmptyAlbum(name: trimmed)
                    } else if let selection = operation.selection {
                        _ = try await repository.createAlbum(name: trimmed, selection: selection)
                    }
                case .add:
                    guard let albumID, let selection = operation.selection else { return }
                    try await repository.addItems(selection, toAlbum: albumID)
                case .remove:
                    guard let source = operation.sourceAlbumID, let selection = operation.selection else { return }
                    try await repository.removeItems(selection, fromAlbum: source)
                }
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.refreshAfterAlbumOperation(operation, destinationID: albumID)
                self.albumOperation = nil
            } catch {
                guard let self, self.albumOperation?.id == operation.id else { return }
                self.refreshAfterAlbumOperation(operation, destinationID: albumID)
                self.albumOperation = nil
                self.albumOperationError = error.localizedDescription
            }
        }
    }

    private func refreshAfterAlbumOperation(_ operation: AlbumOperation, destinationID: Int64?) {
        albumsTask?.cancel()
        albumsTask = nil
        if albumListRequested { startAlbumListFetchIfNeeded() }
        let id = operation.kind == .remove ? operation.sourceAlbumID : destinationID
        guard let id else { return }
        let collection = PhotoCollectionDescriptor.album(id)
        changedAlbumID = id
        albumMembershipRevision &+= 1
        guard openedCollections.contains(collection) else { return }
        collectionFetchTasks.removeValue(forKey: collection)?.cancel()
        startCollectionFetchIfNeeded(collection, reason: .favoriteMutationRefresh)
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
            presentationNamespace = repository.namespace
            try await repository.setConfiguredThumbnailSize(thumbnailSize)
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
            for collection in PhotoCollectionDescriptor.allCases where refreshTasks[collection] == nil {
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

    private func receiveAlbums(_ event: ResourceEvent<[AlbumSummary]>, incoming: Bool) {
        switch event {
        case .value(let list, let verified):
            // Never expose a provisional replacement under the preceding list’s authority.
            albumsVerified = false
            if incoming { receivedIncomingAlbums = list; incomingAlbumsVerified = verified }
            else { ownedAlbums = list; ownedAlbumsVerified = verified }
            albums = ownedAlbums + receivedIncomingAlbums
            albumsVerified = ownedAlbumsVerified && incomingAlbumsVerified
            if verified {
                albumListError = nil
                if incoming {
                    for collection in openedCollections where collection.incomingAlbumIdentity != nil {
                        collectionFetchTasks.removeValue(forKey: collection)?.cancel()
                        startCollectionFetchIfNeeded(collection)
                    }
                }
            }
        case .failure(let message):
            albumListError = message
        }
    }

    private func receive(_ event: ResourceEvent<TimelineSnapshot>, collection: PhotoCollectionDescriptor,
                         reason: TimelineUpdateReason = .authoritativeLoad) async {
        switch event {
        case .value(let snapshot, let verified):
            let authority = await repository?.selectionAuthority(collection: collection, snapshot: snapshot)
            selectionAuthorities[collection] = authority
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
        incomingAlbumsTask?.cancel()
        incomingAlbumsTask = nil
        ownedAlbums = []
        receivedIncomingAlbums = []
        ownedAlbumsVerified = false
        incomingAlbumsVerified = false
        for task in collectionFetchTasks.values { task.cancel() }
        collectionFetchTasks.removeAll()
        let affected = Set(snapshots.keys).union(PhotoCollectionDescriptor.allCases)
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

struct AlbumOperation: Identifiable {
    enum Kind { case create, add, remove }
    let id = UUID()
    let kind: Kind
    let sourceAlbumID: Int64?
    var selection: ResolvedPhotoSelection?
    var createsEmptyAlbum = false
    var albums: [AlbumSummary] = []
    var loading = true
    var writing = false
}
