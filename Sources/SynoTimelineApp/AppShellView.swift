import PhotoCache
import SwiftUI
import SynologyAPI

struct AppShellView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var navigationRestoration: NavigationRestorationStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewer: PhotoViewerPresentation?
    @State private var selectedCollection: PhotoCollectionDescriptor
    @State private var chrome = WindowChromeMetrics()
    @State private var lastViewerFollowSelection: PhotoViewerSelection?
    @StateObject private var browserBridge = LibraryBrowserBridge()

    init(navigationRestoration: NavigationRestorationStore) {
        self.navigationRestoration = navigationRestoration
        _selectedCollection = State(initialValue: navigationRestoration.selectedCollection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { selectedCollection }, set: select)) {
                Label("Personal Library", systemImage: "photo.on.rectangle.angled")
                    .tag(PhotoCollectionDescriptor.personalLibrary)
                Section("Collections") {
                    Label("Favorites", systemImage: "heart")
                        .tag(PhotoCollectionDescriptor.favorites)
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
        .onChange(of: model.timelineVerified(for: selectedCollection)) { _, verified in
            viewer?.updateAllowNetwork(verified)
        }
        .onChange(of: model.retryRevision) { _, _ in
            viewer?.retry()
        }
        .onChange(of: model.viewerSnapshotRevision(for: selectedCollection)) { _, revision in
            if let viewer, viewer.snapshotRevision != revision { viewer.invalidateForNewIndex() }
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
            let collection = selectedCollection
            ZStack(alignment: .topLeading) {
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

    private func select(_ collection: PhotoCollectionDescriptor) {
        guard collection != selectedCollection else { return }
        if let active = viewer {
            guard active.close() else { return }
            active.canvasController.collapse(to: nil, reduceMotion: reduceMotion) {
                if viewer === active { viewer = nil }
                lastViewerFollowSelection = nil
                model.setActiveViewer(nil)
                finishSelection(collection)
            }
            return
        }
        finishSelection(collection)
    }

    private func finishSelection(_ collection: PhotoCollectionDescriptor) {
        navigationRestoration.select(collection)
        selectedCollection = collection
    }

    private func openPhoto(_ request: PhotoViewerOpenRequest) {
        guard viewer == nil, let repository = model.repository,
              let snapshot = model.snapshot(for: selectedCollection) else { return }
        viewer = PhotoViewerPresentation(repository: repository, collection: selectedCollection,
                                         index: LibraryIndex(snapshot: snapshot),
                                         request: request, thumbnailSize: model.thumbnailSize,
                                         loadsLargePreviews: model.loadsLargeViewerPreviews,
                                         allowNetwork: model.timelineVerified(for: selectedCollection),
                                         snapshotRevision: model.viewerSnapshotRevision(for: selectedCollection))
        lastViewerFollowSelection = nil
        model.setActiveViewer(viewer)
        model.installViewerCloseHandler(closeViewer)
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
            ToolbarItem(placement: .principal) {
                ViewerToolbarTitle(viewer: viewer)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                LibrarySizeControl(value: $model.itemsPerRow)
            }
            ToolbarItem(placement: .primaryAction) {
                BrowserFavoriteControl(model: model, collection: selectedCollection)
            }
        }

        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            ConnectionToolbarItem()
        }
    }

}
