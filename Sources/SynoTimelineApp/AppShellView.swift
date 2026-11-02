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
    @ObservedObject var albumPresentation: AlbumPresentationStore
    @State private var sidebarSelection: SidebarSelection
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewer: PhotoViewerPresentation?
    @State private var selectedDestination: LibraryDestination
    @State private var openedTagID: Int64?
    @State private var tags: [TagSummary]?
    @State private var tagsError: String?
    @State private var openedSubjectID: Int64?
    @State private var subjects: [SubjectSummary]?
    @State private var subjectsError: String?
    @State private var openedPersonID: Int64?
    @State private var people: [PersonSummary]?
    @State private var peopleError: String?
    @State private var openedAlbum: PhotoCollectionDescriptor?
    @State private var showsFolders: Bool
    @State private var folderPath: [Int64]
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

    init(navigationRestoration: NavigationRestorationStore, albumPresentation: AlbumPresentationStore) {
        self.navigationRestoration = navigationRestoration
        self.albumPresentation = albumPresentation
        _sidebarSelection = State(initialValue: navigationRestoration.sidebarSelection)
        _selectedDestination = State(initialValue: navigationRestoration.selectedDestination)
        _openedAlbum = State(initialValue: navigationRestoration.openedAlbum)
        _showsFolders = State(initialValue: navigationRestoration.showsFolders)
        _folderPath = State(initialValue: navigationRestoration.folderPath)
    }

    /// The collection currently browsed in the detail area, or nil for the Albums
    /// overview and the unfiltered map.
    private var sourceCollection: PhotoCollectionDescriptor? {
        switch selectedDestination {
        case .personalLibrary:
            if showsFolders { folderDirectoryRequest == (folderPath.last ?? 0) ? folderDirectory.map { .folder($0.folder.id) } : nil }
            else { .personalLibrary }
        case .favorites: .favorites
        case .recentlyAdded: .recentlyAdded
        case .people: openedPersonID.map { .person($0) }
        case .subjects: openedSubjectID.map { .subject($0) }
        case .tags: openedTagID.map { .tag($0) }
        case .albums: openedAlbum
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
        .background(DownloadCloseGuard().frame(width: 0, height: 0))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar { applicationToolbar }
        .onExitCommand {
            model.navigateBack()
        }
        .onAppear {
            configureAlbumPresentation()
            updateBackHandler()
            libraryFilter.configure(library: model, source: sourceCollection)
            timelineSectionLoad.configure(library: model, filter: libraryFilter)
            updateTimelineSectionLoadSource()
        }
        .onChange(of: selectedDestination) { _, _ in
            updateBackHandler(); updateTimelineSectionLoadSource()
        }
        .onChange(of: showsFolders) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .onChange(of: folderPath) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .task(id: PeopleLoadKey(namespace: model.presentationNamespace, active: selectedDestination == .people, resetRevision: model.metadataInvalidationRevision, retryRevision: model.retryRevision)) { await loadPeople() }
        .task(id: SubjectsLoadKey(namespace: model.presentationNamespace, active: selectedDestination == .subjects, resetRevision: model.metadataInvalidationRevision, retryRevision: model.retryRevision)) { await loadSubjects() }
        .task(id: TagsLoadKey(namespace: model.presentationNamespace, active: selectedDestination == .tags, resetRevision: model.metadataInvalidationRevision, retryRevision: model.retryRevision)) { await loadTags() }
        .onChange(of: openedTagID) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .onChange(of: openedSubjectID) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .onChange(of: openedPersonID) { _, _ in updateBackHandler(); updateTimelineSectionLoadSource() }
        .task(id: FolderLoadKey(namespace: model.presentationNamespace, active: selectedDestination == .personalLibrary && showsFolders, id: folderPath.last ?? 0, resetRevision: model.metadataInvalidationRevision, retryRevision: model.retryRevision)) { await loadFolder() }
        .onChange(of: openedAlbum) { _, _ in
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
            if selectedDestination == .recentlyAdded { model.ensureCollectionLoaded(.recentlyAdded) }
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
        .onChange(of: model.presentationNamespace) { _, _ in configureAlbumPresentation() }
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
        .sheet(item: $model.albumOperation) { operation in
            AlbumOperationView(model: model, operation: operation)
        }
        .alert("Album Update Failed", isPresented: Binding(
            get: { model.albumOperationError != nil },
            set: { if !$0 { model.albumOperationError = nil } }
        )) {
            Button("OK") { model.albumOperationError = nil }
        } message: {
            Text(model.albumOperationError ?? "The album update failed.")
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
                if selectedDestination == .personalLibrary && showsFolders {
                    folderDetail(topInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if let collection = selectedCollection {
                    LibraryBrowserView(collection: collection,
                                       restorationAnchor: collection.isSessionDerived
                                           ? nil : navigationRestoration.timelineAnchor(for: collection),
                                       bridge: browserBridge,
                                       pinnedAlbumIDs: albumPresentation.pinnedIDs,
                                       contentTopInset: topInset,
                                       onOpenPhoto: openPhoto,
                                       onRestorationAnchorChanged: { anchor in
                                           guard !collection.isSessionDerived else { return }
                                           navigationRestoration.setTimelineAnchor(anchor, for: collection)
                                       })
                        .id(collection)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if selectedDestination == .people {
                    peopleDetail(topInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if selectedDestination == .subjects {
                    subjectsDetail(topInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if selectedDestination == .tags {
                    tagsDetail(topInset: topInset)
                        .allowsHitTesting(viewer == nil)
                        .ignoresSafeArea(.container, edges: .top)
                } else if selectedDestination == .map {
                    MapBrowserView(model: mapModel, contentTopInset: topInset,
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

    private struct PeopleLoadKey: Hashable {
        let namespace: String?
        let active: Bool
        let resetRevision: UInt64
        let retryRevision: Int
    }

    private func loadPeople() async {
        guard selectedDestination == .people, let repository = model.repository else { return }
        let restored = navigationRestoration.preparePerson(namespace: repository.namespace)
        openedPersonID = restored
        if let restored { model.ensureCollectionLoaded(.person(restored)) }
        people = nil; peopleError = nil
        for await event in await repository.people() {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let list, let verified):
                people = list
                if verified, let id = openedPersonID, !list.contains(where: { $0.id == id }) {
                    openedPersonID = nil; navigationRestoration.setOpenedPerson(nil)
                }
            case .failure(let error): peopleError = error
            }
        }
    }

    private func closePerson() {
        openedPersonID = nil
        navigationRestoration.setOpenedPerson(nil)
        updateBackHandler(); updateInfoPanelContext()
    }

    @ViewBuilder private func peopleDetail(topInset: CGFloat) -> some View {
        if let people {
            ScrollView {
                if let peopleError { Text(peopleError).font(.caption).foregroundStyle(.secondary) }
                if people.isEmpty { ContentUnavailableView("No People", systemImage: "person.2") }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(people) { person in
                            Button {
                                openedPersonID = person.id
                                navigationRestoration.setOpenedPerson(person.id)
                                model.ensureCollectionLoaded(.person(person.id))
                                updateBackHandler(); updateInfoPanelContext()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumCoverView(thumbnail: person.thumbnail, repository: model.repository, placeholderSymbol: "person.crop.square")
                                    Text(person.name.isEmpty ? "Unnamed" : person.name).font(.headline).lineLimit(1)
                                    Text("\(person.itemCount) items").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.contentMargins(.top, topInset + 24).contentMargins(.horizontal, 24)
        } else if let peopleError {
            ContentUnavailableView { Label("People unavailable", systemImage: "person.2") } description: { Text(peopleError) } actions: { Button("Try Again") { Task { await model.reload() } } }
        } else { ProgressView("Loading people…") }
    }

    private struct SubjectsLoadKey: Hashable {
        let namespace: String?
        let active: Bool
        let resetRevision: UInt64
        let retryRevision: Int
    }

    private func loadSubjects() async {
        guard selectedDestination == .subjects, let repository = model.repository else { return }
        let restored = navigationRestoration.prepareSubject(namespace: repository.namespace)
        openedSubjectID = restored
        if let restored { model.ensureCollectionLoaded(.subject(restored)) }
        subjects = nil; subjectsError = nil
        for await event in await repository.subjects() {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let list, let verified):
                subjects = list
                if verified, let id = openedSubjectID, !list.contains(where: { $0.id == id }) {
                    openedSubjectID = nil; navigationRestoration.setOpenedSubject(nil)
                }
            case .failure(let error): subjectsError = error
            }
        }
    }

    private func closeSubject() {
        openedSubjectID = nil
        navigationRestoration.setOpenedSubject(nil)
        updateBackHandler(); updateInfoPanelContext()
    }

    @ViewBuilder private func subjectsDetail(topInset: CGFloat) -> some View {
        if let subjects {
            ScrollView {
                if let subjectsError { Text(subjectsError).font(.caption).foregroundStyle(.secondary) }
                if subjects.isEmpty { ContentUnavailableView("No Subjects", systemImage: "square.grid.2x2") }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(subjects) { subject in
                            Button {
                                openedSubjectID = subject.id
                                navigationRestoration.setOpenedSubject(subject.id)
                                model.ensureCollectionLoaded(.subject(subject.id))
                                updateBackHandler(); updateInfoPanelContext()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumCoverView(thumbnail: subject.thumbnail, repository: model.repository, placeholderSymbol: "square.grid.2x2")
                                    Text(subject.name.isEmpty ? "Unnamed" : subject.name).font(.headline).lineLimit(1)
                                    Text("\(subject.itemCount) items").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.contentMargins(.top, topInset + 24).contentMargins(.horizontal, 24)
        } else if let subjectsError {
            ContentUnavailableView { Label("Subjects unavailable", systemImage: "square.grid.2x2") } description: { Text(subjectsError) } actions: { Button("Try Again") { Task { await model.reload() } } }
        } else { ProgressView("Loading subjects…") }
    }

    private struct TagsLoadKey: Hashable {
        let namespace: String?
        let active: Bool
        let resetRevision: UInt64
        let retryRevision: Int
    }

    private func loadTags() async {
        guard selectedDestination == .tags, let repository = model.repository else { return }
        let restored = navigationRestoration.prepareTag(namespace: repository.namespace)
        openedTagID = restored
        if let restored { model.ensureCollectionLoaded(.tag(restored)) }
        tags = nil; tagsError = nil
        for await event in await repository.tags() {
            guard !Task.isCancelled else { return }
            switch event {
            case .value(let list, let verified):
                tags = list
                if verified, let id = openedTagID, !list.contains(where: { $0.id == id }) {
                    openedTagID = nil; navigationRestoration.setOpenedTag(nil)
                }
            case .failure(let error): tagsError = error
            }
        }
    }

    private func closeTag() {
        openedTagID = nil
        navigationRestoration.setOpenedTag(nil)
        updateBackHandler(); updateInfoPanelContext()
    }

    @ViewBuilder private func tagsDetail(topInset: CGFloat) -> some View {
        if let tags {
            ScrollView {
                if let tagsError { Text(tagsError).font(.caption).foregroundStyle(.secondary) }
                if tags.isEmpty { ContentUnavailableView("No Tags", systemImage: "tag") }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(tags) { tag in
                            Button {
                                openedTagID = tag.id
                                navigationRestoration.setOpenedTag(tag.id)
                                model.ensureCollectionLoaded(.tag(tag.id))
                                updateBackHandler(); updateInfoPanelContext()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumCoverView(thumbnail: tag.thumbnail, repository: model.repository, placeholderSymbol: "tag")
                                    Text(tag.name.isEmpty ? "Unnamed" : tag.name).font(.headline).lineLimit(1)
                                    Text("\(tag.itemCount) items").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.contentMargins(.top, topInset + 24).contentMargins(.horizontal, 24)
        } else if let tagsError {
            ContentUnavailableView { Label("Tags unavailable", systemImage: "tag") } description: { Text(tagsError) } actions: { Button("Try Again") { Task { await model.reload() } } }
        } else { ProgressView("Loading tags…") }
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
        let restoredPath = navigationRestoration.prepareFolders(namespace: repository.namespace)
        if restoredPath != folderPath { folderPath = restoredPath; return }
        let id = folderPath.last ?? 0
        folderDirectory = nil; folderDirectoryRequest = id; folderError = nil
        for await event in await repository.folderDirectory(id: id) {
            guard !Task.isCancelled, id == (folderPath.last ?? 0) else { return }
            switch event {
            case .value(let directory, _):
                folderDirectory = directory
                model.ensureCollectionLoaded(.folder(directory.folder.id))
            case .failure(let message): folderError = message
            }
        }
    }

    private func folderBack() {
        guard !folderPath.isEmpty else { return }
        folderPath.removeLast()
        navigationRestoration.setFolders(shown: showsFolders, path: folderPath)
    }

    @ViewBuilder private func folderDetail(topInset: CGFloat) -> some View {
        if let directory = folderDirectory, folderDirectoryRequest == (folderPath.last ?? 0), let collection = selectedCollection {
            VStack(spacing: 0) {
                if let folderError { Text(folderError).font(.caption).foregroundStyle(.secondary).padding(6) }
                LibraryBrowserView(collection: collection,
                    restorationAnchor: collection.isSessionDerived ? nil : navigationRestoration.timelineAnchor(for: collection),
                    bridge: browserBridge, pinnedAlbumIDs: albumPresentation.pinnedIDs, contentTopInset: topInset,
                    hidesEmptyCollectionState: !directory.children.isEmpty,
                    customHeader: folderHeader(directory.children),
                    onOpenPhoto: openPhoto,
                    onRestorationAnchorChanged: { anchor in
                        guard !collection.isSessionDerived else { return }
                        navigationRestoration.setTimelineAnchor(anchor, for: collection)
                    }).id(collection)
            }
        } else if let folderError {
            ContentUnavailableView { Label("Folders unavailable", systemImage: "folder.badge.questionmark") } description: { Text(folderError) } actions: { Button("Try Again") { Task { await model.reload() } } }
        } else { ProgressView("Loading folders…") }
    }

    private func folderHeader(_ children: [FolderSummary]) -> BrowserHeaderConfiguration? {
        guard !children.isEmpty else { return nil }
        return BrowserHeaderConfiguration(identity: AnyHashable(children), height: { width in
            let count = AlbumsOverviewView.columnCount(width: width)
            let cardWidth = min(240, max(0, (width - 48 - CGFloat(count - 1) * 20) / CGFloat(count)))
            let rows = (children.count + count - 1) / count
            return 48 + CGFloat(rows) * (cardWidth + 26) + CGFloat(rows - 1) * 20
        }, content: { repository, width in
            let count = AlbumsOverviewView.columnCount(width: width)
            let columns = Array(repeating: GridItem(.flexible(maximum: 240), spacing: 20, alignment: .leading), count: count)
            return AnyView(LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(children) { child in
                    Button {
                        folderPath.append(child.id)
                        navigationRestoration.setFolders(shown: showsFolders, path: folderPath)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AlbumCoverView(thumbnail: child.thumbnail, repository: repository, placeholderSymbol: "folder")
                            Text(child.displayName).font(.headline).lineLimit(1).frame(height: 20, alignment: .top)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading))
        })
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
        guard SelectionDragRegistry.observeEnd(nonce, namespace: namespace, action: {
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
        navigationRestoration.selectSidebar(selection)
        selectedDestination = selection.destination
        switch selection {
        case .album(let id):
            openedAlbum = id
            navigationRestoration.setOpenedAlbum(id)
            model.ensureAlbumsLoaded()
            model.ensureCollectionLoaded(id)
        case .destination(.recentlyAdded):
            model.ensureCollectionLoaded(.recentlyAdded)
        case .destination(.albums):
            if returningToAlbums, let id = openedAlbum {
                model.ensureCollectionLoaded(id)
            } else {
                openedAlbum = nil
                navigationRestoration.setOpenedAlbum(nil)
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
        navigationRestoration.selectSidebar(selection)
    }

    private func validateOpenedAlbum(in albums: [AlbumSummary]) {
        albumPresentation.reconcile(albums, verified: model.albumsVerified)
        guard navigationRestoration.clearOpenedAlbumIfMissing(
            in: albums, verified: model.albumsVerified
        ) else { return }
        openedAlbum = nil
        synchronizeAlbumSelection()
        updateInfoPanelContext()
    }

    private func openAlbum(_ album: AlbumSummary) {
        guard let collection = album.collection else { return }
        openedAlbum = collection
        navigationRestoration.setOpenedAlbum(collection)
        synchronizeAlbumSelection()
        model.ensureCollectionLoaded(collection)
        updateBackHandler()
        updateInfoPanelContext()
    }

    private func closeAlbum() {
        openedAlbum = nil
        navigationRestoration.setOpenedAlbum(nil)
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
                                         request: request, thumbnailSize: model.thumbnailSize,
                                         loadsLargePreviews: model.loadsLargeViewerPreviews,
                                         videoQuality: model.videoQuality,
                                         isIncoming: model.isIncomingCollection(collection),
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
        } else if selectedDestination == .people && openedPersonID != nil {
            model.installBackHandler(closePerson)
        } else if selectedDestination == .subjects && openedSubjectID != nil {
            model.installBackHandler(closeSubject)
        } else if selectedDestination == .tags && openedTagID != nil {
            model.installBackHandler(closeTag)
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
        if selectedDestination == .personalLibrary && viewer == nil {
            if showsFolders && !folderPath.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button(action: folderBack) {
                        Image(systemName: "chevron.left")
                            .frame(width: ToolbarMetrics.controlHeight, height: ToolbarMetrics.controlHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Back to Parent Folder")
                    .help("Back to Parent Folder")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .navigation) {
                Button { showsFolders.toggle(); navigationRestoration.setFolders(shown: showsFolders, path: folderPath) } label: {
                    Image(systemName: showsFolders ? "photo.on.rectangle" : "folder")
                }
                .help(showsFolders ? "Show Timeline" : "Browse Folders")
                .accessibilityLabel(showsFolders ? "Show Timeline" : "Browse Folders")
            }
        }
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
            collectionToolbar(collection)
        } else {
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .primaryAction)
            if selectedDestination == .albums {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.beginEmptyAlbumCreation) {
                        Image(systemName: "plus")
                    }
                    .help("New Album")
                    .accessibilityLabel("New Album")
                    .disabled(model.repository == nil || model.albumOperation != nil)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) { DownloadsToolbarControl() }
        ToolbarItem(placement: .primaryAction) {
            ConnectionToolbarItem()
        }
    }

    @ToolbarContentBuilder
    private func collectionToolbar(_ collection: PhotoCollectionDescriptor) -> some ToolbarContent {
            collectionBackToolbar
            ToolbarItem(placement: .navigation) {
                LibrarySizeControl(value: $model.itemsPerRow)
            }
            ToolbarItem(placement: .navigation) {
                BrowserThumbnailShapeControl(model: model)
                    .frame(height: ToolbarMetrics.controlHeight)
            }
            collectionTitleToolbar
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
    }

    private var collectionBackAction: (String, () -> Void)? {
        if selectedDestination == .people && openedPersonID != nil { return ("Back to People", closePerson) }
        if selectedDestination == .subjects && openedSubjectID != nil { return ("Back to Subjects", closeSubject) }
        if selectedDestination == .tags && openedTagID != nil { return ("Back to Tags", closeTag) }
        if isAlbumBrowser { return ("Back to Albums", closeAlbum) }
        if isMapFilterBrowser { return ("Back to Map", closeMapFilter) }
        return nil
    }

    @ToolbarContentBuilder
    private var collectionBackToolbar: some ToolbarContent {
        if let (label, action) = collectionBackAction {
            ToolbarItem(placement: .navigation) {
                Button(action: action) {
                    Image(systemName: "chevron.left")
                        .frame(width: ToolbarMetrics.controlHeight, height: ToolbarMetrics.controlHeight)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(label).help(label)
            }.sharedBackgroundVisibility(.hidden)
        }
    }

    @ToolbarContentBuilder
    private var collectionTitleToolbar: some ToolbarContent {
            if selectedDestination == .personalLibrary && showsFolders {
                ToolbarItem(placement: .principal) { Text(folderDirectory?.folder.displayName ?? "Folders").font(.headline).lineLimit(1) }
                .sharedBackgroundVisibility(.hidden)
            } else if selectedDestination == .people {
                ToolbarItem(placement: .principal) { Text(people?.first(where: { $0.id == openedPersonID })?.name ?? "Person").font(.headline).lineLimit(1) }
                    .sharedBackgroundVisibility(.hidden)
            } else if selectedDestination == .subjects {
                ToolbarItem(placement: .principal) { Text(subjects?.first(where: { $0.id == openedSubjectID })?.name ?? "Subject").font(.headline).lineLimit(1) }
                    .sharedBackgroundVisibility(.hidden)
            } else if selectedDestination == .tags {
                ToolbarItem(placement: .principal) { Text(tags?.first(where: { $0.id == openedTagID })?.name ?? "Tag").font(.headline).lineLimit(1) }
                    .sharedBackgroundVisibility(.hidden)
            } else if isAlbumBrowser {
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
    }

}
