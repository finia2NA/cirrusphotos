import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

@MainActor
final class LibraryModel: ObservableObject {
    private enum TimelineUpdateReason: Equatable {
        case authoritativeLoad
        case favoriteMutationRefresh
    }

    @Published private var snapshots: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    @Published private var snapshotRevisions: [PhotoCollectionDescriptor: Int] = [:]
    @Published private var viewerSnapshotRevisions: [PhotoCollectionDescriptor: Int] = [:]
    @Published private var timelineVerifications: [PhotoCollectionDescriptor: Bool] = [:]
    @Published private var collectionErrors: [PhotoCollectionDescriptor: String] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var authenticationStatus: AuthenticationStatus = .notStarted
    @Published private(set) var retryRevision = 0
    @Published private(set) var canToggleViewerFavorite = false
    @Published private(set) var canCloseViewer = false
    @Published private(set) var canOpenSelectedPhoto = false
    @Published private(set) var browserCommandsActive = false
    private var browserSelectionStates: [PhotoCollectionDescriptor: BrowserSelectionState] = [:]
    private var browserCommandHandler: ((BrowserSelectionCommand) -> Void)?
    private var browserCommandOwner: UUID?
    private weak var activeViewer: PhotoViewerPresentation?
    private var viewerCloseHandler: (() -> Void)?
    private var thumbnailPolicyRevision: UInt64 = 0
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
    @Published var itemsPerRow: Int = LibraryModel.persistedItemsPerRow() {
        didSet {
            let valid = min(10, max(3, itemsPerRow))
            if valid != itemsPerRow { itemsPerRow = valid }
            UserDefaults.standard.set(valid, forKey: "itemsPerRow")
        }
    }
    @Published var budgetFraction: Double = CacheBudget.fraction(for: Int64(UserDefaults.standard.object(forKey: "cacheBudget") as? Int ?? Int(CacheBudget.bytes(at: 0.5)))) {
        didSet {
            let bytes = CacheBudget.bytes(at: budgetFraction)
            UserDefaults.standard.set(Int(bytes), forKey: "cacheBudget")
            if let repository { Task { try? await repository.setBudget(bytes) } }
        }
    }
    @Published private(set) var cacheUsage: Int64 = 0
    private(set) var repository: CachedPhotosRepository?
    private var started = false
    private var authenticationTask: Task<Void, Never>?
    private var refreshTasks: [PhotoCollectionDescriptor: Task<Void, Never>] = [:]

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

    func installBrowserCommands(owner: UUID, active: Bool, canOpen: Bool,
                                handler: ((BrowserSelectionCommand) -> Void)?) {
        if active { browserCommandOwner = owner }
        else if browserCommandOwner != nil && browserCommandOwner != owner { return }
        let open = active && canOpen
        if browserCommandsActive != active { browserCommandsActive = active }
        if canOpenSelectedPhoto != open { canOpenSelectedPhoto = open }
        browserCommandHandler = active ? handler : nil
        if !active { browserCommandOwner = nil }
    }

    func performBrowserCommand(_ command: BrowserSelectionCommand) {
        guard browserCommandsActive else { return }
        browserCommandHandler?(command)
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
            await withTaskGroup(of: Void.self) { group in
                for collection in PhotoCollectionDescriptor.allCases {
                    group.addTask { [weak self] in
                        for await event in await repository.timeline(collection: collection) {
                            guard !Task.isCancelled else { return }
                            await self?.receive(event, collection: collection)
                        }
                    }
                }
            }
            await refreshUsage()
        } catch {
            collectionErrors[.personalLibrary] = error.localizedDescription
        }
        isLoading = false
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
        case .failure(let message):
            collectionErrors[collection] = message
        }
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        if let repository { await repository.retryAuthentication() }
        retryRevision += 1
        started = false
        await load()
    }

    func refreshUsage() async {
        if let repository { cacheUsage = (try? await repository.usage()) ?? 0 }
    }

    func clearCache() async {
        if let repository {
            try? await repository.clearCache()
            DecodedImages.shared.clear()
            await refreshUsage()
        }
    }
}
