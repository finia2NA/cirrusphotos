import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

@main
struct TimelinePrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = LibraryModel()
    @StateObject private var navigationRestoration = NavigationRestorationStore()

    var body: some Scene {
        WindowGroup("Cirrus Photos") {
            AppShellView(navigationRestoration: navigationRestoration)
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 420)
                .task { await model.load() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 820)
        .commands { LibraryCommands(model: model) }
        Settings { CacheSettingsView().environmentObject(model) }
        Window("Download Thumbnails", id: "thumbnail-download") {
            ThumbnailRangeDownloadView().environmentObject(model)
        }
        .defaultSize(width: 540, height: 500)
    }
}

private struct AppShellView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var navigationRestoration: NavigationRestorationStore
    @State private var sidebarVisible = true
    @State private var viewer: PhotoViewerPresentation?
    @State private var selectedCollection: PhotoCollectionDescriptor
    @State private var chrome = WindowChromeMetrics()
    private let sidebarWidth: CGFloat = 210

    init(navigationRestoration: NavigationRestorationStore) {
        self.navigationRestoration = navigationRestoration
        _selectedCollection = State(initialValue: navigationRestoration.selectedCollection)
    }

    var body: some View {
        GeometryReader { geometry in
            let topInset = max(chrome.top, geometry.safeAreaInsets.top)
            ZStack(alignment: .topLeading) {
                LibraryBrowserView(collection: selectedCollection,
                                   restorationAnchor: navigationRestoration.timelineAnchor(for: selectedCollection),
                                   contentLeadingInset: sidebarVisible ? sidebarWidth : 0,
                                   contentTopInset: topInset,
                                   onOpenPhoto: openPhoto,
                                   onRestorationAnchorChanged: { anchor in
                                       navigationRestoration.setTimelineAnchor(anchor, for: selectedCollection)
                                   })
                    .id(selectedCollection)
                    .allowsHitTesting(viewer == nil)
                    .ignoresSafeArea(.container, edges: .top)

                if let viewer {
                    PhotoViewerView(viewer: viewer,
                                    sidebarWidth: sidebarVisible ? sidebarWidth : 0,
                                    toolbarInset: topInset,
                                    reduceMotion: reduceMotion,
                                    onClose: closeViewer)
                        .ignoresSafeArea(.container, edges: .top)
                }

                Rectangle()
                    .fill(.regularMaterial)
                    .frame(maxWidth: .infinity)
                    .frame(height: topInset)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)

                if sidebarVisible {
                    sidebar()
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .glassEffect(.regular.interactive(), in: Rectangle())
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                WindowChromeMetricsReader { chrome = $0 }
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: sidebarVisible)
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
    }

    private func sidebar() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                select(.personalLibrary)
            } label: {
                Label("Personal Library", systemImage: "photo.on.rectangle.angled")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(selectedCollection == .personalLibrary ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            Text("Collections")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.top, 8)
            Button { select(.favorites) } label: {
                Label("Favorites", systemImage: "heart")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(selectedCollection == .favorites ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func select(_ collection: PhotoCollectionDescriptor) {
        if viewer != nil { closeViewer() }
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
    }

    private func closeViewer() {
        guard let active = viewer else { return }
        let canReturnToSource = active.state?.selection.itemID == active.originalItemID
        let target = canReturnToSource ? active.source.rectInWindowContent() : nil
        guard active.close() else { return }
        active.canvasController.collapse(to: target, reduceMotion: reduceMotion) {
            if viewer === active { viewer = nil }
        }
    }

    @ToolbarContentBuilder
    private var applicationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Color.clear
                .frame(width: toolbarLeadingAlignmentWidth, height: 1)
                .accessibilityHidden(true)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        }

        ToolbarSpacer(.fixed, placement: .navigation)

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
                LibrarySizeControl(value: $model.displayRowHeight)
            }
        }

        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            ConnectionToolbarItem()
        }
    }

    /// Navigation toolbar content begins just after the traffic lights. This fills the
    /// remaining portion of the sidebar so its toggle's trailing edge follows the divider.
    private var toolbarLeadingAlignmentWidth: CGFloat {
        max(0, sidebarWidth - chrome.trafficLightTrailing - 64)
    }
}

private struct LibrarySizeControl: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus").accessibilityHidden(true)
            Slider(value: $value, in: 100...300)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel("Thumbnail size")
                .accessibilityValue("\(Int(value.rounded())) points")
            Image(systemName: "plus").accessibilityHidden(true)
        }
        .imageScale(.small)
        .help("Thumbnail size")
    }
}

private struct ViewerZoomControl: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
            Slider(value: $viewer.zoom, in: 1...16)
                .frame(width: 96)
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(Int((viewer.zoom * 100).rounded())) percent of fit")
            Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
        }
        .imageScale(.small)
    }
}

/// The shell owns the viewer as optional navigation state, so it only observes changes to
/// that reference. This child observes the presentation itself and refreshes as soon as the
/// selected item's metadata arrives or its favorite state changes.
private struct ViewerFavoriteControl: View {
    @ObservedObject var viewer: PhotoViewerPresentation

    var body: some View {
        Button(action: viewer.toggleFavorite) {
            Label(viewer.state?.item?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: viewer.state?.item?.isFavorite == true ? "heart.fill" : "heart")
        }
        .disabled(!viewer.canToggleFavorite)
        .keyboardShortcut(".", modifiers: [])
        .help(viewer.state?.favoriteFailure ?? "Toggle Favorite (.)")
    }
}

private struct ViewerToolbarTitle: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    var body: some View {
        VStack(spacing: 0) {
            Text(viewer.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                if viewer.showsLoadingIndicator {
                    ProgressView().controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(viewer.detailLine)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 100, idealWidth: 270, maxWidth: 360)
        .help(viewer.detailLine)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionToolbarItem: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch library.authenticationStatus {
                case .notStarted:
                    Image(systemName: "circle.dotted")
                    Text(library.error == nil ? "Opening library…" : "Library unavailable")
                case .loggingIn:
                    ProgressView().controlSize(.mini)
                    Text("Logging in…")
                case .signedIn:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(library.error == nil ? "Connected" : "Metadata unavailable")
                        .help(library.error ?? "Signed in")
                case .failed(let message):
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("Login failed").help(message)
                }
            }
            .foregroundStyle(.secondary)

            if library.authenticationStatus != .signedIn || library.error != nil {
                Button("Retry") { Task { await library.reload() } }
                    .controlSize(.small)
                    .disabled(library.isLoading)
            }
        }
        .font(.caption)
    }
}

private struct LibraryCommands: Commands {
    @ObservedObject var model: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Library") {
            Button("Increase Thumbnail Size") { model.adjustDisplayRowHeight(by: 20) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.displayRowHeight >= 300)
            Button("Decrease Thumbnail Size") { model.adjustDisplayRowHeight(by: -20) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.displayRowHeight <= 100)
            Divider()
            Button("Download Thumbnails…") { openWindow(id: "thumbnail-download") }
                .disabled(model.snapshot?.timeline.days.isEmpty != false || model.repository == nil ||
                          !model.timelineVerified)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private var snapshots: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    @Published private var snapshotRevisions: [PhotoCollectionDescriptor: Int] = [:]
    @Published private var viewerSnapshotRevisions: [PhotoCollectionDescriptor: Int] = [:]
    @Published private var timelineVerifications: [PhotoCollectionDescriptor: Bool] = [:]
    @Published private(set) var status = "Opening library…"
    @Published private var collectionErrors: [PhotoCollectionDescriptor: String] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var authenticationStatus: AuthenticationStatus = .notStarted
    @Published private(set) var retryRevision = 0
    var authenticationFailed: Bool {
        if case .failed = authenticationStatus { return true }
        return false
    }
    @Published var thumbnailSize: ThumbnailSize = ThumbnailSize(rawValue: UserDefaults.standard.string(forKey: "thumbnailSize") ?? "m") ?? .m {
        didSet { UserDefaults.standard.set(thumbnailSize.rawValue, forKey: "thumbnailSize") }
    }
    @Published var loadsLargeViewerPreviews: Bool = UserDefaults.standard.bool(forKey: "loadsLargeViewerPreviews") {
        didSet { UserDefaults.standard.set(loadsLargeViewerPreviews, forKey: "loadsLargeViewerPreviews") }
    }
    @Published var displayRowHeight: Double = LibraryModel.persistedDisplayRowHeight() {
        didSet {
            let valid = Self.validDisplayRowHeight(displayRowHeight)
            if valid != displayRowHeight { displayRowHeight = valid }
            UserDefaults.standard.set(valid, forKey: "displayRowHeight")
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

    private static func persistedDisplayRowHeight() -> Double {
        guard let value = (UserDefaults.standard.object(forKey: "displayRowHeight") as? NSNumber)?.doubleValue else {
            return 180
        }
        return validDisplayRowHeight(value)
    }

    private static func validDisplayRowHeight(_ value: Double) -> Double {
        guard value.isFinite else { return 180 }
        return min(max(value, 100), 300)
    }

    func adjustDisplayRowHeight(by amount: Double) {
        displayRowHeight = Self.validDisplayRowHeight(displayRowHeight + amount)
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
                        self?.receive(event, collection: collection, forceRevision: true)
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
            status = "Library unavailable"
        }
        isLoading = false
    }

    private func receive(_ event: ResourceEvent<TimelineSnapshot>, collection: PhotoCollectionDescriptor,
                         forceRevision: Bool = false) {
        switch event {
        case .value(let snapshot, let verified):
            let changed = snapshots[collection]?.sections != snapshot.sections
            if forceRevision || changed {
                snapshots[collection] = snapshot
                snapshotRevisions[collection, default: 0] += 1
                if changed, !forceRevision {
                    viewerSnapshotRevisions[collection, default: 0] += 1
                }
            }
            timelineVerifications[collection] = verified
            if verified { collectionErrors.removeValue(forKey: collection) }
            if collection == .personalLibrary {
                status = verified ? "Personal Space · Current" : "Personal Space · Cached or initial"
            }
        case .failure(let message):
            collectionErrors[collection] = message
            if collection == .personalLibrary {
                status = snapshots[collection] == nil ? "Library unavailable" : "Personal Space · Offline copy"
            }
        }
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        if let repository { await repository.retryAuthentication() }
        retryRevision += 1
        started = false
        status = "Checking Cirrus…"
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

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct TimelineNavigator: View {
    let timeline: Timeline
    @Binding var selected: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Int?
    @State private var pointerIsNear = false
    @State private var dragging = false
    @State private var keyboardActive = false
    @State private var lastDragIndex: Int?
    @FocusState private var focused: Bool
    private let inset: CGFloat = 14

    private var isRevealed: Bool { pointerIsNear || dragging || (focused && keyboardActive) }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - inset * 2)
            let width = geometry.size.width
            let y: (Int) -> CGFloat = { inset + height * timeline.fraction(at: $0) }

            Canvas { context, size in
                let rail = size.width - 10
                var line = Path()
                line.move(to: CGPoint(x: rail, y: inset))
                line.addLine(to: CGPoint(x: rail, y: size.height - inset))
                context.stroke(line, with: .color(.primary.opacity(0.12)), lineWidth: 1)

                // Paint marks in one canvas; dates never create individual hit targets.
                for index in timeline.monthStarts {
                    let dot = CGRect(x: rail - 1.5, y: y(index) - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.32)))
                }
                var lastLabelY: CGFloat = -.infinity
                for index in timeline.yearStarts {
                    let position = y(index)
                    guard position - lastLabelY >= 25 else { continue }
                    context.draw(Text(String(timeline.days[index].year)).font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary.opacity(0.82)),
                        at: CGPoint(x: rail - 11, y: position), anchor: .trailing)
                    lastLabelY = position
                }
                var selection = Path()
                if !timeline.days.isEmpty {
                    let safeSelection = min(max(0, selected), timeline.days.count - 1)
                    selection.move(to: CGPoint(x: rail - 7, y: y(safeSelection)))
                    selection.addLine(to: CGPoint(x: rail + 6, y: y(safeSelection)))
                }
                context.stroke(selection, with: .color(.pink), lineWidth: 2)
            }
            .opacity(isRevealed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isRevealed)
            .allowsHitTesting(false)

            if isRevealed, let hovered, timeline.days.indices.contains(hovered) {
                let markerY = y(hovered)
                Rectangle().fill(.pink.opacity(0.7)).frame(width: width - 8, height: 1)
                    .position(x: width / 2, y: markerY).allowsHitTesting(false)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeline.days[hovered].monthLabel).font(.system(size: 15, weight: .semibold))
                    Text(timeline.days[hovered].id).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .monospacedDigit().padding(.horizontal, 9).padding(.vertical, 6)
                .frame(width: 126, alignment: .trailing)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .position(x: width - 63,
                          y: min(max(markerY - 29, 25), geometry.size.height - 25))
                .allowsHitTesting(false)
            }

            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        pointerIsNear = true
                        hovered = timeline.index(at: (point.y - inset) / height)
                    case .ended:
                        pointerIsNear = false
                        hovered = focused && keyboardActive || dragging ?
                            (timeline.days.indices.contains(selected) ? selected : nil) : nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    keyboardActive = false
                    dragging = true
                    focused = true
                    if let index = timeline.index(at: (value.location.y - inset) / height) {
                        if lastDragIndex != index { selected = index; lastDragIndex = index }
                        hovered = index
                    }
                }.onEnded { _ in
                    dragging = false
                    lastDragIndex = nil
                    if !pointerIsNear && !(focused && keyboardActive) { hovered = nil }
                })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    guard !timeline.days.isEmpty else { return .handled }
                    keyboardActive = true
                    selected = max(0, min(selected, timeline.days.count - 1) - 1); hovered = selected; return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !timeline.days.isEmpty else { return .handled }
                    keyboardActive = true
                    selected = min(timeline.days.count - 1, max(0, selected) + 1); hovered = selected; return .handled
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Library timeline")
                .accessibilityValue(timeline.days[safe: selected]?.id ?? "No dates")
                .accessibilityHint("Use up and down arrows to select adjacent populated days.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if !timeline.days.isEmpty { selected = min(timeline.days.count - 1, max(0, selected) + 1) }
                    case .decrement: if !timeline.days.isEmpty { selected = max(0, min(selected, timeline.days.count - 1) - 1) }
                    @unknown default: break
                    }
                    keyboardActive = true
                    focused = true
                    hovered = timeline.days.indices.contains(selected) ? selected : nil
                }
                .onChange(of: focused) { _, isFocused in
                    if isFocused, !pointerIsNear, !dragging, !timeline.days.isEmpty {
                        keyboardActive = true
                        hovered = min(max(0, selected), timeline.days.count - 1)
                    } else if !isFocused {
                        keyboardActive = false
                        if !pointerIsNear && !dragging { hovered = nil }
                    }
                }
                .onChange(of: selected) { _, newSelection in
                    if focused && keyboardActive, !pointerIsNear, !dragging,
                       timeline.days.indices.contains(newSelection) {
                        hovered = newSelection
                    } else if !pointerIsNear && !dragging && !(focused && keyboardActive) {
                        hovered = nil
                    }
                }
        }
    }
}
