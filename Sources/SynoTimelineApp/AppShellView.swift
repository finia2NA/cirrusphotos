import PhotoCache
import SwiftUI
import SynologyAPI

struct AppShellView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var infoPanel: InfoPanelModel
    @EnvironmentObject private var libraryFilter: LibraryFilterModel
    @EnvironmentObject private var timelineSectionLoad: TimelineSectionLoadModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var navigationRestoration: NavigationRestorationStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewer: PhotoViewerPresentation?
    @State private var selectedDestination: LibraryDestination
    @State private var openedAlbumID: Int64?
    @State private var openedMapFilter: PhotoCollectionDescriptor?
    @State private var mapFilterOpenGeneration: UInt64 = 0
    @State private var chrome = WindowChromeMetrics()
    @State private var lastViewerFollowSelection: PhotoViewerSelection?
    @StateObject private var browserBridge = LibraryBrowserBridge()
    @StateObject private var mapModel = MapBrowserModel()

    init(navigationRestoration: NavigationRestorationStore) {
        self.navigationRestoration = navigationRestoration
        _selectedDestination = State(initialValue: navigationRestoration.selectedDestination)
        _openedAlbumID = State(initialValue: navigationRestoration.openedAlbumID)
    }

    /// The collection currently browsed in the detail area, or nil for the Albums
    /// overview and the unfiltered map.
    private var sourceCollection: PhotoCollectionDescriptor? {
        switch selectedDestination {
        case .personalLibrary: .personalLibrary
        case .favorites: .favorites
        case .albums: openedAlbumID.map { .album($0) }
        case .map: openedMapFilter
        }
    }

    private var selectedCollection: PhotoCollectionDescriptor? {
        libraryFilter.activeCollection(for: sourceCollection) ?? sourceCollection
    }

    private var sourceSnapshotRevision: Int {
        sourceCollection.map { model.snapshotRevision(for: $0) } ?? 0
    }

    private var sourceTimelineVerified: Bool {
        sourceCollection.map { model.timelineVerified(for: $0) } ?? false
    }

    private var isAlbumBrowser: Bool {
        selectedDestination == .albums && openedAlbumID != nil
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { selectedDestination }, set: select)) {
                Label("Library", systemImage: "photo.on.rectangle.angled")
                    .tag(LibraryDestination.personalLibrary)
                Section("Collections") {
                    Label("Favorites", systemImage: "heart")
                        .tag(LibraryDestination.favorites)
                    Label("Map", systemImage: "map")
                        .tag(LibraryDestination.map)
                }
                Section("Albums") {
                    Label("Albums", systemImage: "rectangle.stack")
                        .tag(LibraryDestination.albums)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            detail
        }
        .background(DownloadCloseGuard().frame(width: 0, height: 0))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar { applicationToolbar }
        .onExitCommand {
            model.navigateBack()
        }
        .onAppear {
            updateBackHandler()
            libraryFilter.configure(library: model, source: sourceCollection)
            timelineSectionLoad.configure(library: model, filter: libraryFilter)
            updateTimelineSectionLoadSource()
        }
        .onChange(of: selectedDestination) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: openedAlbumID) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: openedMapFilter) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: sourceCollection) { _, _ in
            libraryFilter.configure(library: model, source: sourceCollection)
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
            guard selectedDestination == .albums else { return }
            model.ensureAlbumsLoaded()
            if let id = openedAlbumID { model.ensureCollectionLoaded(.album(id)) }
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
        .alert(
            "Favorite Update Failed",
            isPresented: Binding(
                get: { model.browserFavoriteFailure != nil },
                set: { if !$0 { model.dismissBrowserFavoriteFailure() } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.dismissBrowserFavoriteFailure()
            }
        } message: {
            Text(model.browserFavoriteFailure ?? "The favorite update failed.")
        }
        .alert("Rotation Failed", isPresented: Binding(
            get: { model.rotationFailure != nil || viewer?.rotationFailure != nil },
            set: { if !$0 { model.dismissRotationFailure(); viewer?.dismissRotationFailure() } }
        )) {
            Button("OK") { model.dismissRotationFailure(); viewer?.dismissRotationFailure() }
        } message: {
            Text(model.rotationFailure ?? viewer?.rotationFailure ?? "The photo could not be rotated.")
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
                if let collection = selectedCollection {
                    LibraryBrowserView(collection: collection,
                                       restorationAnchor: collection.isSessionDerived
                                           ? nil : navigationRestoration.timelineAnchor(for: collection),
                                       bridge: browserBridge,
                                       contentTopInset: topInset,
                                       onOpenPhoto: openPhoto,
                                       onRestorationAnchorChanged: { anchor in
                                           guard !collection.isSessionDerived else { return }
                                           navigationRestoration.setTimelineAnchor(anchor, for: collection)
                                       })
                        .id(collection)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if selectedDestination == .map {
                    MapBrowserView(model: mapModel, contentTopInset: topInset,
                                   onOpenPhoto: { openMapGroup([$0]) },
                                   onOpenGroup: openMapGroup)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else {
                    AlbumsOverviewView(onOpenAlbum: openAlbum, contentTopInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                }

                if let viewer {
                    PhotoViewerView(viewer: viewer,
                                    toolbarInset: topInset,
                                    reduceMotion: reduceMotion,
                                    pixelInterpolation: model.pixelInterpolation,
                                    videoMuted: model.videoMuted,
                                    showsFilmstrip: model.showsFilmstrip,
                                    cropsThumbnailsToSquare: model.cropsThumbnailsToSquare,
                                    showsHistogram: model.showsHistogram,
                                    showsHighlightPeaking: model.showsHighlightPeaking,
                                    onVideoMuteChanged: { model.videoMuted = $0 },
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

    private func select(_ destination: LibraryDestination) {
        guard destination != selectedDestination else { return }
        if let active = viewer {
            guard active.close() else { return }
            active.canvasController.collapse(to: nil, reduceMotion: reduceMotion) {
                if viewer === active { viewer = nil }
                lastViewerFollowSelection = nil
                model.setActiveViewer(nil)
                infoPanel.updateViewer(active: false, item: nil)
                finishSelection(destination)
            }
            return
        }
        finishSelection(destination)
    }

    private func finishSelection(_ destination: LibraryDestination) {
        navigationRestoration.select(destination)
        selectedDestination = destination
        if destination == .albums {
            model.ensureAlbumsLoaded()
            validateOpenedAlbum(in: model.albums)
            if let openedAlbumID { model.ensureCollectionLoaded(.album(openedAlbumID)) }
        }
        updateInfoPanelContext()
    }

    private func validateOpenedAlbum(in albums: [AlbumSummary]) {
        guard selectedDestination == .albums,
              navigationRestoration.clearOpenedAlbumIfMissing(
                in: albums, verified: model.albumsVerified
              ) else { return }
        openedAlbumID = nil
        updateInfoPanelContext()
    }

    private func openAlbum(_ album: AlbumSummary) {
        openedAlbumID = album.id
        navigationRestoration.setOpenedAlbum(album.id)
        model.ensureCollectionLoaded(.album(album.id))
        updateBackHandler()
        updateInfoPanelContext()
    }

    private func closeAlbum() {
        openedAlbumID = nil
        navigationRestoration.setOpenedAlbum(nil)
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
                                         request: request, thumbnailSize: model.thumbnailSize,
                                         loadsLargePreviews: model.loadsLargeViewerPreviews,
                                         videoQuality: model.videoQuality,
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

    @ToolbarContentBuilder
    private var applicationToolbar: some ToolbarContent {
        if let viewer {
            ToolbarItem(placement: .navigation) {
                Button(action: closeViewer) {
                    Image(systemName: "chevron.left")
                        .frame(width: ToolbarMetrics.controlHeight,
                               height: ToolbarMetrics.controlHeight)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Back to Library")
                .help("Back to Library")
            }
            .sharedBackgroundVisibility(.hidden)
            if viewer.state?.item?.isVideo != true {
                ToolbarItem(placement: .navigation) {
                    ViewerZoomControl(viewer: viewer)
                }
            }
            ToolbarItem(placement: .principal) {
                ViewerToolbarTitle(viewer: viewer)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showsFilmstrip.toggle() } label: {
                    Image(systemName: model.showsFilmstrip ? "film.fill" : "film")
                        .foregroundStyle(model.showsFilmstrip ? Color.accentColor : Color.primary)
                }
                .help(model.showsFilmstrip ? "Hide Filmstrip" : "Show Filmstrip")
                .accessibilityLabel(model.showsFilmstrip ? "Hide Filmstrip" : "Show Filmstrip")
                Button { model.showsHistogram.toggle() } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(model.showsHistogram ? Color.accentColor : Color.primary)
                }
                .help(model.showsHistogram ? "Hide Histogram" : "Show Histogram")
                .accessibilityLabel(model.showsHistogram ? "Hide Histogram" : "Show Histogram")
                Button { model.showsHighlightPeaking.toggle() } label: {
                    Image(systemName: "circle.lefthalf.striped.horizontal")
                        .foregroundStyle(model.showsHighlightPeaking ? Color.accentColor : Color.primary)
                }
                .help(model.showsHighlightPeaking ? "Hide Highlight Peaking" : "Show Highlight Peaking")
                .accessibilityLabel(model.showsHighlightPeaking ? "Hide Highlight Peaking" : "Show Highlight Peaking")
                if viewer.state?.item?.isVideo == true {
                    Button { model.videoMuted.toggle() } label: {
                        Image(systemName: model.videoMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(model.videoMuted ? "Unmute Video" : "Mute Video")
                    .accessibilityLabel(model.videoMuted ? "Unmute Video" : "Mute Video")
                }
                if viewer.state?.item?.isVideo != true {
                    ViewerRotationControls(viewer: viewer)
                        .frame(height: ToolbarMetrics.controlHeight)
                }
                ViewerFavoriteControl(viewer: viewer)
                    .frame(height: ToolbarMetrics.controlHeight)
                InfoPanelToolbarControl()
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else if let collection = selectedCollection {
            if isAlbumBrowser {
                ToolbarItem(placement: .navigation) {
                    Button(action: closeAlbum) {
                        Image(systemName: "chevron.left")
                            .frame(width: ToolbarMetrics.controlHeight,
                                   height: ToolbarMetrics.controlHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Back to Albums")
                    .help("Back to Albums")
                }
                .sharedBackgroundVisibility(.hidden)
            } else if isMapFilterBrowser {
                ToolbarItem(placement: .navigation) {
                    Button(action: closeMapFilter) {
                        Image(systemName: "chevron.left")
                            .frame(width: ToolbarMetrics.controlHeight,
                                   height: ToolbarMetrics.controlHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Back to Map")
                    .help("Back to Map")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .navigation) {
                LibrarySizeControl(value: $model.itemsPerRow)
            }
            ToolbarItem(placement: .navigation) {
                BrowserThumbnailShapeControl(model: model)
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            if isAlbumBrowser {
                ToolbarItem(placement: .principal) {
                    Text(sourceCollection.flatMap { model.albumName(for: $0) } ?? "Album")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .sharedBackgroundVisibility(.hidden)
            } else if isMapFilterBrowser {
                ToolbarItem(placement: .principal) {
                    Text(mapFilterCount == 1 ? "1 Photo at This Location"
                                             : "\(mapFilterCount) Photos at This Location")
                        .font(.headline)
                        .lineLimit(1)
                }
                .sharedBackgroundVisibility(.hidden)
            } else if libraryFilter.isActive {
                ToolbarItem(placement: .principal) {
                    Text(libraryFilter.statusText).font(.headline).lineLimit(1)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                LibraryFilterToolbarControl()
                    .frame(height: ToolbarMetrics.controlHeight)
                BrowserRotationControls(model: model)
                    .frame(height: ToolbarMetrics.controlHeight)
                BrowserFavoriteControl(model: model, collection: collection)
                    .frame(height: ToolbarMetrics.controlHeight)
                InfoPanelToolbarControl()
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) { DownloadsToolbarControl() }
        ToolbarItem(placement: .primaryAction) {
            ConnectionToolbarItem()
        }
    }

}
