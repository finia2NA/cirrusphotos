import PhotoCache
import SwiftUI
import SynologyAPI

struct AppShellView: View {
    @Environment(LibraryModel.self) private var model
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var infoPanel: InfoPanelModel
    @EnvironmentObject private var libraryFilter: LibraryFilterModel
    @EnvironmentObject private var timelineSectionLoad: TimelineSectionLoadModel
    /// Not observed: the shell only drives sync and must not re-render on its progress.
    @Environment(\.metadataSyncModel) private var metadataSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var albumPresentation: AlbumPresentationStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewer: PhotoViewerPresentation?
    @State private var indexEntries: [CollectionIndexKind: [CollectionIndexEntry]] = [:]
    @State private var indexErrors: [CollectionIndexKind: String] = [:]
    @State private var personEdit: PersonEditRequest?
    @State private var peopleEditRevision: UInt64 = 0
    @State private var folderDirectory: FolderDirectory?
    @State private var folderDirectoryRequest: Int64?
    @State private var folderError: String?
    @State private var dragOverviewNonce: String?
    @State private var openedMapFilter: PhotoCollectionDescriptor?
    @State private var mapFilterOpenGeneration: UInt64 = 0
    @State private var chrome = WindowChromeMetrics()
    @State private var lastViewerFollowSelection: PhotoViewerSelection?
    @StateObject private var browserBridge = LibraryBrowserBridge()
    @StateObject private var mapModel = MapBrowserModel()

    init(navigation: NavigationModel, albumPresentation: AlbumPresentationStore) {
        self.navigation = navigation
        self.albumPresentation = albumPresentation
    }

    // Navigation state lives in `NavigationModel`; these forward to it and persist on write.
    private var sidebarSelection: SidebarSelection {
        get { navigation.sidebarSelection } nonmutating set { navigation.sidebarSelection = newValue }
    }
    private var selectedDestination: LibraryDestination { navigation.selectedDestination }
    private var openedAlbum: PhotoCollectionDescriptor? {
        get { navigation.openedAlbum } nonmutating set { navigation.openedAlbum = newValue }
    }
    private var selectedSpace: PhotoSpace {
        get { navigation.selectedSpace } nonmutating set { navigation.selectedSpace = newValue }
    }
    private var showsFolders: Bool {
        get { navigation.showsFolders } nonmutating set { navigation.showsFolders = newValue }
    }
    private var folderPath: [Int64] {
        get { navigation.folderPath } nonmutating set { navigation.folderPath = newValue }
    }
    private var openedIndexEntryIDs: [CollectionIndexKind: Int64] {
        get { navigation.openedIndexEntries } nonmutating set { navigation.openedIndexEntries = newValue }
    }

    /// The collection currently browsed in the detail area, or nil for the Albums
    /// overview and the unfiltered map.
    private var sourceCollection: PhotoCollectionDescriptor? {
        let collection: PhotoCollectionDescriptor? = switch selectedDestination {
        case .personalLibrary:
            if showsFolders { folderDirectoryRequest == (folderPath.last ?? 0) ? folderDirectory.map { .folder($0.folder.id, space: selectedSpace) } : nil }
            else { .library(selectedSpace) }
        case .favorites: .favorites(selectedSpace)
        case .recentlyAdded: .recentlyAdded
        case .people, .subjects, .tags:
            selectedDestination.indexKind.flatMap { kind in openedIndexEntryIDs[kind].map { kind.collection($0, space: selectedSpace) } }
        case .albums: openedAlbum
        case .map: openedMapFilter
        }
        if selectedSpace == .shared && selectedDestination == .recentlyAdded { return nil }
        return collection
    }

    private var selectedCollection: PhotoCollectionDescriptor? {
        libraryFilter.activeCollection(for: sourceCollection) ?? sourceCollection
    }

    /// Activity rows reveal photos of the collection the browser shows, not under a viewer.
    private var activityRevealCollection: PhotoCollectionDescriptor? {
        viewer == nil ? selectedCollection : nil
    }

    private var sourceSnapshotRevision: Int {
        sourceCollection.map { model.snapshotRevision(for: $0) } ?? 0
    }

    private var sourceTimelineVerified: Bool {
        sourceCollection.map { model.timelineVerified(for: $0) } ?? false
    }

    private var isAlbumBrowser: Bool {
        selectedDestination == .albums && openedAlbum != nil
    }

    private var isMapFilterBrowser: Bool {
        sourceCollection?.isMapFilter == true
    }

    private var mapFilterCount: Int {
        guard isMapFilterBrowser, let collection = sourceCollection else { return 0 }
        return model.snapshot(for: collection)?.sections.reduce(0) { $0 + $1.limit } ?? 0
    }

    private var timelineVerified: Bool {
        selectedCollection.map { model.timelineVerified(for: $0) } ?? false
    }

    private var viewerSnapshotRevision: Int {
        selectedCollection.map { model.viewerSnapshotRevision(for: $0) } ?? 0
    }

    private var snapshotRevision: Int {
        selectedCollection.map { model.snapshotRevision(for: $0) } ?? 0
    }

    var body: some View {
        let _ = ModelChangeSignposts.body("App shell body")
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { sidebarSelection }, set: select)) {
                Label("Library", systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarSelection.destination(.personalLibrary))
                Section("Collections") {
                    Label("Recently Added", systemImage: "clock")
                        .tag(SidebarSelection.destination(.recentlyAdded))
                    Label("Favorites", systemImage: "heart")
                        .tag(SidebarSelection.destination(.favorites))
                    Label("People", systemImage: "person.2")
                        .tag(SidebarSelection.destination(.people))
                    Label("Subjects", systemImage: "square.grid.2x2")
                        .tag(SidebarSelection.destination(.subjects))
                    Label("Tags", systemImage: "tag")
                        .tag(SidebarSelection.destination(.tags))
                    Label("Map", systemImage: "map")
                        .tag(SidebarSelection.destination(.map))
                }
                AlbumSidebarSection(presentation: albumPresentation, albums: model.albums,
                                    repository: model.repository, showOverviewForDrag: showAlbumsOverviewForDrag)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            detail
        }
        .background(DownloadCloseGuard(session: model.session).frame(width: 0, height: 0))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar(id: "main") { applicationToolbar.customizationBehavior(.disabled) }
        .onExitCommand {
            model.navigateBack()
        }
        .onAppear {
            model.activity.revealHandler = { [browserBridge] item, _ in
                browserBridge.reveal(BrowserRevealRequest(itemID: item.id, dayID: item.utcDayID,
                                                          sectionOffsetHint: nil, selectOnCompletion: true))
            }
            configureAlbumPresentation()
            updateBackHandler()
            libraryFilter.configure(library: model, source: sourceCollection)
            timelineSectionLoad.configure(library: model, filter: libraryFilter)
            metadataSync?.configure(library: model)
            metadataSync?.setFocus(sourceCollection)
            updateTimelineSectionLoadSource()
        }
        .onChange(of: activityRevealCollection, initial: true) { _, collection in
            model.activity.revealableCollection = collection
        }
        .onChange(of: selectedDestination) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: selectedSpace) { _, space in
            libraryFilter.clear()
            mapFilterOpenGeneration &+= 1
            if let previous = openedMapFilter {
                openedMapFilter = nil
                Task { await model.closeMapFilter(previous) }
            }
            if selectedDestination == .map { mapModel.start(repository: model.repository, space: space) }
            else { mapModel.stopObservingProjection(); mapModel.invalidateMetadata(restart: false) }
            indexEntries = [:]; folderDirectory = nil; folderDirectoryRequest = nil
            if let collection = sourceCollection { model.ensureCollectionLoaded(collection) }
            if space == .shared { model.ensureCollectionLoaded(.library(.shared)) }
            updateBackHandler(); updateTimelineSectionLoadSource(); updateInfoPanelContext()
        }
        .onChange(of: showsFolders) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .onChange(of: folderPath) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .task(id: IndexLoadKey(namespace: model.presentationNamespace.map { $0 + ":" + selectedSpace.rawValue }, kind: selectedDestination.indexKind, resetRevision: model.metadataInvalidationRevision, retryRevision: model.retryRevision, editRevision: peopleEditRevision)) { await loadIndex() }
        .onChange(of: openedIndexEntryIDs) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .task(id: FolderLoadKey(namespace: model.presentationNamespace.map { $0 + ":" + selectedSpace.rawValue }, active: selectedDestination == .personalLibrary && showsFolders, id: folderPath.last ?? 0, resetRevision: model.metadataInvalidationRevision, retryRevision: model.retryRevision)) { await loadFolder() }
        .onChange(of: openedAlbum) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: openedMapFilter) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: sourceCollection) { _, _ in
            if let collection = sourceCollection { model.ensureCollectionLoaded(collection) }
            libraryFilter.configure(library: model, source: sourceCollection)
            metadataSync?.setFocus(sourceCollection)
            updateTimelineSectionLoadSource()
        }
        .onChange(of: sourceSnapshotRevision) { _, _ in
            libraryFilter.configure(library: model, source: sourceCollection)
        }
        .onChange(of: sourceTimelineVerified) { _, _ in
            libraryFilter.configure(library: model, source: sourceCollection)
        }
        .onChange(of: selectedCollection) { _, _ in updateTimelineSectionLoadSource() }
        .onDisappear {
            dismissWindow(id: InfoPanelScene.id)
        }
        .task {
            if let collection = sourceCollection { model.ensureCollectionLoaded(collection) }
            if selectedSpace == .shared { model.ensureCollectionLoaded(.library(.shared)) }
            if selectedSpace == .personal && selectedDestination == .recentlyAdded { model.ensureCollectionLoaded(.recentlyAdded) }
            guard selectedDestination == .albums || !albumPresentation.pinnedCollections.isEmpty else { return }
            model.ensureAlbumsLoaded()
            if let collection = openedAlbum { model.ensureCollectionLoaded(collection) }
        }
        .onChange(of: timelineVerified) { _, verified in
            viewer?.updateAllowNetwork(verified)
            updateTimelineSectionLoadSource()
        }
        .onChange(of: model.retryRevision) { _, _ in
            viewer?.retry()
        }
        .onChange(of: model.metadataInvalidationRevision) { _, revision in
            guard revision > 0 else { return }
            libraryFilter.clear()
            mapFilterOpenGeneration &+= 1
            openedMapFilter = nil
            viewer?.invalidateForNewIndex()
            mapModel.invalidateMetadata(restart: selectedDestination == .map)
            infoPanel.clearBrowserContext()
            updateInfoPanelContext()
        }
        .onChange(of: model.albumMembershipRevision) { _, _ in
            guard sourceCollection?.albumID == model.changedAlbumID else { return }
            libraryFilter.clear()
            viewer?.invalidateForNewIndex()
        }
        .onChange(of: model.mapFilterInvalidationRevision) { _, _ in
            guard model.invalidatedMapFilter == openedMapFilter else { return }
            mapFilterOpenGeneration &+= 1
            openedMapFilter = nil
            viewer?.invalidateForNewIndex()
            infoPanel.clearBrowserContext()
            updateInfoPanelContext()
        }
        .onChange(of: viewerSnapshotRevision) { _, revision in
            if let viewer, viewer.snapshotRevision != revision { viewer.invalidateForNewIndex() }
        }
        .onChange(of: snapshotRevision) { _, _ in
            updateInfoPanelContext()
            updateTimelineSectionLoadSource()
        }
        .onChange(of: model.presentationNamespace) { _, _ in
            indexEntries = [:]
            configureAlbumPresentation()
        }
        .onChange(of: albumPresentation.pinnedCollections) { _, _ in
            if !albumPresentation.pinnedCollections.isEmpty { model.ensureAlbumsLoaded() }
            synchronizeAlbumSelection()
        }
        .onChange(of: model.albums) { _, albums in
            validateOpenedAlbum(in: albums)
        }
        .onChange(of: model.albumsVerified) { _, _ in
            validateOpenedAlbum(in: model.albums)
        }
        .alert(
            model.pendingFavoriteConfirmation?.title ?? "",
            isPresented: Binding(
                get: { model.pendingFavoriteConfirmation != nil },
                set: { if !$0 { model.cancelBrowserFavorite() } }
            ),
            presenting: model.pendingFavoriteConfirmation
        ) { confirmation in
            Button(confirmation.actionButtonTitle) {
                model.confirmBrowserFavorite()
            }
            Button("Cancel", role: .cancel) {
                model.cancelBrowserFavorite()
            }
        }
        .sheet(item: $personEdit) { request in
            PersonEditView(request: request, people: indexEntries[.person] ?? [], repository: model.repository,
                           activity: model.activity) {
                peopleEditRevision &+= 1
            }
        }
        .sheet(item: Bindable(model).albumOperation) { operation in
            AlbumOperationView(model: model, operation: operation)
        }
        .sheet(item: Bindable(model).itemDeletion) { deletion in
            ItemDeletionView(model: model, deletion: deletion)
        }
        .sheet(isPresented: Binding(
            get: { model.thumbnailRotationProgress != nil },
            set: { if !$0 { model.dismissThumbnailRotation() } }
        )) {
            ThumbnailRotationProgressView(model: model)
        }
    }

    private func updateTimelineSectionLoadSource() {
        timelineSectionLoad.configure(library: model, filter: libraryFilter)
        timelineSectionLoad.refreshAvailability()
    }

    private var detail: some View {
        GeometryReader { geometry in
            let topInset = max(chrome.top, geometry.safeAreaInsets.top)
            ZStack(alignment: .topLeading) {
                if selectedSpace == .shared && selectedDestination == .recentlyAdded {
                    ContentUnavailableView("Unavailable in Shared Space", systemImage: "photo.on.rectangle")
                        .detailPlaceholder(topInset: topInset)
                } else if selectedDestination == .personalLibrary && showsFolders {
                    folderDetail(topInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if let collection = selectedCollection {
                    LibraryBrowserView(collection: collection,
                                       restorationAnchor: collection.isSessionDerived
                                           ? nil : navigation.timelineAnchor(for: collection),
                                       bridge: browserBridge,
                                       pinnedAlbumIDs: albumPresentation.pinnedIDs,
                                       contentTopInset: topInset,
                                       onOpenPhoto: openPhoto,
                                       onRestorationAnchorChanged: { anchor in
                                           guard !collection.isSessionDerived else { return }
                                           navigation.setTimelineAnchor(anchor, for: collection)
                                       })
                        .id(collection)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if let kind = selectedDestination.indexKind {
                    indexDetail(kind, topInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if selectedDestination == .map {
                    MapBrowserView(model: mapModel, contentTopInset: topInset, space: selectedSpace,
                                   onOpenPhoto: { openMapGroup([$0]) },
                                   onOpenGroup: openMapGroup)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else {
                    AlbumsOverviewView(onOpenAlbum: openAlbum, presentation: albumPresentation, contentTopInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                }

                if dragOverviewNonce != nil {
                    AlbumsOverviewView(onOpenAlbum: { _ in }, presentation: albumPresentation, contentTopInset: topInset)
                        .ignoresSafeArea(.container, edges: .top)
                }

                if let viewer {
                    PhotoViewerView(viewer: viewer,
                                    pinnedAlbumIDs: albumPresentation.pinnedIDs,
                                    toolbarInset: topInset,
                                    reduceMotion: reduceMotion,
                                    pixelInterpolation: preferences.pixelInterpolation,
                                    videoMuted: preferences.videoMuted,
                                    showsFilmstrip: model.showsFilmstrip,
                                    cropsThumbnailsToSquare: preferences.cropsThumbnailsToSquare,
                                    showsHistogram: model.showsHistogram,
                                    showsHighlightPeaking: model.showsHighlightPeaking,
                                    showsFocusEdges: model.showsFocusEdges,
                                    onVideoMuteChanged: { preferences.videoMuted = $0 },
                                    onSelectionChanged: followViewer,
                                    onClose: closeViewer,
                                    onInteractiveDismiss: closeViewer)
                        .ignoresSafeArea(.container, edges: .top)
                }

                Rectangle()
                    .fill(.regularMaterial)
                    .frame(maxWidth: .infinity)
                    .frame(height: topInset)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)

                WindowChromeMetricsReader { chrome = $0 }
                    .allowsHitTesting(false)
            }
        }
    }

    private struct IndexLoadKey: Hashable {
        let namespace: String?
        let kind: CollectionIndexKind?
        let resetRevision: UInt64
        let retryRevision: Int
        let editRevision: UInt64
    }

    private func loadIndex() async {
        guard let kind = selectedDestination.indexKind, let repository = model.repository else { return }
        let restored = navigation.prepareIndexEntry(kind, namespace: repository.namespace)
        openedIndexEntryIDs[kind] = restored
        if let restored { model.ensureCollectionLoaded(kind.collection(restored, space: selectedSpace)) }
        indexErrors[kind] = nil
        for await event in await repository.collectionIndex(kind, space: selectedSpace) {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let list, let verified):
                indexEntries[kind] = list
                if verified, let id = openedIndexEntryIDs[kind], !list.contains(where: { $0.id == id }) {
                    openedIndexEntryIDs[kind] = nil
                }
            case .failure(let error): indexErrors[kind] = error.localizedDescription
            }
        }
    }

    private func openIndexEntry(_ entry: CollectionIndexEntry, kind: CollectionIndexKind) {
        openedIndexEntryIDs[kind] = entry.id
        model.ensureCollectionLoaded(kind.collection(entry.id, space: selectedSpace))
        updateBackHandler(); updateInfoPanelContext()
    }

    private func closeIndexEntry() {
        guard let kind = selectedDestination.indexKind else { return }
        openedIndexEntryIDs[kind] = nil
        updateBackHandler(); updateInfoPanelContext()
    }

    /// The opened person, subject or tag of the current destination.
    private var openedIndexEntryID: Int64? {
        selectedDestination.indexKind.flatMap { openedIndexEntryIDs[$0] }
    }

    @ViewBuilder private func indexDetail(_ kind: CollectionIndexKind, topInset: CGFloat) -> some View {
        let style = IndexOverviewStyle(kind)
        if let entries = indexEntries[kind], entries.isEmpty {
            ContentUnavailableView {
                Label("No \(style.title)", systemImage: style.symbol)
            } description: {
                if let error = indexErrors[kind] { Text(error).textSelection(.enabled) }
            }
            .detailPlaceholder(topInset: topInset)
        } else if let entries = indexEntries[kind] {
            ScrollView {
                if let error = indexErrors[kind] { Text(error).font(.caption).foregroundStyle(.secondary) }
                VStack {
                    LazyVGrid(columns: CardGrid.columns(preferences.itemsPerRow), alignment: .leading, spacing: CardGrid.spacing) {
                        ForEach(entries) { entry in
                            Button { openIndexEntry(entry, kind: kind) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumCoverView(thumbnail: entry.thumbnail, repository: model.repository, collection: PhotoCollectionDescriptor.library(selectedSpace), placeholderSymbol: style.coverSymbol)
                                    Text(entry.name.isEmpty ? "Unnamed" : entry.name).font(.headline).lineLimit(1)
                                    Text("\(entry.itemCount) items").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            .contextMenu {
                                if kind == .person {
                                    Button("Rename…") { personEdit = PersonEditRequest(person: entry, space: selectedSpace) }
                                }
                            }
                        }
                    }
                }
            }.contentMargins(.top, topInset + 24).contentMargins(.horizontal, 24)
        } else if let error = indexErrors[kind] {
            ContentUnavailableView { Label("\(style.title) unavailable", systemImage: style.symbol) } description: { Text(error).textSelection(.enabled) } actions: { Button("Try Again") { Task { await model.reload() } } }
                .detailPlaceholder(topInset: topInset)
        } else {
            ProgressView("Loading \(style.title.lowercased())…")
                .detailPlaceholder(topInset: topInset)
        }
    }

    private struct FolderLoadKey: Hashable {
        let namespace: String?
        let active: Bool
        let id: Int64
        let resetRevision: UInt64
        let retryRevision: Int
    }

    private func loadFolder() async {
        guard selectedDestination == .personalLibrary, showsFolders, let repository = model.repository else { return }
        let restoredPath = navigation.prepareFolders(namespace: repository.namespace)
        if restoredPath != folderPath { folderPath = restoredPath; return }
        let id = folderPath.last ?? 0
        folderDirectory = nil; folderDirectoryRequest = id; folderError = nil
        let started = ContinuousClock.now
        for await event in await repository.folderDirectory(id: id, space: selectedSpace) {
            guard !Task.isCancelled, id == (folderPath.last ?? 0) else { return }
            switch event {
            case .value(let directory, let verified):
                SynologyDiagnostics.folders.info("directory folder=\(id, privacy: .public) children=\(directory.children.count, privacy: .public) verified=\(verified, privacy: .public) elapsed=\(String(describing: ContinuousClock.now - started), privacy: .public)")
                folderDirectory = directory
                model.ensureCollectionLoaded(PhotoCollectionDescriptor.folder(directory.folder.id, space: selectedSpace))
            case .failure(let message): folderError = message.localizedDescription
            }
        }
    }

    private func folderBack() {
        guard !folderPath.isEmpty else { return }
        folderPath.removeLast()
    }

    @ViewBuilder private func folderDetail(topInset: CGFloat) -> some View {
        if let directory = folderDirectory, folderDirectoryRequest == (folderPath.last ?? 0), let collection = selectedCollection {
            VStack(spacing: 0) {
                if let folderError { Text(folderError).font(.caption).foregroundStyle(.secondary).padding(6) }
                LibraryBrowserView(collection: collection,
                    restorationAnchor: collection.isSessionDerived ? nil : navigation.timelineAnchor(for: collection),
                    bridge: browserBridge, pinnedAlbumIDs: albumPresentation.pinnedIDs, contentTopInset: topInset,
                    hidesEmptyCollectionState: !directory.children.isEmpty,
                    customHeader: folderHeader(directory.children),
                    uploadFolderName: directory.folder.displayName,
                    onOpenPhoto: openPhoto,
                    onRestorationAnchorChanged: { anchor in
                        guard !collection.isSessionDerived else { return }
                        navigation.setTimelineAnchor(anchor, for: collection)
                    }).id(collection)
            }
        } else if let folderError {
            ContentUnavailableView { Label("Folders unavailable", systemImage: "folder.badge.questionmark") } description: { Text(folderError).textSelection(.enabled) } actions: { Button("Try Again") { Task { await model.reload() } } }
                .detailPlaceholder(topInset: topInset)
        } else {
            ProgressView("Loading folders…")
                .detailPlaceholder(topInset: topInset)
        }
    }

    private func folderHeader(_ children: [FolderSummary]) -> BrowserHeaderConfiguration? {
        guard !children.isEmpty else { return nil }
        let count = preferences.itemsPerRow
        return BrowserHeaderConfiguration(identity: AnyHashable(FolderHeaderIdentity(children: children, count: count)), height: { width in
            let cardWidth = CardGrid.cardWidth(width: width, count: count)
            let rows = (children.count + count - 1) / count
            return 2 * CardGrid.padding + CGFloat(rows) * (cardWidth + 26) + CGFloat(rows - 1) * CardGrid.spacing
        }, content: { repository, _ in
            AnyView(LazyVGrid(columns: CardGrid.columns(count), alignment: .leading, spacing: CardGrid.spacing) {
                ForEach(children) { child in
                    Button {
                        folderPath.append(child.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            FolderCoverView(folder: child, repository: repository, space: selectedSpace)
                            Text(child.displayName).font(.headline).lineLimit(1).frame(height: 20, alignment: .top)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(CardGrid.padding).frame(maxWidth: .infinity, alignment: .topLeading))
        })
    }

    private struct FolderHeaderIdentity: Hashable {
        let children: [FolderSummary]
        let count: Int
    }

    private func configureAlbumPresentation() {
        guard let namespace = model.presentationNamespace else { return }
        albumPresentation.configure(namespace: namespace)
        if !albumPresentation.pinnedCollections.isEmpty { model.ensureAlbumsLoaded() }
        validateOpenedAlbum(in: model.albums)
        synchronizeAlbumSelection()
    }

    private func showAlbumsOverviewForDrag(_ nonce: String) {
        guard sourceCollection != nil, dragOverviewNonce != nonce,
              let namespace = model.repository?.namespace else { return }
        guard model.session.drags.selections.observeEnd(nonce, namespace: namespace, action: {
            if dragOverviewNonce == nonce { dragOverviewNonce = nil }
        }) else { return }
        dragOverviewNonce = nonce
        model.ensureAlbumsLoaded()
    }

    private func select(_ selection: SidebarSelection) {
        guard selection != sidebarSelection else { return }
        if let active = viewer {
            guard active.close() else { return }
            active.canvasController.collapse(to: nil, reduceMotion: reduceMotion) {
                if viewer === active { viewer = nil }
                lastViewerFollowSelection = nil
                model.setActiveViewer(nil)
                infoPanel.updateViewer(active: false, item: nil)
                finishSelection(selection)
            }
            return
        }
        finishSelection(selection)
    }

    private func finishSelection(_ requested: SidebarSelection) {
        // Returning to Albums from another destination restores its last open route.
        let selection: SidebarSelection
        if requested == .destination(.albums), selectedDestination != .albums,
           let id = openedAlbum, albumPresentation.pinnedCollections.contains(id) {
            selection = .album(id)
        } else {
            selection = requested
        }
        let returningToAlbums = selectedDestination != .albums
        sidebarSelection = selection
        switch selection {
        case .album(let id):
            openedAlbum = id
            model.ensureAlbumsLoaded()
            model.ensureCollectionLoaded(id)
        case .destination(.recentlyAdded):
            if selectedSpace == .personal { model.ensureCollectionLoaded(.recentlyAdded) }
        case .destination(.albums):
            if returningToAlbums, let id = openedAlbum {
                model.ensureCollectionLoaded(id)
            } else {
                openedAlbum = nil
            }
            model.ensureAlbumsLoaded()
        case .destination:
            break
        }
        updateInfoPanelContext()
    }

    private func synchronizeAlbumSelection() {
        guard selectedDestination == .albums else { return }
        let selection: SidebarSelection = openedAlbum.flatMap {
            albumPresentation.pinnedCollections.contains($0) ? .album($0) : nil
        } ?? .destination(.albums)
        sidebarSelection = selection
    }

    private func validateOpenedAlbum(in albums: [AlbumSummary]) {
        albumPresentation.reconcile(albums, verified: model.albumsVerified)
        guard navigation.clearOpenedAlbumIfMissing(
            in: albums, verified: model.albumsVerified
        ) else { return }
        openedAlbum = nil
        synchronizeAlbumSelection()
        updateInfoPanelContext()
    }

    private func openAlbum(_ album: AlbumSummary) {
        guard let collection = album.collection else { return }
        openedAlbum = collection
        synchronizeAlbumSelection()
        model.ensureCollectionLoaded(collection)
        updateBackHandler()
        updateInfoPanelContext()
    }

    private func closeAlbum() {
        openedAlbum = nil
        synchronizeAlbumSelection()
        updateBackHandler()
        updateInfoPanelContext()
    }

    /// Opens a map pin or cluster in the filtered timeline. The filter is session-only
    /// and is never persisted for restoration.
    private func openMapGroup(_ memberIDs: [Int64]) {
        guard let selection = mapModel.filterSelection(for: memberIDs) else { return }
        mapFilterOpenGeneration &+= 1
        let generation = mapFilterOpenGeneration
        Task { @MainActor in
            if let previous = openedMapFilter {
                openedMapFilter = nil
                await model.closeMapFilter(previous)
            }
            guard mapFilterOpenGeneration == generation else { return }
            guard let descriptor = await model.openMapFilter(
                itemIDs: selection.ids, locationRevision: selection.revision
            ) else { return }
            guard mapFilterOpenGeneration == generation else {
                await model.closeMapFilter(descriptor)
                return
            }
            openedMapFilter = descriptor
            updateBackHandler()
            updateInfoPanelContext()
        }
    }

    private func closeMapFilter() {
        mapFilterOpenGeneration &+= 1
        guard let collection = openedMapFilter else { return }
        openedMapFilter = nil
        updateBackHandler()
        updateInfoPanelContext()
        Task { await model.closeMapFilter(collection) }
    }

    private func updateInfoPanelContext() {
        guard let collection = selectedCollection else {
            infoPanel.clearBrowserContext()
            return
        }
        infoPanel.updateBrowserContext(
            repository: model.repository,
            snapshot: model.snapshot(for: collection),
            collection: collection,
            selection: model.selectionState(for: collection).selection.indexes)
    }

    private func openPhoto(_ request: PhotoViewerOpenRequest) {
        guard viewer == nil, let repository = model.repository,
              let collection = selectedCollection,
              let snapshot = model.snapshot(for: collection) else { return }
        viewer = PhotoViewerPresentation(repository: repository, collection: collection,
                                         index: LibraryIndex(snapshot: snapshot),
                                         request: request, thumbnailSize: preferences.thumbnailSize,
                                         loadsLargePreviews: preferences.loadsLargeViewerPreviews,
                                         videoQuality: preferences.videoQuality,
                                         isIncoming: model.capabilities(for: collection).isIncoming,
                                         activity: model.activity,
                                         allowNetwork: model.timelineVerified(for: collection),
                                         snapshotRevision: model.viewerSnapshotRevision(for: collection))
        lastViewerFollowSelection = nil
        model.setActiveViewer(viewer)
        model.installViewerCloseHandler(closeViewer)
        updateBackHandler()
        infoPanel.updateViewer(active: true, item: request.seed.item)
        let panel = infoPanel
        viewer?.onInfoItemChanged = { [weak panel] item in
            panel?.updateViewer(active: true, item: item)
        }
        viewer?.canvasController.requestKeyboardFocus()
    }

    private func closeViewer() {
        guard let active = viewer else { return }
        let request = revealRequest(for: active, selectOnCompletion: true)
        guard active.close() else { return }
        let finish: (CGRect?) -> Void = { target in
            active.canvasController.collapse(to: target, reduceMotion: reduceMotion) {
                if viewer === active { viewer = nil }
                lastViewerFollowSelection = nil
                model.setActiveViewer(nil)
                updateBackHandler()
                infoPanel.updateViewer(active: false, item: nil)
                browserBridge.focusTimeline()
            }
        }
        if let request { browserBridge.reveal(request, completion: finish) }
        else { finish(nil) }
    }

    private func updateBackHandler() {
        if viewer != nil {
            model.installBackHandler(closeViewer)
        } else if selectedDestination == .personalLibrary && showsFolders && !folderPath.isEmpty {
            model.installBackHandler(folderBack)
        } else if openedIndexEntryID != nil {
            model.installBackHandler(closeIndexEntry)
        } else if isAlbumBrowser {
            model.installBackHandler(closeAlbum)
        } else if isMapFilterBrowser {
            model.installBackHandler(closeMapFilter)
        } else {
            model.installBackHandler(nil)
        }
    }

    private func followViewer(_ state: PhotoViewerState) {
        model.updateViewerCommands()
        guard let active = viewer, !active.isClosing,
              state.selection != lastViewerFollowSelection,
              let request = revealRequest(for: active) else { return }
        lastViewerFollowSelection = state.selection
        browserBridge.reveal(request)
    }

    private func revealRequest(for active: PhotoViewerPresentation,
                               selectOnCompletion: Bool = false) -> BrowserRevealRequest? {
        guard let state = active.state, let item = state.item else { return nil }
        return BrowserRevealRequest(itemID: item.id, dayID: item.utcDayID,
                                    sectionOffsetHint: active.sectionOffsetHint(for: state.desiredLocation),
                                    selectOnCompletion: selectOnCompletion)
    }

    /// Items keep one stable id across navigation states so AppKit reuses them instead of
    /// recreating the toolbar when a viewer or collection opens or closes.
    @ToolbarContentBuilder
    private var applicationToolbar: some CustomizableToolbarContent {
        leadingToolbar
        titleToolbar
        primaryToolbar
        statusToolbar
    }

    @ToolbarContentBuilder
    private var leadingToolbar: some CustomizableToolbarContent {
        let inViewer = viewer != nil
        let collection = inViewer ? nil : selectedCollection
        let isVideo = viewer?.state?.item?.isVideo == true

        if let (label, action) = toolbarBackAction {
            ToolbarItem(id: "back", placement: .navigation) {
                Button(action: action) {
                    Image(systemName: "chevron.left")
                        .frame(width: ToolbarMetrics.controlHeight, height: ToolbarMetrics.controlHeight)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(label)
                .help(label)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if !inViewer && selectedDestination != .albums {
            // One item so the space picker and the folder toggle share a single glass capsule.
            ToolbarItem(id: "space", placement: .navigation) {
                HStack(spacing: 4) {
                    Picker("Space", selection: $navigation.selectedSpace) {
                        Text("Personal Space").tag(PhotoSpace.personal)
                        Text("Shared Space").tag(PhotoSpace.shared)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    if selectedDestination == .personalLibrary {
                        Button { showsFolders.toggle() } label: {
                            Image(systemName: showsFolders ? "photo.on.rectangle" : "folder")
                        }
                        .help(showsFolders ? "Show Timeline" : "Browse Folders")
                        .accessibilityLabel(showsFolders ? "Show Timeline" : "Browse Folders")
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .navigation)
        }
        if let viewer, !isVideo {
            ToolbarItem(id: "zoom", placement: .navigation) {
                ViewerZoomControl(viewer: viewer)
            }
        }
        if !inViewer && (collection != nil || showsCardGrid) {
            ToolbarItem(id: "size", placement: .navigation) {
                LibrarySizeControl(value: $preferences.itemsPerRow)
            }
        }
        if collection != nil {
            ToolbarItem(id: "shape", placement: .navigation) {
                BrowserThumbnailShapeControl(preferences: preferences)
                    .frame(height: ToolbarMetrics.controlHeight)
            }
        }
    }

    @ToolbarContentBuilder
    private var titleToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "title", placement: .principal) {
            toolbarTitle(collection: viewer == nil ? selectedCollection : nil)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ToolbarContentBuilder
    private var primaryToolbar: some CustomizableToolbarContent {
        let inViewer = viewer != nil
        let collection = inViewer ? nil : selectedCollection
        let isVideo = viewer?.state?.item?.isVideo == true

        ToolbarSpacer(.flexible, placement: .primaryAction)
        if let viewer {
            if preferences.showsViewerToolbarTools {
                ToolbarItem(id: "overlays", placement: .primaryAction) {
                    ViewerOverlayControls(model: model)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if isVideo {
                ToolbarItem(id: "mute", placement: .primaryAction) {
                    Button { preferences.videoMuted.toggle() } label: {
                        Label(preferences.videoMuted ? "Unmute Video" : "Mute Video",
                              systemImage: preferences.videoMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .labelStyle(.iconOnly)
                    }
                    .help(preferences.videoMuted ? "Unmute Video" : "Mute Video")
                    .accessibilityLabel(preferences.videoMuted ? "Unmute Video" : "Mute Video")
                }
            } else {
                ToolbarItem(id: "rotate", placement: .primaryAction) {
                    ViewerRotationControls(viewer: viewer)
                        .frame(height: ToolbarMetrics.controlHeight)
                }
            }
            ToolbarItem(id: "favorite", placement: .primaryAction) {
                ViewerFavoriteControl(viewer: viewer)
                    .frame(height: ToolbarMetrics.controlHeight)
            }
        } else if let collection {
            ToolbarItem(id: "filter", placement: .primaryAction) {
                LibraryFilterToolbarControl()
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            ToolbarItem(id: "rotate", placement: .primaryAction) {
                BrowserRotationControls(model: model)
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            ToolbarItem(id: "favorite", placement: .primaryAction) {
                BrowserFavoriteControl(model: model, collection: collection)
                    .frame(height: ToolbarMetrics.controlHeight)
            }
        } else if selectedDestination == .albums {
            ToolbarItem(id: "newAlbum", placement: .primaryAction) {
                Button(action: model.beginEmptyAlbumCreation) {
                    Label("New Album", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("New Album")
                .accessibilityLabel("New Album")
                .disabled(model.repository == nil || model.albumOperation != nil)
            }
        }
        if inViewer || collection != nil {
            ToolbarItem(id: "info", placement: .primaryAction) {
                InfoPanelToolbarControl()
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    @ToolbarContentBuilder
    private var statusToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "activity", placement: .primaryAction) { ActivityToolbarItem(activity: model.activity) }
    }

    /// The single leading back button: closes the viewer, goes up a folder, or leaves the opened collection.
    private var toolbarBackAction: (String, () -> Void)? {
        if viewer != nil { return ("Back to Library", closeViewer) }
        if selectedDestination == .personalLibrary && showsFolders && !folderPath.isEmpty {
            return ("Back to Parent Folder", folderBack)
        }
        return collectionBackAction
    }

    @ViewBuilder
    private func toolbarTitle(collection: PhotoCollectionDescriptor?) -> some View {
        if let viewer {
            ViewerToolbarTitle(viewer: viewer)
        } else if collection != nil, selectedDestination == .personalLibrary && showsFolders {
            Text(folderDirectory?.folder.displayName ?? "Folders").font(.headline).lineLimit(1)
        } else if collection != nil, let kind = selectedDestination.indexKind {
            Text(indexEntries[kind]?.first(where: { $0.id == openedIndexEntryID })?.name ?? IndexOverviewStyle(kind).singular)
                .font(.headline).lineLimit(1)
        } else if collection != nil, isAlbumBrowser {
            Text(sourceCollection.flatMap { model.albumName(for: $0) } ?? "Album")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if collection != nil, isMapFilterBrowser {
            Text(mapFilterCount == 1 ? "1 Photo at This Location"
                                     : "\(mapFilterCount) Photos at This Location")
                .font(.headline)
                .lineLimit(1)
        } else if collection != nil, libraryFilter.isActive {
            Text(libraryFilter.statusText).font(.headline).lineLimit(1)
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Whether the current destination lists cards (albums, people, subjects, tags, folders) sized by the thumbnail slider.
    private var showsCardGrid: Bool {
        selectedDestination == .albums || selectedDestination.indexKind != nil
            || (selectedDestination == .personalLibrary && showsFolders)
    }

    private var collectionBackAction: (String, () -> Void)? {
        if let kind = selectedDestination.indexKind, openedIndexEntryID != nil {
            return ("Back to \(IndexOverviewStyle(kind).title)", closeIndexEntry)
        }
        if isAlbumBrowser { return ("Back to Albums", closeAlbum) }
        if isMapFilterBrowser { return ("Back to Map", closeMapFilter) }
        return nil
    }

}

/// Presentation for the People, Subjects and Tags overviews.
private struct IndexOverviewStyle {
    let title: String
    let singular: String
    let symbol: String
    let coverSymbol: String

    init(_ kind: CollectionIndexKind) {
        switch kind {
        case .person: (title, singular, symbol, coverSymbol) = ("People", "Person", "person.2", "person.crop.square")
        case .subject: (title, singular, symbol, coverSymbol) = ("Subjects", "Subject", "square.grid.2x2", "square.grid.2x2")
        case .tag: (title, singular, symbol, coverSymbol) = ("Tags", "Tag", "tag", "tag")
        }
    }
}
