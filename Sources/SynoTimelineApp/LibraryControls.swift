import SwiftUI
import SynologyAPI
import PhotoCache

enum ToolbarMetrics {
    static let controlHeight: CGFloat = 36
}

struct LibrarySizeControl: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus").accessibilityHidden(true)
            Slider(value: Binding(get: { Double(13 - value) },
                                  set: { value = 13 - Int($0.rounded()) }), in: 3...10, step: 1)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel("Thumbnail size")
                .accessibilityValue("\(value) items per row")
            Image(systemName: "plus").accessibilityHidden(true)
        }
        .frame(height: ToolbarMetrics.controlHeight)
        .padding(.horizontal, 4)
        .imageScale(.small)
        .help("Thumbnail size")
    }
}

struct ViewerZoomControl: View {
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
        .frame(height: ToolbarMetrics.controlHeight)
        .padding(.horizontal, 4)
        .imageScale(.small)
    }
}

/// The shell owns the viewer as optional navigation state, so it only observes changes to
/// that reference. This child observes the presentation itself and refreshes as soon as the
/// selected item's metadata arrives or its favorite state changes.
struct ViewerFavoriteControl: View {
    @ObservedObject var viewer: PhotoViewerPresentation

    var body: some View {
        Button(action: viewer.toggleFavorite) {
            Label(viewer.state?.item?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: viewer.state?.item?.isFavorite == true ? "heart.fill" : "heart")
        }
        .disabled(!viewer.canToggleFavorite)
        .help(viewer.state?.favoriteFailure ?? "Toggle Favorite (.)")
    }
}

/// Toggles the shared browser between aspect-fitted and square-cropped thumbnails.
/// The Library menu's "Crop Thumbnails to Square" command is the discoverable equivalent.
struct BrowserThumbnailShapeControl: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Button {
            preferences.cropsThumbnailsToSquare.toggle()
        } label: {
            Label(preferences.cropsThumbnailsToSquare ? "Use Aspect-Fit Thumbnails" : "Crop Thumbnails to Square",
                  systemImage: preferences.cropsThumbnailsToSquare
                      ? "rectangle.arrowtriangle.2.inward"
                      : "rectangle.arrowtriangle.2.outward")
        }
        .accessibilityLabel(preferences.cropsThumbnailsToSquare ? "Use Aspect-Fit Thumbnails" : "Crop Thumbnails to Square")
        .help(preferences.cropsThumbnailsToSquare
              ? "Crop Thumbnails to Square (on)"
              : "Crop Thumbnails to Square (off)")
    }
}

struct BrowserFavoriteControl: View {
    var model: LibraryModel
    let collection: PhotoCollectionDescriptor

    var body: some View {
        Button(action: model.toggleSelectionFavorite) {
            Label("Toggle Favorite", systemImage: model.browserSelectionFavorited && canToggle ? "heart.fill" : "heart")
        }
        .disabled(!canToggle)
        .accessibilityLabel(accessibilityLabel)
        .help("Toggle Favorite (.)")
    }

    private var canToggle: Bool {
        model.canToggleBrowserFavorite && model.timelineVerified(for: collection)
    }

    private var accessibilityLabel: String {
        let count = model.browserSelectionCount
        if count == 0 {
            return "Toggle Favorite"
        } else if count == 1 {
            return "Toggle Favorite for 1 Selected Item"
        } else {
            return "Toggle Favorite for \(count) Selected Items"
        }
    }
}

struct ViewerRotationControls: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    var body: some View {
        HStack(spacing: 2) {
            Button { viewer.rotate(.counterClockwise) } label: {
                Label("Rotate Photo Left", systemImage: "rotate.left")
            }
            Button { viewer.rotate(.clockwise) } label: {
                Label("Rotate Photo Right", systemImage: "rotate.right")
            }
        }
        .disabled(!viewer.canRotate)
        .help("Rotate photo")
    }
}

struct BrowserRotationControls: View {
    var model: LibraryModel
    var body: some View {
        HStack(spacing: 2) {
            Button { model.rotateSelection(.counterClockwise) } label: {
                Label("Rotate Selected Photos Left", systemImage: "rotate.left")
            }
            Button { model.rotateSelection(.clockwise) } label: {
                Label("Rotate Selected Photos Right", systemImage: "rotate.right")
            }
        }
        .disabled(!model.canRotate)
        .help("Rotate selected photos")
    }
}

struct ThumbnailRotationProgressView: View {
    var model: LibraryModel
    private var progress: ThumbnailRotationProgress? { model.thumbnailRotationProgress }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.isFixingThumbnailRotations
                 ? "Fixing Thumbnail Rotations"
                 : "Rotating Thumbnail Previews")
                .font(.headline)
            if let progress {
                ProgressView(value: progress.itemProgress, total: 1)
                    .animation(.linear(duration: 0.18), value: progress.itemProgress)
                Text(status(progress)).foregroundStyle(.secondary)
                activityLog(progress.activity)
            }
            HStack {
                Spacer()
                Button(progress?.stage == .finished ? "Done" : "Cancel") {
                    model.dismissThumbnailRotation()
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(progress?.stage != .finished)
    }

    private func activityLog(_ entries: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
                .textSelection(.enabled)
            }
            .frame(height: 190)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.5)))
            .onAppear { scrollToLatest(entries, proxy: proxy) }
            .onChange(of: entries.count) { _, _ in scrollToLatest(entries, proxy: proxy) }
        }
        .accessibilityLabel("Thumbnail rotation activity log")
    }

    private func scrollToLatest(_ entries: [String], proxy: ScrollViewProxy) {
        guard !entries.isEmpty else { return }
        withAnimation { proxy.scrollTo(entries.count - 1, anchor: .bottom) }
    }

    private func status(_ progress: ThumbnailRotationProgress) -> String {
        if progress.stage == .finished {
            return progress.failures.isEmpty
                ? "Finished \(progress.completedItems) of \(progress.totalItems)."
                : "Finished with \(progress.failures.count) failure(s)."
        }
        let item = progress.itemID.map { " photo \($0)" } ?? ""
        if let detail = progress.detail, let itemID = progress.itemID {
            return "\(detail) for photo \(itemID) · \(progress.completedItems) of \(progress.totalItems) complete"
        }
        return "\(progress.stage.rawValue.capitalized)\(item) · \(progress.completedItems) of \(progress.totalItems) complete"
    }
}

struct InfoPanelToolbarControl: View {
    @EnvironmentObject private var infoPanel: InfoPanelModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button(action: toggle) {
            Label(infoPanel.isVisible ? "Hide Info" : "Show Info",
                  systemImage: infoPanel.isVisible ? "info.circle.fill" : "info.circle")
        }
        .help(infoPanel.isVisible ? "Hide Info (Cmd+I)" : "Show Info (Cmd+I)")
    }

    private func toggle() {
        if infoPanel.isVisible {
            dismissWindow(id: InfoPanelScene.id)
        } else {
            openWindow(id: InfoPanelScene.id)
        }
    }
}

struct ViewerToolbarTitle: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    @ObservedObject private var status: ViewerStatusModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewer: PhotoViewerPresentation) {
        self.viewer = viewer
        status = viewer.statusModel
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(viewer.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text([viewer.dateText, status.status.short].filter { !$0.isEmpty }.joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
            ViewerProgressBar(model: status, reduceMotion: reduceMotion)
                .padding(.top, 2)
                .padding(.horizontal, 12)
        }
        .frame(minWidth: 100, idealWidth: 270, maxWidth: 360)
        .help(status.status.help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(status.status.help)
    }
}

struct LibraryCommands: Commands {
    @Bindable var model: LibraryModel
    @Bindable var activity: ActivityCenter
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var infoPanel: InfoPanelModel
    @ObservedObject var filter: LibraryFilterModel
    @ObservedObject var timelineSectionLoad: TimelineSectionLoadModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button { model.rotateSelection(.counterClockwise) } label: {
                Label("Rotate Photo Left", systemImage: "rotate.left")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canRotate)
            Button { model.rotateSelection(.clockwise) } label: {
                Label("Rotate Photo Right", systemImage: "rotate.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canRotate)
            Divider()
            Button { model.rotateThumbnailPreviews(.counterClockwise) } label: {
                Label("Rotate Thumbnail Previews Left…", systemImage: "rotate.left")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canRotateThumbnails || model.thumbnailRotationProgress != nil)
            Button { model.rotateThumbnailPreviews(.clockwise) } label: {
                Label("Rotate Thumbnail Previews Right…", systemImage: "rotate.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canRotateThumbnails || model.thumbnailRotationProgress != nil)
            Divider()
            Button { model.fixThumbnailRotations() } label: {
                Label("Fix Thumbnail Rotations…", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canRotateThumbnails || model.thumbnailRotationProgress != nil)
        }
        CommandGroup(after: .toolbar) {
            Button(activity.isPresented ? "Hide Activity" : "Show Activity") { activity.togglePresented() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Toggle("Show Filmstrip", isOn: $model.showsFilmstrip)
                .disabled(!model.canCloseViewer)
            Toggle("Show Histogram", isOn: $model.showsHistogram)
                .disabled(!model.canCloseViewer)
            Toggle("Show Highlight Peaking", isOn: $model.showsHighlightPeaking)
                .disabled(!model.canCloseViewer)
            Toggle("Show Focus Edges", isOn: $model.showsFocusEdges)
                .disabled(!model.canCloseViewer)
        }
        CommandMenu("Library") {
            Button("Refresh from NAS") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing || model.isLoading)
            Divider()
            Button("Back") { model.navigateBack() }
                .keyboardShortcut(.cancelAction)
                .disabled(!model.canNavigateBack)
            Divider()
            Button("Increase Thumbnail Size") { preferences.adjustItemsPerRow(by: -1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(preferences.itemsPerRow <= 3)
            Button("Decrease Thumbnail Size") { preferences.adjustItemsPerRow(by: 1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(preferences.itemsPerRow >= 10)
            Divider()
            Toggle("Crop Thumbnails to Square", isOn: $preferences.cropsThumbnailsToSquare)
            Toggle("Always Show Timeline", isOn: $preferences.alwaysShowsTimeline)
            Divider()
            Button("Select Left") { model.performBrowserCommand(.move(.left, extending: false)) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.browserCommandsActive)
            Button("Select Right") { model.performBrowserCommand(.move(.right, extending: false)) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.browserCommandsActive)
            Button("Select Up") { model.performBrowserCommand(.move(.up, extending: false)) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!model.browserCommandsActive)
            Button("Select Down") { model.performBrowserCommand(.move(.down, extending: false)) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!model.browserCommandsActive)
            Button("Extend Selection Left") { model.performBrowserCommand(.move(.left, extending: true)) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .disabled(!model.browserCommandsActive)
            Button("Extend Selection Right") { model.performBrowserCommand(.move(.right, extending: true)) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .disabled(!model.browserCommandsActive)
            Button("Extend Selection Up") { model.performBrowserCommand(.move(.up, extending: true)) }
                .keyboardShortcut(.upArrow, modifiers: [.shift])
                .disabled(!model.browserCommandsActive)
            Button("Extend Selection Down") { model.performBrowserCommand(.move(.down, extending: true)) }
                .keyboardShortcut(.downArrow, modifiers: [.shift])
                .disabled(!model.browserCommandsActive)
            Button("Select All") { model.performBrowserCommand(.selectAll) }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!model.browserCommandsActive)
            Button(model.canCloseViewer ? "Close Viewer" : "Open Selected Photo") {
                if model.canCloseViewer { model.closeViewer() }
                else { model.performBrowserCommand(.openSelected) }
            }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.canCloseViewer && !model.canOpenSelectedPhoto)
            Divider()
            Button("New Album…") { model.beginAlbumOperation(.create) }
                .disabled(!model.canManageAlbumSelection)
            Button("Add to Album…") { model.beginAlbumOperation(.add) }
                .disabled(!model.canManageAlbumSelection)
            if model.canRemoveAlbumSelection {
                Button("Remove from Album") { model.beginAlbumOperation(.remove) }
            }
            Divider()
            Button("Delete…") { model.beginItemDeletion() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!model.canDeleteSelection)
            Divider()
            Button("Toggle Favorite") { model.toggleSelectionFavorite() }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!model.canToggleFavorite)
            Menu("Rating") {
                ForEach(0...PhotoAnnotations.maximumRating, id: \.self) { rating in
                    Button(LibraryModel.ratingTitle(rating)) { model.setSelectionRating(rating) }
                        .keyboardShortcut(KeyEquivalent(Character(String(rating))), modifiers: [])
                }
            }
            .disabled(!model.canAnnotate)
            Button("Add Tag…") { model.promptAddTag() }
                .disabled(!model.canAnnotate)
            Button("Remove Tag…") { model.promptRemoveTag() }
                .disabled(!model.canRemoveTag)
            Divider()
            Button(infoPanel.isVisible ? "Hide Info" : "Show Info") {
                if infoPanel.isVisible {
                    dismissWindow(id: InfoPanelScene.id)
                } else {
                    openWindow(id: InfoPanelScene.id)
                }
            }
            .keyboardShortcut("i", modifiers: [.command])
            Divider()
            Button("Download Thumbnails…") { openWindow(id: "thumbnail-download") }
                .disabled(model.snapshot(for: .library(.personal))?.timeline.days.isEmpty != false || model.repository == nil ||
                          !model.timelineVerified(for: .library(.personal)))
            Divider()
            Button("Load All Timeline Sections") {
                if timelineSectionLoad.prepare() {
                    openWindow(id: "timeline-section-load")
                }
            }
            .disabled(!timelineSectionLoad.canPresent)
        }
    }
}

/// Filmstrip, histogram, highlight peaking and focus-edge overlays in their own glass pill,
/// separate from the viewer's action buttons.
struct ViewerOverlayControls: View {
    var model: LibraryModel

    var body: some View {
        HStack(spacing: 0) {
            Button { model.showsFilmstrip.toggle() } label: {
                Label(model.showsFilmstrip ? "Hide Filmstrip" : "Show Filmstrip",
                      systemImage: model.showsFilmstrip ? "film.fill" : "film")
                    .labelStyle(.iconOnly)
                        .frame(width: 34, height: ToolbarMetrics.controlHeight)
                        .contentShape(Rectangle())
                    .foregroundStyle(model.showsFilmstrip ? Color.accentColor : Color.primary)
            }
            .help(model.showsFilmstrip ? "Hide Filmstrip" : "Show Filmstrip")
            .accessibilityLabel(model.showsFilmstrip ? "Hide Filmstrip" : "Show Filmstrip")
            Button { model.showsHistogram.toggle() } label: {
                Label(model.showsHistogram ? "Hide Histogram" : "Show Histogram",
                      systemImage: "chart.bar.xaxis")
                    .labelStyle(.iconOnly)
                        .frame(width: 34, height: ToolbarMetrics.controlHeight)
                        .contentShape(Rectangle())
                    .foregroundStyle(model.showsHistogram ? Color.accentColor : Color.primary)
            }
            .help(model.showsHistogram ? "Hide Histogram" : "Show Histogram")
            .accessibilityLabel(model.showsHistogram ? "Hide Histogram" : "Show Histogram")
            Button { model.showsHighlightPeaking.toggle() } label: {
                Label(model.showsHighlightPeaking ? "Hide Highlight Peaking" : "Show Highlight Peaking",
                      systemImage: "circle.lefthalf.striped.horizontal")
                    .labelStyle(.iconOnly)
                        .frame(width: 34, height: ToolbarMetrics.controlHeight)
                        .contentShape(Rectangle())
                    .foregroundStyle(model.showsHighlightPeaking ? Color.accentColor : Color.primary)
            }
            .help(model.showsHighlightPeaking ? "Hide Highlight Peaking" : "Show Highlight Peaking")
            .accessibilityLabel(model.showsHighlightPeaking ? "Hide Highlight Peaking" : "Show Highlight Peaking")
            Button { model.showsFocusEdges.toggle() } label: {
                Label(model.showsFocusEdges ? "Hide Focus Edges" : "Show Focus Edges",
                      systemImage: "scope")
                    .labelStyle(.iconOnly)
                        .frame(width: 34, height: ToolbarMetrics.controlHeight)
                        .contentShape(Rectangle())
                    .foregroundStyle(model.showsFocusEdges ? Color.accentColor : Color.primary)
            }
            .help(model.showsFocusEdges ? "Hide Focus Edges" : "Show Focus Edges")
            .accessibilityLabel(model.showsFocusEdges ? "Hide Focus Edges" : "Show Focus Edges")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(height: ToolbarMetrics.controlHeight)
        .glassEffect(.regular, in: Capsule())
    }
}
