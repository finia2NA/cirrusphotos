import PhotoCache
import SwiftUI
import SynologyAPI

struct AppShellView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var infoPanel: InfoPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var navigationRestoration: NavigationRestorationStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewer: PhotoViewerPresentation?
    @State private var selectedDestination: LibraryDestination
    @State private var openedAlbumID: Int64?
    @State private var chrome = WindowChromeMetrics()
    @State private var lastViewerFollowSelection: PhotoViewerSelection?
    @StateObject private var browserBridge = LibraryBrowserBridge()

    init(navigationRestoration: NavigationRestorationStore) {
        self.navigationRestoration = navigationRestoration
        _selectedDestination = State(initialValue: navigationRestoration.selectedDestination)
        _openedAlbumID = State(initialValue: navigationRestoration.openedAlbumID)
    }

    /// The collection currently browsed in the detail area, or nil for the Albums overview.
    private var selectedCollection: PhotoCollectionDescriptor? {
        switch selectedDestination {
        case .personalLibrary: .personalLibrary
        case .favorites: .favorites
        case .albums: openedAlbumID.map { .album($0) }
        }
    }

    private var isAlbumBrowser: Bool {
        selectedDestination == .albums && openedAlbumID != nil
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
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar { applicationToolbar }
        .onExitCommand {
            if viewer != nil { closeViewer() }
        }
        .onDisappear {
            dismissWindow(id: InfoPanelScene.id)
        }
        .task {
            if let id = openedAlbumID { model.ensureCollectionLoaded(.album(id)) }
        }
        .onChange(of: timelineVerified) { _, verified in
            viewer?.updateAllowNetwork(verified)
        }
        .onChange(of: model.retryRevision) { _, _ in
            viewer?.retry()
        }
        .onChange(of: viewerSnapshotRevision) { _, revision in
            if let viewer, viewer.snapshotRevision != revision { viewer.invalidateForNewIndex() }
        }
        .onChange(of: snapshotRevision) { _, _ in
            updateInfoPanelContext()
        }
        .onChange(of: model.albums) { _, albums in
            guard selectedDestination == .albums, let openedAlbumID,
                  !albums.isEmpty,
                  !albums.contains(where: { $0.id == openedAlbumID }) else { return }
            closeAlbum()
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
    }

    private var detail: some View {
        GeometryReader { geometry in
            let topInset = max(chrome.top, geometry.safeAreaInsets.top)
            ZStack(alignment: .topLeading) {
                if let collection = selectedCollection {
                    LibraryBrowserView(collection: collection,
                                       restorationAnchor: navigationRestoration.timelineAnchor(for: collection),
                                       bridge: browserBridge,
                                       contentTopInset: topInset,
                                       onOpenPhoto: openPhoto,
                                       onRestorationAnchorChanged: { anchor in
                                           navigationRestoration.setTimelineAnchor(anchor, for: collection)
                                       })
                        .id(collection)
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
                                    onSelectionChanged: followViewer,
                                    onClose: closeViewer)
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
        updateInfoPanelContext()
    }

    private func openAlbum(_ album: AlbumSummary) {
        openedAlbumID = album.id
        navigationRestoration.setOpenedAlbum(album.id)
        model.ensureCollectionLoaded(.album(album.id))
        updateInfoPanelContext()
    }

    private func closeAlbum() {
        openedAlbumID = nil
        navigationRestoration.setOpenedAlbum(nil)
        updateInfoPanelContext()
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
                                         allowNetwork: model.timelineVerified(for: collection),
                                         snapshotRevision: model.viewerSnapshotRevision(for: collection))
        lastViewerFollowSelection = nil
        model.setActiveViewer(viewer)
        model.installViewerCloseHandler(closeViewer)
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
                infoPanel.updateViewer(active: false, item: nil)
                browserBridge.focusTimeline()
            }
        }
        if let request { browserBridge.reveal(request, completion: finish) }
        else { finish(nil) }
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
                    Label("Back to Library", systemImage: "chevron.left")
                }
                .help("Back to Library")
            }
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) {
                ViewerZoomControl(viewer: viewer)
            }
            ToolbarItem(placement: .primaryAction) {
                ViewerFavoriteControl(viewer: viewer)
            }
            ToolbarItem(placement: .primaryAction) {
                InfoPanelToolbarControl()
            }
            ToolbarItem(placement: .principal) {
                ViewerToolbarTitle(viewer: viewer)
            }
            .sharedBackgroundVisibility(.hidden)
        } else if let collection = selectedCollection {
            if isAlbumBrowser {
                ToolbarItem(placement: .navigation) {
                    Button(action: closeAlbum) {
                        Label("Albums", systemImage: "chevron.left")
                    }
                    .help("Back to Albums")
                }
            }
            ToolbarItem(placement: .navigation) {
                LibrarySizeControl(value: $model.itemsPerRow)
            }
            ToolbarItem(placement: .primaryAction) {
                BrowserFavoriteControl(model: model, collection: collection)
            }
            ToolbarItem(placement: .primaryAction) {
                InfoPanelToolbarControl()
            }
            if isAlbumBrowser {
                ToolbarItem(placement: .principal) {
                    Text(model.albumName(for: collection) ?? "Album")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }

        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            ConnectionToolbarItem()
        }
    }

}
