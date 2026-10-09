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

struct BrowserFavoriteControl: View {
    @ObservedObject var model: LibraryModel
    let collection: PhotoCollectionDescriptor

    var body: some View {
        Button(action: model.toggleSelectionFavorite) {
            Label("Toggle Favorite", systemImage: "heart")
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
        .help(viewer.rotationFailure ?? "Rotate photo")
    }
}

struct BrowserRotationControls: View {
    @ObservedObject var model: LibraryModel
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
    @ObservedObject var model: LibraryModel
    private var progress: ThumbnailRotationProgress? { model.thumbnailRotationProgress }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rotating Thumbnail Previews").font(.headline)
            if let progress {
                ProgressView(value: Double(progress.completedItems),
                             total: Double(max(1, progress.totalItems)))
                Text(status(progress)).foregroundStyle(.secondary)
                if !progress.failures.isEmpty {
                    ScrollView {
                        Text(progress.failures.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.frame(maxHeight: 120)
                }
            }
            HStack {
                Spacer()
                Button(progress?.stage == .finished ? "Done" : "Cancel") {
                    model.dismissThumbnailRotation()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(progress?.stage != .finished)
    }

    private func status(_ progress: ThumbnailRotationProgress) -> String {
        if progress.stage == .finished {
            return progress.failures.isEmpty
                ? "Finished \(progress.completedItems) of \(progress.totalItems)."
                : "Finished with \(progress.failures.count) failure(s)."
        }
        let item = progress.itemID.map { " photo \($0)" } ?? ""
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

struct ConnectionToolbarItem: View {
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
        .frame(height: ToolbarMetrics.controlHeight)
        .padding(.horizontal, 4)
        .font(.caption)
    }
}

struct LibraryCommands: Commands {
    @ObservedObject var model: LibraryModel
    @ObservedObject var infoPanel: InfoPanelModel
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
            .disabled(!model.canRotate || model.thumbnailRotationProgress != nil)
            Button { model.rotateThumbnailPreviews(.clockwise) } label: {
                Label("Rotate Thumbnail Previews Right…", systemImage: "rotate.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canRotate || model.thumbnailRotationProgress != nil)
        }
        CommandMenu("Library") {
            Button("Back") { model.navigateBack() }
                .keyboardShortcut(.cancelAction)
                .disabled(!model.canNavigateBack)
            Divider()
            Button("Increase Thumbnail Size") { model.adjustItemsPerRow(by: -1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.itemsPerRow <= 3)
            Button("Decrease Thumbnail Size") { model.adjustItemsPerRow(by: 1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.itemsPerRow >= 10)
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
            Button("Toggle Favorite") { model.toggleSelectionFavorite() }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!model.canToggleFavorite)
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
                .disabled(model.snapshot?.timeline.days.isEmpty != false || model.repository == nil ||
                          !model.timelineVerified)
        }
    }
}
