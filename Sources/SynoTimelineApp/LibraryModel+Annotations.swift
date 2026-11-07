import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// Star ratings and tags for the viewer photo or the browser selection.
extension LibraryModel {
    /// What a menu needs to offer and run rating and tag edits on one target.
    struct AnnotationTarget {
        let collection: PhotoCollectionDescriptor
        /// The rating every target item shares, when already known.
        let currentRating: Int?
        /// Whether the target carries any tag, when known without resolving it.
        var hasTags: Bool? = nil
        let resolve: () async -> SelectionAnnotationAction?
    }

    private enum AnnotationRequest {
        case edit(PhotoAnnotationEdit)
        case newTag(String)

        var activityKind: ActivityKind {
            switch self {
            case .edit(.rating(let rating)): .rating(rating)
            case .edit(.addTags(let tags)): .addTags(tags.map(\.name))
            case .edit(.removeTags(let tags)): .removeTags(tags.map(\.name))
            case .newTag(let name): .newTag(name)
            }
        }

        var actionName: String {
            switch self {
            case .edit(.rating): "Rating"
            case .edit(.removeTags): "Remove Tag"
            case .edit(.addTags), .newTag: "Add Tag"
            }
        }
    }

    var canAnnotate: Bool {
        if let activeViewer {
            return capabilities(for: activeViewer.collection).allowsSpaceItemActions && activeViewer.canAnnotate && !annotationBusy
        }
        return browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsSpaceItemActions &&
            browserHasSelection && timelineVerified(for: browserCommandSnapshot.collection) &&
            !annotationBusy
    }

    /// The browser snapshot the Info panel may act on: it must still describe the panel's selection.
    func infoPanelSnapshot(collection: PhotoCollectionDescriptor, selection: IndexSet) -> BrowserCommandSnapshot? {
        guard let snapshot = lastActiveBrowserSnapshot, snapshot.collection == collection,
              snapshot.selectedOrdinals == selection else { return nil }
        return snapshot
    }

    func canRateFromInfoPanel(viewerActive: Bool, collection: PhotoCollectionDescriptor, selection: IndexSet) -> Bool {
        guard !annotationBusy else { return false }
        if viewerActive {
            guard let viewer = activeViewer else { return false }
            return capabilities(for: viewer.collection).allowsSpaceItemActions && viewer.canAnnotate
        }
        return capabilities(for: collection).allowsSpaceItemActions && timelineVerified(for: collection) &&
            infoPanelSnapshot(collection: collection, selection: selection) != nil
    }

    /// Sets the rating of the Info panel's single item. The panel is its own key window,
    /// so this does not depend on the browser menu-bar command state.
    func setInfoPanelRating(_ rating: Int, viewerActive: Bool, collection: PhotoCollectionDescriptor, selection: IndexSet) {
        guard canRateFromInfoPanel(viewerActive: viewerActive, collection: collection, selection: selection) else { return }
        if viewerActive, let viewer = activeViewer {
            run(.edit(.rating(rating)), on: viewerAnnotationTarget(viewer))
        } else if let snapshot = infoPanelSnapshot(collection: collection, selection: selection),
                  let target = browserAnnotationTarget(snapshot) {
            run(.edit(.rating(rating)), on: target)
        }
    }

    /// False only when the viewer photo is known to have no tags to remove.
    var canRemoveTag: Bool {
        guard canAnnotate else { return false }
        if let viewer = activeViewer, let item = viewer.state?.item { return !item.tags.isEmpty }
        return true
    }

    // MARK: Targets

    /// The viewer photo, or the browser selection when no viewer is open.
    private var menuBarAnnotationTarget: AnnotationTarget? {
        if let viewer = activeViewer {
            return AnnotationTarget(collection: viewer.collection, currentRating: viewer.state?.item?.rating,
                         hasTags: viewer.state?.item.map { !$0.tags.isEmpty }) { viewer.annotationAction() }
        }
        guard let repository else { return nil }
        let snapshot = browserCommandSnapshot
        return AnnotationTarget(collection: snapshot.collection, currentRating: nil) { [weak self] in
            await self?.resolveAnnotation(snapshot, repository: repository)
        }
    }

    func browserAnnotationTarget(_ snapshot: BrowserCommandSnapshot) -> AnnotationTarget? {
        guard let repository else { return nil }
        return AnnotationTarget(collection: snapshot.collection, currentRating: nil) { [weak self] in
            await self?.resolveAnnotation(snapshot, repository: repository)
        }
    }

    func viewerAnnotationTarget(_ viewer: PhotoViewerPresentation) -> AnnotationTarget {
        AnnotationTarget(collection: viewer.collection, currentRating: viewer.state?.item?.rating,
                         hasTags: viewer.state?.item.map { !$0.tags.isEmpty }) { viewer.annotationAction() }
    }

    private func resolveAnnotation(_ snapshot: BrowserCommandSnapshot,
                                   repository: CachedPhotosRepository) async -> SelectionAnnotationAction? {
        guard snapshot.active, let selection = snapshot.captureSelection(timeline: snapshots[snapshot.collection]) else { return nil }
        return await SelectionAnnotationResolver(repository: repository).resolve(selection)
    }

    // MARK: Menu bar commands

    func setSelectionRating(_ rating: Int) {
        guard canAnnotate, let target = menuBarAnnotationTarget else { return }
        run(.edit(.rating(rating)), on: target)
    }

    func promptAddTag() {
        guard canAnnotate, let target = menuBarAnnotationTarget else { return }
        Task { [weak self] in
            guard let self else { return }
            let suggestions = await availableTags(for: target.collection).map(\.name)
            guard let name = promptForTagName(suggestions: suggestions) else { return }
            run(.newTag(name), on: target)
        }
    }

    func promptRemoveTag() {
        guard canAnnotate, let target = menuBarAnnotationTarget else { return }
        Task { [weak self] in
            guard let self, let action = await target.resolve() else { return }
            let present = action.presentTags
            guard !present.isEmpty else {
                reportNotStarted("Remove Tag", error: .invalidInput("The selected photos have no tags."))
                return
            }
            guard let tag = promptForTagToRemove(present) else { return }
            run(.edit(.removeTags([tag])), on: AnnotationTarget(collection: target.collection, currentRating: nil) { action })
        }
    }

    // MARK: Context menus

    /// Adds Rating, Add Tag and Remove Tag submenus.
    func addAnnotationMenus(to menu: NSMenu, target: AnnotationTarget) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        let rating = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu(title: "Rating")
        for value in 0...PhotoAnnotations.maximumRating {
            let item = PhotoDownloadMenuItem(title: Self.ratingTitle(value)) { [weak self] in
                self?.run(.edit(.rating(value)), on: target)
            }
            if target.currentRating == value { item.state = .on }
            ratingMenu.addItem(item)
            if value == 0 { ratingMenu.addItem(.separator()) }
        }
        rating.submenu = ratingMenu
        menu.addItem(rating)

        let add = NSMenuItem(title: "Add Tag", action: nil, keyEquivalent: "")
        let addMenu = NSMenu(title: "Add Tag")
        @MainActor func addNewTagItem() {
            addMenu.addItem(PhotoDownloadMenuItem(title: "New Tag…") { [weak self] in
                guard let self else { return }
                Task {
                    let suggestions = await self.availableTags(for: target.collection).map(\.name)
                    if let name = self.promptForTagName(suggestions: suggestions) { self.run(.newTag(name), on: target) }
                }
            })
        }
        addNewTagItem()
        add.submenu = addMenu
        menu.addItem(add)
        Task { [weak self] in
            guard let self else { return }
            let tags = await availableTags(for: target.collection)
            guard !tags.isEmpty else { return }
            addMenu.addItem(.separator())
            for tag in tags {
                addMenu.addItem(PhotoDownloadMenuItem(title: tag.name) { [weak self] in
                    self?.run(.edit(.addTags([tag])), on: target)
                })
            }
        }

        let remove = NSMenuItem(title: "Remove Tag", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu(title: "Remove Tag")
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        removeMenu.addItem(loading)
        remove.submenu = removeMenu
        menu.addItem(remove)
        if target.hasTags == false {
            remove.submenu = nil
            remove.isEnabled = false
            return
        }
        Task { [weak self] in
            let action = await target.resolve()
            removeMenu.removeAllItems()
            let present = action?.presentTags ?? []
            guard let action, !present.isEmpty else {
                // Nothing to remove: disable the item itself rather than listing a placeholder.
                remove.submenu = nil
                remove.isEnabled = false
                return
            }
            let resolved = AnnotationTarget(collection: target.collection, currentRating: nil) { action }
            for tag in present {
                removeMenu.addItem(PhotoDownloadMenuItem(title: tag.name) { [weak self] in
                    self?.run(.edit(.removeTags([tag])), on: resolved)
                })
            }
        }
    }

    static func ratingTitle(_ rating: Int) -> String {
        rating == 0 ? "No Rating" : String(repeating: "★", count: rating)
    }

    // MARK: Running

    private func run(_ request: AnnotationRequest, on target: AnnotationTarget) {
        guard !annotationBusy, let repository else { return }
        annotationBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { annotationBusy = false }
            guard let action = await target.resolve() else {
                reportUnverified(request.actionName)
                return
            }
            await runAnnotation(request, action: action, repository: repository)
        }
    }

    /// Sends a resolved edit as a tracked activity. Ratings and tag changes are absolute, so their
    /// failed photos can be retried; creating a tag is not retried.
    private func runAnnotation(_ request: AnnotationRequest, action: SelectionAnnotationAction,
                               repository: CachedPhotosRepository) async {
        let items = action.items.map { ActivityItem(photo: $0, collection: action.collection) }
        var retry: ActivityRetry?
        if case .edit = request {
            retry = { [weak self] retried in
                let ids = Set(retried.compactMap(\.photoID))
                guard let self, !ids.isEmpty else { return false }
                Task { await self.runAnnotation(request, action: action.restricted(to: ids), repository: repository) }
                return true
            }
        }
        let handle = activity.begin(request.activityKind, items: items, totalCount: max(action.itemIDs.count, 1), retry: retry)
        do {
            switch request {
            case .edit(let edit): try await repository.annotate(action, edit: edit)
            case .newTag(let name): try await repository.addNewTag(named: name, to: action)
            }
            handle.succeed()
        } catch {
            handle.fail(error, operation: "Ratings and tags")
        }
    }

    /// The space's tags, from the cached-first Tags index. Empty when the collection's
    /// items can belong to more than one space.
    func availableTags(for collection: PhotoCollectionDescriptor) async -> [PhotoTag] {
        guard let repository, let space = capabilities(for: collection).source.contentScope.space else { return [] }
        for await event in await repository.collectionIndex(.tag, space: space) {
            guard case .value(let entries, _) = event else { return [] }
            return entries.map { PhotoTag(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return []
    }

    // MARK: Prompts

    private func promptForTagName(suggestions: [String]) -> String? {
        let alert = NSAlert()
        alert.messageText = "Add Tag"
        alert.informativeText = "Choose an existing tag or enter a new name."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.addItems(withObjectValues: suggestions)
        field.completes = true
        field.numberOfVisibleItems = 10
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func promptForTagToRemove(_ tags: [PhotoTag]) -> PhotoTag? {
        let alert = NSAlert()
        alert.messageText = "Remove Tag"
        alert.informativeText = "Remove this tag from the selected photos."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: tags.map(\.name))
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn, tags.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return tags[popup.indexOfSelectedItem]
    }
}
