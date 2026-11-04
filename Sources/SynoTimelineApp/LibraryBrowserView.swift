import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

enum BrowserSelectionCommand {
    case move(LibrarySelectionDirection, extending: Bool)
    case selectAll
    case openSelected
    case toggleFavorite
    case endExtension
}

/// Immutable snapshot of browser command context published to the shell.
struct BrowserCommandSnapshot: Sendable {
    let owner: UUID
    let active: Bool
    let canOpen: Bool
    let canToggleFavorite: Bool
    let collection: PhotoCollectionDescriptor
    let indexFingerprint: String?
    let selectionGeneration: String?
    let selectedOrdinals: IndexSet
    let knownItemIDsByOrdinal: [Int: Int64]
    var timeline: TimelineSnapshot? = nil
    var authority: PhotoSelectionAuthority? = nil
    var sourceAlbumID: Int64? = nil

    func captureSelection(timeline fallback: TimelineSnapshot?) -> PhotoSelectionSnapshot? {
        guard let timeline = timeline ?? fallback else { return nil }
        return PhotoSelectionSnapshot(collection: collection, timeline: timeline,
            timelineFingerprint: indexFingerprint ?? LibraryIndex(snapshot: timeline).fingerprint,
            selectedOrdinals: selectedOrdinals, knownItemIDsByOrdinal: knownItemIDsByOrdinal, authority: authority)
    }

    static let inactive = BrowserCommandSnapshot(
        owner: UUID(),
        active: false,
        canOpen: false,
        canToggleFavorite: false,
        collection: .library(.personal),
        indexFingerprint: nil,
        selectionGeneration: nil,
        selectedOrdinals: IndexSet(),
        knownItemIDsByOrdinal: [:]
    )
}

struct BrowserSelectionState: Equatable {
    var selection = LibrarySelection()
    var descriptorFingerprint: String?
    var membershipRevision = 0
    var membershipSignatures: [Int: Int] = [:]

    var generation: String? { descriptorFingerprint.map { "\($0):\(membershipRevision)" } }

    mutating func bind(to fingerprint: String) {
        guard descriptorFingerprint != fingerprint else { return }
        descriptorFingerprint = fingerprint
        membershipRevision = 0
        membershipSignatures.removeAll()
        selection.bind(to: "\(fingerprint):0")
    }

    mutating func rebaseFilter(to fingerprint: String, oldMembership: [[Int64]], newMembership: [[Int64]]) {
        let oldIDs = oldMembership.flatMap { $0 }
        let selected = Set(selection.indexes.compactMap { oldIDs.indices.contains($0) ? oldIDs[$0] : nil })
        let newIDs = newMembership.flatMap { $0 }
        if descriptorFingerprint == fingerprint {
            membershipRevision += 1
            if let generation { selection.bind(to: generation) }
        } else {
            bind(to: fingerprint)
        }
        selection.replace(with: IndexSet(newIDs.enumerated().compactMap { selected.contains($0.element) ? $0.offset : nil }))
        membershipSignatures.removeAll()
    }

    @discardableResult
    mutating func reconcileMembership(_ updates: [Int: Int]) -> Bool {
        let changed = updates.contains { section, signature in
            membershipSignatures[section] != nil && membershipSignatures[section] != signature
        }
        if changed {
            membershipRevision += 1
            if let generation { selection.bind(to: generation) }
        }
        for (section, signature) in updates { membershipSignatures[section] = signature }
        return changed
    }
}

struct BrowserMarqueeSelection {
    let baseline: IndexSet
    let toggles: Bool
    private(set) var knownFrames: [Int: CGRect] = [:]

    mutating func update(rectangle: CGRect, loadedFrames: [Int: CGRect]) -> IndexSet {
        for (ordinal, frame) in loadedFrames { knownFrames[ordinal] = frame }
        let hits = IndexSet(knownFrames.compactMap { $0.value.intersects(rectangle) ? $0.key : nil })
        guard toggles else { return hits }
        var result = baseline
        result.formSymmetricDifference(hits)
        return result
    }
}

struct BrowserPendingOpen: Equatable {
    let ordinal: Int
    let generation: String?
    let selectionEpoch: UInt64

    func matches(selection: LibrarySelection, generation: String?, selectionEpoch: UInt64) -> Bool {
        selection.count == 1 && selection.contains(ordinal) && self.generation == generation &&
            self.selectionEpoch == selectionEpoch
    }
}

struct BrowserPointerInteraction {
    private(set) var start: CGPoint?
    private(set) var current: CGPoint?
    private(set) var dragging = false
    var isActive: Bool { start != nil }
    var rectangle: CGRect? {
        guard dragging, let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    mutating func begin(at point: CGPoint) {
        start = point; current = point; dragging = false
    }

    mutating func drag(to point: CGPoint, threshold: CGFloat = 3) -> CGRect? {
        current = point
        if let start, !dragging,
           hypot(point.x - start.x, point.y - start.y) >= threshold { dragging = true }
        return rectangle
    }

    mutating func move(to point: CGPoint) -> CGRect? {
        current = point
        return rectangle
    }

    mutating func finish(at point: CGPoint) -> CGRect? {
        current = point
        return rectangle
    }

    mutating func cancel() {
        start = nil; current = nil; dragging = false
    }
}

@MainActor
final class LibraryBrowserBridge: ObservableObject {
    var revealHandler: ((BrowserRevealRequest, @escaping (CGRect?) -> Void) -> Void)?
    var focusHandler: (() -> Void)?

    /// A reveal may wait for its page's metadata, which can be slow or offline.
    /// Callers such as the viewer close animation fall back after this deadline.
    static let revealDeadline: Duration = .milliseconds(300)

    func reveal(_ request: BrowserRevealRequest, completion: @escaping (CGRect?) -> Void = { _ in }) {
        guard let revealHandler else { completion(nil); return }
        final class CompletionGate {
            var completed = false
            let completion: (CGRect?) -> Void
            init(_ completion: @escaping (CGRect?) -> Void) { self.completion = completion }
            func finish(_ rect: CGRect?) {
                guard !completed else { return }
                completed = true
                completion(rect)
            }
        }
        let gate = CompletionGate(completion)
        revealHandler(request) { gate.finish($0) }
        Task { @MainActor in
            try? await Task.sleep(for: Self.revealDeadline)
            gate.finish(nil)
        }
    }

    func focusTimeline() { focusHandler?() }
}

struct LibraryBrowserView: View {
    let collection: PhotoCollectionDescriptor
    var restorationAnchor: PhotoTimelineRestorationAnchor?
    let bridge: LibraryBrowserBridge
    var pinnedAlbumIDs: [Int64] = []
    var contentTopInset: CGFloat = 0
    var hidesEmptyCollectionState = false
    var customHeader: BrowserHeaderConfiguration?
    var uploadFolderName: String?
    var onOpenPhoto: (PhotoViewerOpenRequest) -> Void = { _ in }
    var onRestorationAnchorChanged: (PhotoTimelineRestorationAnchor) -> Void = { _ in }
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var infoPanel: InfoPanelModel
    @EnvironmentObject private var libraryFilter: LibraryFilterModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSharing = false
    @State private var selectedDay: String?
    @State private var jumpRequest: DayJumpRequest?

    private var selection: Binding<Int> {
        Binding(
            get: { library.snapshot(for: collection)?.timeline.index(keeping: selectedDay) ?? 0 },
            set: { index in
                guard let days = library.snapshot(for: collection)?.timeline.days, days.indices.contains(index) else { return }
                let day = days[index].id
                selectedDay = day
                jumpRequest = DayJumpRequest(dayID: day)
            }
        )
    }

    private var isAlbum: Bool { library.capabilities(for: collection).sourceAlbumID != nil || library.capabilities(for: collection).isIncoming }
    private var upload: PhotoUploadDrop? {
        let destination: PhotoUploadDestination
        switch collection {
        case .library(let space): destination = .timeline(space)
        case .album(let id): destination = .album(id)
        case .folder(let id, let space): destination = .folder(id, space: space)
        default: return nil
        }
        guard let repository = library.repository else { return nil }
        return PhotoUploadDrop(destination: destination, destinationName: uploadFolderName, repository: repository) { [weak library] in await library?.reload() }
    }
    private var browserHeader: BrowserHeaderConfiguration? { customHeader ?? albumHeader }
    private var shouldHideEmptyCollectionState: Bool {
        hidesEmptyCollectionState && !collection.isLibraryFilter &&
            library.timelineVerified(for: collection) && library.error(for: collection) == nil
    }
    private var albumHeader: BrowserHeaderConfiguration? {
        guard isAlbum else { return nil }
        let model = AlbumHeaderModel(album: library.album(for: collection))
        return BrowserHeaderConfiguration(identity: AnyHashable(model), height: AlbumHeaderModel.height) { repository, width in
            AnyView(AlbumHeaderView(model: model, repository: repository, width: width, onManageSharing: { showingSharing = true }))
        }
    }
    private var emptyTitle: String {
        if isAlbum { return library.albumName(for: collection) ?? "Album" }
        return collection.favoriteOnly ? "No favorites" : "No photos"
    }
    private var emptySymbol: String {
        if isAlbum { return "rectangle.stack" }
        return collection.favoriteOnly ? "heart" : "photo"
    }
    private var emptyDescription: String {
        if library.error(for: collection) != nil { return "Cached collection is empty. Connection unavailable." }
        guard library.timelineVerified(for: collection) else { return "Cached collection is empty. Checking Cirrus…" }
        if isAlbum { return "This album is empty." }
        if collection.folderID != nil { return "This folder contains no photos." }
        return collection.favoriteOnly ? "No photos are marked as favorites." : (collection.space == .shared ? "Shared Space is empty." : "Personal Space is empty.")
    }
    private var loadingText: String {
        if isAlbum { return "Opening album…" }
        return collection.favoriteOnly ? "Opening favorites…" : "Opening library…"
    }

    private var emptyState: some View {
        Group {
            if library.snapshot(for: collection) == nil {
                if let error = library.error(for: collection) {
                    ContentUnavailableView {
                        Label("Album unavailable", systemImage: "photo.badge.exclamationmark")
                    } description: { Text(error) }
                    actions: {
                        Button("Try Again") { Task { await library.reload() } }.disabled(library.isLoading)
                    }
                } else { ProgressView(loadingText) }
            } else {
                ContentUnavailableView {
                    Label(collection.isLibraryFilter ? (libraryFilter.progress.remaining == 0 ? "No matches in library" : "No matches in loaded sections") : emptyTitle,
                          systemImage: emptySymbol)
                } description: { Text(collection.isLibraryFilter ? libraryFilter.coverageText : emptyDescription) }
                actions: {
                    if collection.isLibraryFilter && libraryFilter.progress.hasInitialUnverifiedSection {
                        Button("Load More Results") { libraryFilter.loadInitialBatch() }
                    }
                }
            }
        }
    }

    var body: some View {
        let _ = ModelChangeSignposts.body("Library browser body")
        Group {
            if let repository = library.repository,
               (browserHeader != nil || !(library.snapshot(for: collection)?.timeline.days.isEmpty ?? true)) {
                let snapshot = library.snapshot(for: collection) ?? TimelineSnapshot(sections: [])
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        LibraryBrowserScrollView(snapshot: snapshot,
                                             header: browserHeader,
                                             emptyContent: snapshot.timeline.days.isEmpty && !shouldHideEmptyCollectionState ? AnyView(emptyState) : nil,
                                             authority: library.selectionAuthority(for: collection),
                                             sourceAlbumID: library.capabilities(for: collection).sourceAlbumID,
                                             allowsPersonalActions: library.capabilities(for: collection).allowsPersonalActions,
                                             allowsDownloads: library.capabilities(for: collection).allowsDownloads,
                                             allowsFileDrag: library.capabilities(for: collection).allowsSpaceItemActions,
                                             filterMembership: library.filterMembership(for: collection),
                                             filterAuthority: library.filterAuthority(for: collection),
                                             collection: collection,
                                             upload: upload,
                                             revision: library.snapshotRevision(for: collection),
                                             retryRevision: library.retryRevision,
                                             repository: repository, allowNetwork: library.timelineVerified(for: collection),
                                             thumbnailSize: preferences.thumbnailSize,
                                             itemsPerRow: preferences.itemsPerRow,
                                             cropsThumbnailsToSquare: preferences.cropsThumbnailsToSquare,
                                             selectionState: library.selectionState(for: collection),
                                             restorationAnchor: restorationAnchor,
                                             bridge: bridge,
                                             jumpToDay: jumpRequest,
                                             unavailableOffline: library.error(for: collection) != nil || library.authenticationFailed,
                                             colorScheme: colorScheme,
                                             reduceMotion: reduceMotion,
                                             contentTopInset: contentTopInset,
                                             onOpenPhoto: onOpenPhoto,
                                             onAlbumMenu: { menu, selection in
                                                 library.addAlbumMembershipMenu(to: menu, captured: selection, pinnedIDs: pinnedAlbumIDs)
                                             },
                                             onDownload: { selection, kind, choose in
                                                 library.downloadSelection(selection, kind: kind, choose: choose)
                                             },
                                             onDelete: { selection in
                                                 library.beginItemDeletion(captured: selection)
                                             },
                                             onEdit: { selection, application in
                                                 library.editSelection(selection, application: application)
                                             },
                                             onSelectionStateChanged: { state in
                                                 library.setSelectionState(state, for: collection)
                                                 infoPanel.updateBrowserContext(
                                                     repository: library.repository,
                                                     snapshot: library.snapshot(for: collection),
                                                     collection: collection,
                                                     selection: state.selection.indexes)
                                             },
                                             onCommandStateChanged: { snapshot, handler in
                                                 library.installBrowserCommands(snapshot: snapshot, handler: handler)
                                             },
                                             onRestorationAnchorChanged: onRestorationAnchorChanged,
                                             onFilterEdgeDemand: { sections, direction, generation in
                                                 guard collection.isLibraryFilter else { return }
                                                 libraryFilter.edgeDemand(syntheticSectionIndices: sections,
                                                                          direction: direction,
                                                                          userScrollGeneration: generation)
                                             },
                                             onRetry: { Task { await library.reload() } }) { day in
                        if snapshot.timeline.days.contains(where: { $0.id == day }) { selectedDay = day }
                    }
                        if !snapshot.timeline.days.isEmpty {
                            TimelineNavigator(timeline: snapshot.timeline, selected: selection,
                                              alwaysVisible: preferences.alwaysShowsTimeline)
                                .frame(width: 72)
                                .padding(.top, contentTopInset + 16)
                                .padding(.bottom, 16)
                                .padding(.trailing, 6)
                        }
                    }
                }
            } else if library.snapshot(for: collection)?.timeline.days.isEmpty == true {
                if shouldHideEmptyCollectionState {
                    Color.clear
                } else {
                    emptyState
                }
            } else if let error = library.error(for: collection), library.snapshot(for: collection) == nil {
                ContentUnavailableView {
                    Label(isAlbum ? "Album unavailable" : "Library unavailable",
                          systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await library.reload() } }.disabled(library.isLoading)
                }
            } else {
                ProgressView(loadingText)
            }
        }
        .sheet(isPresented: $showingSharing) {
            if let albumID = library.capabilities(for: collection).sourceAlbumID, let repository = library.repository {
                AlbumSharingSheet(albumID: albumID, repository: repository)
            }
        }
        .background(FileUploadTarget(upload: upload))
        .onDisappear { PhotoUploadManager.shared.cancelThumbnailPolling() }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: library.snapshotRevision(for: collection)) { _, _ in
            guard let timeline = library.snapshot(for: collection)?.timeline,
                  let index = timeline.index(keeping: selectedDay) else { selectedDay = nil; return }
            selectedDay = timeline.days[index].id
        }
    }
}

struct BrowserHeaderConfiguration {
    let identity: AnyHashable
    let height: (CGFloat) -> CGFloat
    let content: (CachedPhotosRepository, CGFloat) -> AnyView
}

struct LibraryBrowserScrollView: NSViewRepresentable {
    let snapshot: TimelineSnapshot
    let header: BrowserHeaderConfiguration?
    let emptyContent: AnyView?
    let authority: PhotoSelectionAuthority?
    let sourceAlbumID: Int64?
    let allowsPersonalActions: Bool
    let allowsDownloads: Bool
    let allowsFileDrag: Bool
    let filterMembership: [[Int64]]?
    let filterAuthority: [[Bool]]?
    let collection: PhotoCollectionDescriptor
    let upload: PhotoUploadDrop?
    let revision: Int
    let retryRevision: Int
    let repository: CachedPhotosRepository
    let allowNetwork: Bool
    let thumbnailSize: ThumbnailSize
    let itemsPerRow: Int
    let cropsThumbnailsToSquare: Bool
    let selectionState: BrowserSelectionState
    let restorationAnchor: PhotoTimelineRestorationAnchor?
    let bridge: LibraryBrowserBridge
    let jumpToDay: DayJumpRequest?
    let unavailableOffline: Bool
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let contentTopInset: CGFloat
    let onOpenPhoto: (PhotoViewerOpenRequest) -> Void
    let onAlbumMenu: (NSMenu, BrowserCommandSnapshot) -> Void
    let onDownload: (BrowserCommandSnapshot, PhotoDownloadKind, Bool) -> Void
    let onDelete: (BrowserCommandSnapshot) -> Void
    let onEdit: (BrowserCommandSnapshot, URL) -> Void
    let onSelectionStateChanged: (BrowserSelectionState) -> Void
    let onCommandStateChanged: (BrowserCommandSnapshot, ((BrowserSelectionCommand) -> Void)?) -> Void
    let onRestorationAnchorChanged: (PhotoTimelineRestorationAnchor) -> Void
    let onFilterEdgeDemand: ([Int], LibraryFilterScanDirection, UInt64) -> Void
    let onRetry: () -> Void
    let onVisibleDay: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineScrollView()
        scroll.upload = upload
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let document = FlippedDocumentView()
        let overlay = SelectionOverlayView()
        document.overlay = overlay
        document.addSubview(overlay)
        scroll.documentView = document
        scroll.keyboardResponder = document
        document.timelineScrollView = scroll
        context.coordinator.scroll = scroll
        context.coordinator.document = document
        document.fileDragHitTest = { [weak coordinator = context.coordinator] point in
            coordinator?.isFileDragOrigin(at: point) ?? false
        }
        document.cancelFileDrag = { [weak coordinator = context.coordinator] in
            coordinator?.cancelFileDragGesture()
        }
        document.fileDragHandler = { [weak coordinator = context.coordinator] point, event in
            coordinator?.beginFileDrag(at: point, event: event) ?? false
        }
        document.contextMenuHandler = { [weak coordinator = context.coordinator] point in
            coordinator?.contextMenu(at: point)
        }
        document.commandHandler = { [weak coordinator = context.coordinator] command in
            coordinator?.perform(command)
        }
        scroll.focusChanged = { [weak coordinator = context.coordinator] active in
            coordinator?.publishCommandState(active: active)
        }
        document.interaction = { [weak coordinator = context.coordinator] phase in
            coordinator?.interact(phase)
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.viewportChanged() }
        }
        context.coordinator.configure(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let scroll = nsView as? TimelineScrollView { scroll.upload = upload }
        context.coordinator.configure(self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

}
