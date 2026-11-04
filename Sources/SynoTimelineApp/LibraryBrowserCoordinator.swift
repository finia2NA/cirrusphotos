import AppKit
import Combine
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

/// Hosts visible rows, owns scroll intent and page demand, and bridges AppKit input
/// to SwiftUI callbacks. Selection input and menus live in extensions.
extension LibraryBrowserScrollView {
    @MainActor
    final class Coordinator {
        weak var scroll: NSScrollView?
        weak var document: FlippedDocumentView?
        var observer: NSObjectProtocol?
        var index: LibraryIndex?
        var timelineSnapshot: TimelineSnapshot?
        var selectionAuthority: PhotoSelectionAuthority?
        var sourceAlbumID: Int64?
        var allowsPersonalActions = true
        var allowsDownloads = true
        var allowsFileDrag = true
        var geometry: LibraryViewportGeometry?
        var header: BrowserHeaderConfiguration?
        var emptyContent: AnyView?
        var emptyRevision = 0
        var window: LibraryPageWindow?
        var pages: [Int: LibraryPage] = [:]
        var errors: [Int: String] = [:]
        var pageSignatures: [Int: Int] = [:]
        var rowRevisions: [Int: Int] = [:]
        var viewRevision = 0
        var hosts: [String: NSHostingView<AnyView>] = [:]
        var hostRevisions: [String: (Int, Int)] = [:]
        /// Visible photo cells by ordinal, and hidden cells ready for reuse.
        var cells: [Int: BrowserPhotoCellView] = [:]
        var cellPool: [BrowserPhotoCellView] = []
        var cellRevisions: [Int: CellRevision] = [:]
        /// Set by an animated square toggle: the next cell layout animates frames.
        var animateCellFrames = false
        var presentationObserver: AnyCancellable?
        static let cellPoolLimit = 160
        var selectionFramesKey: (rows: UUID, indexes: IndexSet)?
        /// Running counts reported by the "Viewport layout" signpost.
        var hostsCreated = 0
        var hostsUpdated = 0
        var eventTask: Task<Void, Never>?
        var demandTask: Task<Void, Never>?
        var revision = -1
        var filterMembership: [[Int64]]?
        var rebasing = false
        var retryRevision = 0
        var allowNetwork = false
        var thumbnailSize: ThumbnailSize = .m
        var repository: CachedPhotosRepository?
        var collection: PhotoCollectionDescriptor = .library(.personal)
        var onVisibleDay: ((String) -> Void)?
        var lastVisibleDay: String?
        var unavailableOffline = false
        var colorScheme: ColorScheme = .light
        var onRetry: (() -> Void)?
        var onOpenPhoto: ((PhotoViewerOpenRequest) -> Void)?
        var onAlbumMenu: ((NSMenu, BrowserCommandSnapshot) -> Void)?
        var onDownload: ((BrowserCommandSnapshot, PhotoDownloadKind, Bool) -> Void)?
        var onDelete: ((BrowserCommandSnapshot) -> Void)?
        var onEdit: ((BrowserCommandSnapshot, URL) -> Void)?
        var onSelectionStateChanged: ((BrowserSelectionState) -> Void)?
        var onCommandStateChanged: ((BrowserCommandSnapshot, ((BrowserSelectionCommand) -> Void)?) -> Void)?
        var onRestorationAnchorChanged: ((PhotoTimelineRestorationAnchor) -> Void)?
        var onFilterEdgeDemand: (([Int], LibraryFilterScanDirection, UInt64) -> Void)?
        var demandedVisible: [Int] = []
        var demandedPrefetch: [Int] = []
        var suppressFeedback = false
        var scrollIntent = BrowserScrollIntentCoordinator()
        var feedbackTask: Task<Void, Never>?
        var restorationFeedbackTask: Task<Void, Never>?
        var pendingReveal: (id: UUID, completion: (CGRect?) -> Void)?
        var selectionState = BrowserSelectionState()
        var selection: LibrarySelection {
            get { selectionState.selection }
            set { selectionState.selection = newValue }
        }
        let presentation = BrowserThumbnailPresentation(cropsToSquare: false)
        let thumbnailFailures = ThumbnailFailureRegistry()
        var presentationRequest = 0
        var reduceMotion = false
        let commandOwner = UUID()
        var pointer = BrowserPointerInteraction()
        var pointerShift = false
        var pointerOption = false
        var marqueeSelection: BrowserMarqueeSelection?
        var autoscrollTask: Task<Void, Never>?
        var pendingOpen: BrowserPendingOpen?
        var selectionEpoch: UInt64 = 0
        var selectAfterRevealItemID: Int64?
        weak var sourceProxy: NSView?

        func configure(_ input: LibraryBrowserScrollView) {
            guard let scroll else { return }
            let reusesWindow = collection == input.collection && repository === input.repository && window != nil
            collection = input.collection
            timelineSnapshot = input.snapshot
            selectionAuthority = input.authority
            sourceAlbumID = input.sourceAlbumID
            allowsPersonalActions = input.allowsPersonalActions
            allowsDownloads = input.allowsDownloads
            allowsFileDrag = input.allowsFileDrag
            onVisibleDay = input.onVisibleDay
            onRetry = input.onRetry
            onOpenPhoto = input.onOpenPhoto
            onAlbumMenu = input.onAlbumMenu
            onDownload = input.onDownload
            onDelete = input.onDelete
            onEdit = input.onEdit
            onSelectionStateChanged = input.onSelectionStateChanged
            onCommandStateChanged = input.onCommandStateChanged
            onRestorationAnchorChanged = input.onRestorationAnchorChanged
            onFilterEdgeDemand = input.onFilterEdgeDemand
            (scroll as? TimelineScrollView)?.userScroll = { [weak self] direction, generation in
                self?.userDidScroll(direction, generation: generation)
            }
            scrollIntent.captureRestoration(input.restorationAnchor)
            input.bridge.revealHandler = { [weak self] request, completion in
                self?.reveal(request, completion: completion)
            }
            input.bridge.focusHandler = { [weak self] in
                (self?.scroll as? TimelineScrollView)?.focusTimeline()
            }
            repository = input.repository
            let insetAnchor = geometry?.anchor(at: visibleTop(in: scroll))
            let oldInsets = scroll.contentInsets
            let horizontalInset = CGFloat(FixedPhotoGrid.gap)
            let insets = NSEdgeInsets(top: input.contentTopInset, left: horizontalInset,
                                      bottom: 0, right: horizontalInset)
            scroll.contentInsets = insets
            let insetsChanged = abs(oldInsets.top - insets.top) > 0.5 ||
                abs(oldInsets.left - insets.left) > 0.5 ||
                abs(oldInsets.right - insets.right) > 0.5 ||
                abs(oldInsets.bottom - insets.bottom) > 0.5
            if thumbnailSize != input.thumbnailSize { viewRevision += 1 }
            thumbnailSize = input.thumbnailSize
            if colorScheme != input.colorScheme { viewRevision += 1 }
            colorScheme = input.colorScheme
            reduceMotion = input.reduceMotion
            let width = availableWidth(in: scroll)
            if header?.identity != input.header?.identity { viewRevision += 1 }
            header = input.header
            emptyContent = input.emptyContent
            if emptyContent != nil { emptyRevision += 1 }
            let headerHeight = header.map { Double($0.height(width)) } ?? 0
            let rebuilding = revision != input.revision
            if rebuilding {
                let oldIndex = index
                let previous = geometry?.anchor(at: visibleTop(in: scroll))
                cancelPointerInteraction()
                pendingOpen = nil
                let preserveFilter = reusesWindow && collection.isLibraryFilter &&
                    filterMembership != nil && input.filterMembership != nil
                if preserveFilter {
                    eventTask?.cancel()
                    demandTask?.cancel()
                    demandedVisible = []
                    demandedPrefetch = []
                    rebasing = true
                } else if reusesWindow { detachWindowEvents() } else { stopWindow() }
                let newIndex = LibraryIndex(snapshot: input.snapshot)
                index = newIndex
                geometry = LibraryViewportGeometry(index: newIndex, width: width,
                                                   itemsPerRow: input.itemsPerRow,
                                                   cropsThumbnailsToSquare: input.cropsThumbnailsToSquare,
                                                   contentOrigin: headerHeight)
                snapPresentation(input.cropsThumbnailsToSquare)
                if preserveFilter, let oldMembership = filterMembership, let newMembership = input.filterMembership {
                    pages = FilterPageRebaser.rebase(pages: pages, membership: newMembership, sourceAuthority: input.filterAuthority)
                    geometry?.reconcile(pages: pages)
                    selectionState.rebaseFilter(to: newIndex.fingerprint, oldMembership: oldMembership,
                                                newMembership: newMembership)
                    pageSignatures = Dictionary(uniqueKeysWithValues: pages.map { ($0.key, Self.signature($0.value)) })
                    errors.removeAll()
                } else {
                    selectionState = input.selectionState
                    selectionState.bind(to: newIndex.fingerprint)
                }
                filterMembership = input.filterMembership
                publishSelection()
                revision = input.revision
                allowNetwork = input.allowNetwork
                if !reusesWindow {
                    window = LibraryPageWindow(repository: input.repository, collection: input.collection, maximumPages: 8)
                }
                updateDocumentHeight()
                if let geometry, let target = scrollIntent.rebuild(index: newIndex, geometry: geometry,
                    previousIndex: oldIndex, visibleAnchor: previous, timelineVerified: input.allowNetwork) {
                    scrollTo(target)
                }
                startEvents(rebasingTo: newIndex, filterMembership: preserveFilter ? input.filterMembership : nil,
                            filterAuthority: preserveFilter ? input.filterAuthority : nil)
            } else {
                if allowNetwork != input.allowNetwork {
                    allowNetwork = input.allowNetwork
                    if let index {
                        scrollIntent.timelineDidVerify(index: index, verified: input.allowNetwork)
                    }
                    viewRevision += 1
                    demandedVisible = []
                    demandedPrefetch = []
                }
                if let current = geometry {
                    let widthChanged = abs(current.width - width) > 0.5
                    let columnsChanged = current.itemsPerRow != input.itemsPerRow
                    let presentationChanged = current.cropsThumbnailsToSquare != input.cropsThumbnailsToSquare
                    if widthChanged || columnsChanged || presentationChanged || abs(current.contentOrigin - headerHeight) > 0.5 {
                        let preserved = visiblePhotoAnchor(current, in: scroll)
                        geometry?.setLayout(width: width, itemsPerRow: input.itemsPerRow,
                                            cropsThumbnailsToSquare: input.cropsThumbnailsToSquare,
                                            contentOrigin: headerHeight, pages: pages)
                        selection.endExtension()
                        cancelPointerInteraction()
                        pendingOpen = nil
                        if widthChanged || columnsChanged {
                            // Window resizing and items-per-row changes stay instant; the
                            // presentation snaps and rows rebuild with final geometry.
                            viewRevision += 1
                            snapPresentation(input.cropsThumbnailsToSquare)
                        } else {
                            // A clean user-driven square preference change only morphs the
                            // visible frame inside the stable slots, so no row is rebuilt.
                            applySquarePresentation(input.cropsThumbnailsToSquare)
                        }
                        updateDocumentHeight()
                        if let preserved, let target = geometry?.y(for: preserved.anchor) { scrollTo(target - preserved.distance) }
                    }
                }
            }
            updateDocumentHeight()
            if unavailableOffline != input.unavailableOffline {
                unavailableOffline = input.unavailableOffline
                viewRevision += 1
            }
            if retryRevision != input.retryRevision {
                retryRevision = input.retryRevision
                errors.removeAll()
                demandedVisible = []
                demandedPrefetch = []
                viewRevision += 1
            }
            if let request = input.jumpToDay, let index, let geometry,
               let target = scrollIntent.jump(id: request.id, dayID: request.dayID,
                                              index: index, geometry: geometry) {
                cancelSupersededReveal()
                pendingOpen = nil
                cancelPointerInteraction()
                scrollTo(target)
            } else if insetsChanged, !rebuilding, let insetAnchor,
                      let target = geometry?.y(for: insetAnchor) {
                scrollTo(target)
            }
            viewportChanged()
            publishCommandState(active: (scroll as? TimelineScrollView)?.browserCommandContextActive == true)
        }

        /// Applies the square preference with a short ease-in-out morph. Geometry is
        /// already final; the next cell layout animates each visible frame while images
        /// aspect-fill, and the presentation settles on its rest gravity afterwards.
        func applySquarePresentation(_ cropsToSquare: Bool) {
            presentationRequest &+= 1
            observePresentation()
            let animated = !reduceMotion
            presentation.setCropsToSquare(cropsToSquare, animated: animated)
            animateCellFrames = animated
            updateCellPresentation()
        }

        /// Applies the square preference immediately, invalidating any pending animated
        /// request. Used for initial construction, relayout, and Reduce Motion.
        func snapPresentation(_ cropsToSquare: Bool) {
            presentationRequest &+= 1
            observePresentation()
            presentation.setCropsToSquare(cropsToSquare, animated: false)
            animateCellFrames = false
            updateCellPresentation()
        }

        /// The transition end changes `fillsFrame`; cells pick it up after the change.
        func observePresentation() {
            guard presentationObserver == nil else { return }
            presentationObserver = presentation.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateCellPresentation() }
            }
        }

        func updateCellPresentation() {
            let fills = presentation.fillsFrame
            for cell in cells.values { cell.fillsFrame = fills }
        }

        func updateCellSelection() {
            for (ordinal, cell) in cells { cell.selected = selection.contains(ordinal) }
        }

        /// Hides a cell and returns it to the pool, keeping keyboard focus in the browser.
        func recycle(_ cell: BrowserPhotoCellView) {
            if cell.window?.firstResponder === cell { (scroll as? TimelineScrollView)?.focusTimeline() }
            cell.resetForReuse()
            cell.isHidden = true
            if cellPool.count < Self.cellPoolLimit { cellPool.append(cell) } else { cell.removeFromSuperview() }
        }

        /// Recycles every visible cell; `detach` also removes pooled cells from the document.
        func removeAllCells(detach: Bool) {
            for cell in cells.values { recycle(cell) }
            cells.removeAll()
            cellRevisions.removeAll()
            if detach {
                cellPool.forEach { $0.removeFromSuperview() }
                cellPool.removeAll()
            }
        }

        func openFromCell(_ ordinal: Int, anchor: PhotoViewerSourceAnchor) {
            guard let item = loadedItem(ordinal) else { return }
            let page = pages[item.sectionIndex]
            let seed = PhotoViewerSeed(sectionIndex: item.sectionIndex, pageOffset: item.pageOffset,
                item: item.photo, page: page?.completeItems, pageVerified: page?.verified ?? item.verified)
            openFromAccessibility(ordinal, request: PhotoViewerOpenRequest(seed: seed, source: anchor))
        }

        /// Shows `item` in a visible cell at `frame`, reusing the cell already showing that
        /// ordinal or a pooled one. Content is re-applied only when rows or view state changed.
        func placeCell(_ item: LibraryViewportGeometry.RowItem, frame: CGRect, geometry: LibraryViewportGeometry,
                       document: NSView, repository: CachedPhotosRepository) {
            let cell: BrowserPhotoCellView
            if let existing = cells[item.ordinal] {
                cell = existing
            } else {
                if let pooled = cellPool.popLast() {
                    cell = pooled
                    cell.frame = frame
                } else {
                    cell = BrowserPhotoCellView(frame: frame)
                    if let overlay = (document as? FlippedDocumentView)?.overlay {
                        document.addSubview(cell, positioned: .below, relativeTo: overlay)
                    } else { document.addSubview(cell) }
                    hostsCreated &+= 1
                }
                cell.isHidden = false
                cells[item.ordinal] = cell
                cellRevisions[item.ordinal] = nil
            }
            let revision = CellRevision(rows: geometry.rowsRevision, view: viewRevision, itemID: item.photo.id)
            if cellRevisions[item.ordinal] != revision {
                cellRevisions[item.ordinal] = revision
                hostsUpdated &+= 1
                let ordinal = item.ordinal
                cell.onSelect = { [weak self] in self?.selectFromAccessibility(ordinal) }
                cell.onCommand = { [weak self] in self?.perform($0) }
                cell.onActivate = { [weak self] anchor in self?.openFromCell(ordinal, anchor: anchor) }
                cell.fillsFrame = presentation.fillsFrame
                cell.configure(BrowserPhotoCellContent(item: item.photo, ordinal: ordinal, repository: repository,
                                                       size: thumbnailSize, allowNetwork: item.verified,
                                                       collection: collection, failures: thumbnailFailures),
                               selected: selection.contains(ordinal))
            }
            if cell.frame != frame {
                if animateCellFrames { cell.animator().frame = frame } else { cell.frame = frame }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            feedbackTask?.cancel()
            restorationFeedbackTask?.cancel()
            emitCurrentRestorationAnchor()
            scrollIntent.stop()
            cancelSupersededReveal()
            selectAfterRevealItemID = nil
            cancelPointerInteraction()
            onCommandStateChanged?(.inactive, nil)
            stopWindow()
            hosts.values.forEach { $0.removeFromSuperview() }
            hosts.removeAll()
            hostRevisions.removeAll()
            removeAllCells(detach: true)
            presentationObserver = nil
        }

        func stopWindow() {
            if let window { Task { await window.cancelAll() } }
            window = nil
            detachWindowEvents()
        }

        func detachWindowEvents() {
            eventTask?.cancel()
            demandTask?.cancel()
            eventTask = nil
            demandTask = nil
            rebasing = false
            pages.removeAll()
            errors.removeAll()
            pageSignatures.removeAll()
            rowRevisions.removeAll()
            demandedVisible = []
            demandedPrefetch = []
            hosts.values.forEach { $0.removeFromSuperview() }
            hosts.removeAll()
            hostRevisions.removeAll()
            removeAllCells(detach: false)
        }

        func startEvents(rebasingTo index: LibraryIndex? = nil, filterMembership: [[Int64]]? = nil, filterAuthority: [[Bool]]? = nil) {
            guard let window else { return }
            eventTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                if let index { await window.rebase(to: index, filterMembership: filterMembership, filterAuthority: filterAuthority) }
                guard !Task.isCancelled else { return }
                if let self, self.window === window {
                    self.rebasing = false
                    self.viewportChanged()
                } else { return }
                for await event in await window.events() {
                    guard let self, !Task.isCancelled else { break }
                    switch event {
                    case .failure(let section, let message):
                        self.errors[section] = message
                        self.rowRevisions[section, default: 0] += 1
                    case .page, .removed: break
                    }
                    // Events use a bounded newest buffer, so reconcile against the authoritative window.
                    let retained = await window.retainedPages()
                    guard !Task.isCancelled, self.window === window else { break }
                    let signposter = SynologyDiagnostics.browserSignposts
                    let applyInterval = signposter.beginInterval("Apply pages", id: signposter.makeSignpostID(),
                                                                 "\(retained.count) pages")
                    defer { signposter.endInterval("Apply pages", applyInterval) }
                    let anchor = self.scroll.flatMap { scroll in
                        self.geometry?.anchor(at: self.visibleTop(in: scroll))
                    }
                    self.pages = Dictionary(uniqueKeysWithValues: retained.map { ($0.sectionIndex, $0) })
                    let newSignatures = Dictionary(uniqueKeysWithValues: retained.map {
                        ($0.sectionIndex, Self.signature($0))
                    })
                    let newMembership = Dictionary(uniqueKeysWithValues: retained.map {
                        ($0.sectionIndex, Self.membershipSignature($0))
                    })
                    let membershipChanged = self.selectionState.reconcileMembership(newMembership)
                    if membershipChanged {
                        self.pendingOpen = nil
                        self.cancelPointerInteraction()
                        self.publishSelection()
                    }
                    self.persistSelectionState()
                    for (section, signature) in newSignatures where self.pageSignatures[section] != signature {
                        self.rowRevisions[section, default: 0] += 1
                    }
                    self.pageSignatures = newSignatures
                    self.errors = self.errors.filter { self.demandedVisible.contains($0.key) }
                    self.geometry?.reconcile(pages: self.pages)
                    self.refreshMarqueeSelection()
                    self.updateDocumentHeight()
                    if let index = self.index, let geometry = self.geometry {
                        switch self.scrollIntent.reconcile(pages: self.pages, index: index,
                            geometry: geometry, timelineVerified: self.allowNetwork) {
                        case .scroll(let target): self.scrollTo(target)
                        case .reveal(let id, let itemID): self.finishRevealIfPossible(id: id, itemID: itemID)
                        case .settled:
                            if self.selectAfterRevealItemID != nil {
                                self.selection.replace(with: nil)
                                self.selectAfterRevealItemID = nil
                                self.publishSelection()
                            }
                            self.cancelSupersededReveal()
                        case .preserveViewport:
                            if let anchor, let target = geometry.y(for: anchor) { self.scrollTo(target) }
                        }
                    }
                    self.viewportChanged()
                    self.openPendingIfPossible()
                }
            }
        }

        func viewportChanged() {
            guard let scroll, let document else { return }
            let signposter = SynologyDiagnostics.browserSignposts
            let layoutInterval = signposter.beginInterval("Viewport layout", id: signposter.makeSignpostID())
            let createdBefore = hostsCreated, updatedBefore = hostsUpdated
            defer {
                signposter.endInterval("Viewport layout", layoutInterval,
                                       "created \(self.hostsCreated - createdBefore) updated \(self.hostsUpdated - updatedBefore)")
            }
            if let current = geometry {
                let width = availableWidth(in: scroll)
                if abs(current.width - width) > 0.5 {
                    let preserved = visiblePhotoAnchor(current, in: scroll)
                    geometry?.setLayout(width: width, itemsPerRow: current.itemsPerRow,
                                        cropsThumbnailsToSquare: current.cropsThumbnailsToSquare,
                                        contentOrigin: header.map { Double($0.height(width)) } ?? 0, pages: pages)
                    selection.endExtension()
                    cancelPointerInteraction()
                    pendingOpen = nil
                    viewRevision += 1
                    updateDocumentHeight()
                    if let preserved, let target = geometry?.y(for: preserved.anchor) { scrollTo(target - preserved.distance) }
                }
            }
            guard let geometry, let index, let repository else { return }
            let visible = scroll.contentView.bounds
            let y = visibleTop(in: scroll)
            let height = visibleHeight(in: scroll)
            let clipY = Double(visible.minY)
            scrollIntent.viewportMoved(to: clipY)
            cancelSupersededReveal()
            let overscan = min(240, height * 0.35)
            let range = geometry.sliceRange(y: max(0, y - overscan), height: height + 2 * overscan)
            var wanted: Set<String> = []
            var wantedCells: Set<Int> = []
            if animateCellFrames {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = BrowserThumbnailPresentation.transitionDuration
                NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                NSAnimationContext.current.allowsImplicitAnimation = true
            }
            if let header {
                addHost("album-header", frame: CGRect(x: 0, y: 0, width: geometry.width, height: geometry.contentOrigin),
                        content: header.content(repository, geometry.width),
                        revision: (viewRevision, 0), wanted: &wanted, document: document)
            }
            if let emptyContent, geometry.slices.isEmpty {
                addHost("empty", frame: CGRect(x: 0, y: geometry.contentOrigin, width: geometry.width,
                    height: max(240, visibleHeight(in: scroll) - geometry.contentOrigin)),
                    content: emptyContent, revision: (viewRevision, emptyRevision), wanted: &wanted, document: document)
            }
            let visibleSections = geometry.sectionIndices(y: max(0, y - overscan),
                                                          height: height + 2 * overscan)
            for position in range {
                let slice = geometry.slices[position]
                let section = slice.source.sectionIndex
                if slice.heading {
                    addHost("h:\(slice.source.dayID)", frame: CGRect(x: 0, y: slice.y, width: geometry.width, height: 32),
                            content: AnyView(Text(slice.source.dayID).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)),
                            revision: (viewRevision, 0), wanted: &wanted, document: document)
                }
                if let page = pages[section] {
                    if page.slots.count <= slice.source.pageRange.lowerBound {
                        addHost("e:\(slice.source.dayID):\(slice.source.dayRange.lowerBound)",
                                frame: CGRect(x: 0, y: slice.y + (slice.heading ? 38 : 0),
                                              width: geometry.width, height: 28),
                                content: AnyView(HostedPlaceholder(message: "No photos in this section")),
                                revision: (viewRevision, rowRevisions[section] ?? 0),
                                wanted: &wanted, document: document)
                    }
                } else {
                    let message = errors[section] ?? (unavailableOffline ? "Unavailable offline" : "Loading photos…")
                    addHost("p:\(slice.source.dayID):\(slice.source.dayRange.lowerBound)",
                            frame: CGRect(x: 0, y: slice.y + (slice.heading ? 38 : 0),
                                          width: geometry.width, height: 28),
                            content: AnyView(HStack {
                                HostedPlaceholder(message: message)
                                if errors[section] != nil { Button("Retry", action: onRetry ?? {}) }
                            }),
                            revision: (viewRevision, rowRevisions[section] ?? 0),
                            wanted: &wanted, document: document)
                }
                for row in geometry.rows(in: position) {
                    let rowY = slice.y + row.y
                    guard rowY + row.layout.height >= y - overscan,
                          rowY <= y + height + overscan else { continue }
                    for item in row.items {
                        guard let frame = geometry.frame(forItem: item.photo.id) else { continue }
                        wantedCells.insert(item.ordinal)
                        placeCell(item, frame: frame, geometry: geometry, document: document, repository: repository)
                    }
                }
            }
            if animateCellFrames {
                NSAnimationContext.endGrouping()
                animateCellFrames = false
            }
            for ordinal in cells.keys where !wantedCells.contains(ordinal) {
                if let cell = cells.removeValue(forKey: ordinal) { recycle(cell) }
                cellRevisions.removeValue(forKey: ordinal)
            }
            for key in hosts.keys where !wanted.contains(key) {
                hosts.removeValue(forKey: key)?.removeFromSuperview()
                hostRevisions.removeValue(forKey: key)
            }
            if !suppressFeedback, !geometry.slices.isEmpty {
                let day = geometry.slices[geometry.slice(at: y)].source.dayID
                if day != lastVisibleDay {
                    lastVisibleDay = day
                    feedbackTask?.cancel()
                    feedbackTask = Task { [weak self] in
                        await Task.yield()
                        guard let self, !Task.isCancelled, self.lastVisibleDay == day else { return }
                        self.onVisibleDay?(day)
                    }
                }
            }
            // Demand all viewport sections; immediate neighbors are optional prefetch.
            let first = visibleSections.first ?? 0, last = visibleSections.last ?? first
            var prefetch: [Int] = []
            if first > 0 { prefetch.append(first - 1) }
            if last + 1 < index.sections.count { prefetch.append(last + 1) }
            var demandedSections = visibleSections
            if demandedSections.count < 8,
               let restorationSection = scrollIntent.nextSectionToVerify(index: index, allowNetwork: allowNetwork),
               !demandedSections.contains(restorationSection) {
                demandedSections.append(restorationSection)
            }
            if !rebasing && (demandedSections != demandedVisible || prefetch != demandedPrefetch) {
                demandedVisible = demandedSections
                demandedPrefetch = prefetch
                demandTask?.cancel()
                if let window {
                    let network = allowNetwork
                    let retry = retryRevision
                    let preceding = demandTask
                    demandTask = Task {
                        _ = await preceding?.value
                        guard !Task.isCancelled else { return }
                        await window.update(index: index, allowNetwork: network,
                                            visible: demandedSections, prefetch: prefetch,
                                            retryRevision: retry)
                    }
                }
            }
            if scrollIntent.canPersistViewport {
                scheduleRestorationFeedback()
            }
            updateSelectionDrawing()
        }

        func userDidScroll(_ direction: LibraryFilterScanDirection, generation: UInt64) {
            guard collection.isLibraryFilter, let scroll, let geometry else { return }
            let top = visibleTop(in: scroll)
            let height = visibleHeight(in: scroll)
            guard LibraryFilterEdgeDemandGeometry.resolve(direction: direction, top: top,
                    viewportHeight: height, documentHeight: geometry.totalHeight) != nil else { return }
            let sections = geometry.sectionIndices(y: top, height: height)
            guard !sections.isEmpty else { return }
            onFilterEdgeDemand?(sections, direction, generation)
        }

        func reveal(_ request: BrowserRevealRequest, completion: @escaping (CGRect?) -> Void) {
            guard let index, let geometry else { completion(nil); return }
            pendingOpen = nil
            cancelPointerInteraction()
            let target = scrollIntent.reveal(request, index: index, geometry: geometry)
            cancelSupersededReveal()
            guard let target else { completion(nil); return }
            pendingReveal = (request.id, completion)
            selectAfterRevealItemID = request.selectOnCompletion ? request.itemID : nil
            scrollTo(target)
            viewportChanged()
            finishRevealIfPossible(id: request.id, itemID: request.itemID)
        }

        func finishRevealIfPossible(id: UUID, itemID: Int64) {
            guard scrollIntent.revealID == id, let scroll, let geometry,
                  let frame = geometry.frame(forItem: itemID) else { return }
            scrollIntent.revealPositioned(id: id)
            if selectAfterRevealItemID == itemID,
               let ordinal = index?.ordinalForLoadedItemID(itemID, pages: pages) {
                selection.replace(with: ordinal)
                selectAfterRevealItemID = nil
                publishSelection()
            }
            scrollTo(frame.midY - visibleHeight(in: scroll) / 2)
            viewportChanged()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scrollIntent.revealID == id else { return }
                guard let scroll = self.scroll, let document = self.document,
                      let content = scroll.window?.contentView,
                      let current = self.geometry?.frame(forItem: itemID) else {
                    self.finishReveal(id: id, rect: nil)
                    return
                }
                let rect = document.convert(current, to: content)
                self.finishReveal(id: id, rect: content.bounds.intersects(rect) ? rect : nil)
            }
        }

        func finishReveal(id: UUID, rect: CGRect?) {
            guard scrollIntent.finishReveal(id: id), pendingReveal?.id == id else { return }
            let completion = pendingReveal?.completion
            pendingReveal = nil
            completion?(rect)
            scheduleRestorationFeedback()
        }

        func cancelSupersededReveal() {
            guard let pendingReveal, pendingReveal.id != scrollIntent.revealID else { return }
            self.pendingReveal = nil
            selectAfterRevealItemID = nil
            pendingReveal.completion(nil)
        }
        func scheduleRestorationFeedback() {
            restorationFeedbackTask?.cancel()
            restorationFeedbackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled else { return }
                self.emitCurrentRestorationAnchor()
            }
        }

        func emitCurrentRestorationAnchor() {
            if let restoration = scrollIntent.restoration {
                onRestorationAnchorChanged?(restoration)
                return
            }
            guard let scroll, let index, let anchor = geometry?.anchor(at: visibleTop(in: scroll)),
                  index.sections.indices.contains(anchor.sectionIndex) else { return }
            onRestorationAnchorChanged?(PhotoTimelineRestorationAnchor(
                itemID: anchor.itemID,
                dayID: anchor.dayID,
                sectionOffsetHint: index.sections[anchor.sectionIndex].offset,
                localOffset: anchor.localOffset,
                sectionFraction: anchor.fraction
            ))
        }

        /// Content is built only when a host is created or its revision changed.
        func addHost(_ key: String, frame: CGRect, content: @autoclosure () -> AnyView,
                             revision: (Int, Int), wanted: inout Set<String>, document: NSView) {
            wanted.insert(key)
            let signposter = SynologyDiagnostics.browserSignposts
            if let host = hosts[key] {
                if host.frame != frame { host.frame = frame }
                if let previous = hostRevisions[key], previous != revision {
                    let interval = signposter.beginInterval("Update host", id: signposter.makeSignpostID())
                    host.rootView = AnyView(content().environment(\.colorScheme, colorScheme))
                    signposter.endInterval("Update host", interval)
                    hostRevisions[key] = revision
                    hostsUpdated &+= 1
                }
            } else {
                let interval = signposter.beginInterval("Create host", id: signposter.makeSignpostID())
                let root = AnyView(content().environment(\.colorScheme, colorScheme))
                let host = NSHostingView(rootView: root)
                host.frame = frame
                if let overlay = (document as? FlippedDocumentView)?.overlay {
                    document.addSubview(host, positioned: .below, relativeTo: overlay)
                } else { document.addSubview(host) }
                signposter.endInterval("Create host", interval)
                hosts[key] = host
                hostRevisions[key] = revision
                hostsCreated &+= 1
            }
        }

        func visiblePhotoAnchor(_ geometry: LibraryViewportGeometry, in scroll: NSScrollView)
            -> (anchor: LibraryViewportGeometry.Anchor, distance: Double)? {
            let top = visibleTop(in: scroll)
            let position = max(top, geometry.contentOrigin + 38)
            guard position < top + visibleHeight(in: scroll), let anchor = geometry.anchor(at: position) else { return nil }
            return (anchor, position - top)
        }

        func updateDocumentHeight() {
            guard let scroll, let document, let geometry else { return }
            let frame = CGRect(x: 0, y: 0, width: CGFloat(availableWidth(in: scroll)),
                               height: max(CGFloat(geometry.totalHeight) + (emptyContent == nil ? 0 : 240), scroll.contentSize.height))
            if document.frame != frame { document.frame = frame }
            document.overlay?.frame = document.bounds
        }

        func scrollTo(_ y: Double) {
            guard let scroll, let geometry else { return }
            suppressFeedback = true
            let maximum = max(0, geometry.totalHeight - visibleHeight(in: scroll))
            let target = min(max(0, y), maximum)
            let clipTarget = target - Double(scroll.contentInsets.top)
            scrollIntent.didScrollProgrammatically(to: clipTarget)
            scroll.contentView.scroll(to: CGPoint(x: -scroll.contentInsets.left, y: clipTarget))
            scroll.reflectScrolledClipView(scroll.contentView)
            suppressFeedback = false
        }

        static func signature(_ page: LibraryPage) -> Int {
            var hash = Hasher()
            hash.combine(page.verified)
            hash.combine(page.slots.count)
            for slot in page.slots {
                hash.combine(slot.itemID)
                hash.combine(slot.verified)
                guard let item = slot.item else { continue }
                hash.combine(item.isFavorite)
                hash.combine(item.displayAspectRatio)
                let thumbnail = item.additional?.thumbnail
                hash.combine(thumbnail?.unitID)
                hash.combine(thumbnail?.cacheKey)
                hash.combine(thumbnail?.sm)
                hash.combine(thumbnail?.m)
                hash.combine(thumbnail?.xl)
            }
            return hash.finalize()
        }

        static func membershipSignature(_ page: LibraryPage) -> Int {
            var hash = Hasher()
            hash.combine(page.slots.count)
            for slot in page.slots { hash.combine(slot.itemID) }
            return hash.finalize()
        }

        func availableWidth(in scroll: NSScrollView) -> Double {
            max(1, Double(scroll.contentSize.width - scroll.contentInsets.left - scroll.contentInsets.right))
        }

        func visibleTop(in scroll: NSScrollView) -> Double {
            max(0, Double(scroll.contentView.bounds.minY + scroll.contentInsets.top))
        }

        func visibleHeight(in scroll: NSScrollView) -> Double {
            max(1, Double(scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom))
        }
    }
}

/// What a visible cell was last configured from; equal revisions skip reconfiguration.
struct CellRevision: Equatable {
    let rows: UUID
    let view: Int
    let itemID: Int64
}
