import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

/// Keyboard commands, pointer and marquee selection, autoscroll and opening photos.
extension LibraryBrowserScrollView.Coordinator {
    func perform(_ command: BrowserSelectionCommand) {
        guard let scroll = scroll as? TimelineScrollView,
              scroll.browserCommandContextActive else { return }
        switch command {
        case .move(let direction, let extending):
            guard let index, let geometry else { return }
            let visible = geometry.firstOrdinal(inVerticalRange:
                visibleTop(in: scroll)...(visibleTop(in: scroll) + visibleHeight(in: scroll)))
            if let cursor = selection.move(direction, extending: extending, in: index,
                                           columns: geometry.itemsPerRow, firstVisible: visible) {
                scrollIntent.selectionNavigation()
                revealSelectionCursor(cursor)
                publishSelection()
            }
        case .openSelected:
            guard selection.count == 1, let ordinal = selection.first else { return }
            open(ordinal: ordinal)
        case .selectAll:
            guard let index else { return }
            selection.selectAll(count: index.totalCount)
            publishSelection()
        case .toggleFavorite:
            break  // Routed through LibraryModel; the browser handler is not invoked for this.
        case .endExtension:
            selection.endExtension()
            publishSelection()
        }
    }

    func interact(_ phase: FlippedDocumentView.InteractionPhase) {
        guard let scroll, let geometry else { return }
        switch phase {
        case .down(let point, let clickCount, let shift, let option):
            guard point.y >= geometry.contentOrigin else { return }
            (scroll as? TimelineScrollView)?.focusTimeline()
            pointer.begin(at: point); pointerShift = shift; pointerOption = option
            marqueeSelection = BrowserMarqueeSelection(baseline: selection.indexes, toggles: shift)
            if clickCount >= 2, let ordinal = geometry.ordinal(at: point) {
                selection.replace(with: ordinal)
                publishSelection()
                open(ordinal: ordinal)
                pointer.cancel()
            }
        case .drag(let point):
            guard pointer.isActive, let rectangle = pointer.drag(to: point) else { return }
            updateMarquee(rectangle, geometry: geometry)
            startAutoscrollIfNeeded()
        case .up(let point):
            defer { cancelPointerInteraction() }
            guard pointer.isActive else { return }
            if let rectangle = pointer.finish(at: point) { updateMarquee(rectangle, geometry: geometry) }
            else {
                if let ordinal = geometry.ordinal(at: point) {
                    if pointerShift && pointerOption {
                        selection.addRangeFromClosestSelection(to: ordinal)
                    } else if pointerShift {
                        selection.toggle(ordinal)
                    } else {
                        selection.replace(with: ordinal)
                    }
                } else if !pointerShift { selection.replace(with: nil) }
                publishSelection()
            }
        }
    }

    func publishSelection() {
        selectionEpoch &+= 1
        pendingOpen = nil
        selectionObservation.indexes = selection.indexes
        persistSelectionState()
        updateSelectionDrawing()
        if let scroll = scroll as? TimelineScrollView {
            publishCommandState(active: scroll.browserCommandContextActive)
        }
    }

    func persistSelectionState() {
        let value = selectionState, callback = onSelectionStateChanged
        DispatchQueue.main.async { callback?(value) }
    }

    /// Selection frames are document coordinates, so scrolling alone never changes them.
    func updateSelectionDrawing() {
        guard let geometry else {
            selectionFramesKey = nil
            if document?.selectionFrames.isEmpty == false { document?.selectionFrames = [] }
            return
        }
        let indexes = selection.indexes
        if let key = selectionFramesKey, key.rows == geometry.rowsRevision, key.indexes == indexes { return }
        selectionFramesKey = (geometry.rowsRevision, indexes)
        let frames = indexes.isEmpty ? [] : geometry.frames(for: indexes)
        if document?.selectionFrames != frames { document?.selectionFrames = frames }
    }

    func loadedItem(_ ordinal: Int) -> LibraryViewportGeometry.RowItem? {
        guard let location = index?.location(forOrdinal: ordinal), let page = pages[location.sectionIndex],
              let slot = page.slot(at: location.pageOffset), let item = slot.item else { return nil }
        return LibraryViewportGeometry.RowItem(photo: item, verified: slot.verified,
            sectionIndex: location.sectionIndex, pageOffset: location.pageOffset, ordinal: ordinal)
    }

    func selectFromAccessibility(_ ordinal: Int) {
        selection.replace(with: ordinal)
        scrollIntent.selectionNavigation()
        publishSelection()
    }

    func openFromAccessibility(_ ordinal: Int, request: PhotoViewerOpenRequest) {
        selectFromAccessibility(ordinal)
        onOpenPhoto?(request)
    }

    func revealSelectionCursor(_ ordinal: Int) {
        guard let scroll, let frame = geometry?.slotFrame(for: ordinal) else { return }
        let top = visibleTop(in: scroll), bottom = top + visibleHeight(in: scroll)
        if frame.minY < top { scrollTo(frame.minY) }
        else if frame.maxY > bottom { scrollTo(frame.maxY - visibleHeight(in: scroll)) }
        viewportChanged()
    }

    func open(ordinal: Int) {
        guard let item = loadedItem(ordinal), let document,
              let frame = geometry?.frame(forItem: item.photo.id) else {
            pendingOpen = BrowserPendingOpen(ordinal: ordinal, generation: selectionState.generation,
                                             selectionEpoch: selectionEpoch)
            revealSelectionCursor(ordinal)
            return
        }
        pendingOpen = nil
        if let anchor = findViewerSourceAnchor(for: item.photo.id, in: document) {
            let page = pages[item.sectionIndex]
            let seed = PhotoViewerSeed(sectionIndex: item.sectionIndex, pageOffset: item.pageOffset,
                item: item.photo, page: page?.completeItems, pageVerified: page?.verified ?? item.verified)
            onOpenPhoto?(PhotoViewerOpenRequest(seed: seed, source: anchor))
            return
        }
        sourceProxy?.removeFromSuperview()
        let proxy = PassThroughSourceView(frame: frame)
        proxy.wantsLayer = true
        proxy.layer?.backgroundColor = NSColor.clear.cgColor
        document.addSubview(proxy)
        sourceProxy = proxy
        let anchor = PhotoViewerSourceAnchor()
        anchor.attach(proxy)
        anchor.update(itemID: item.photo.id, image: nil)
        let page = pages[item.sectionIndex]
        let seed = PhotoViewerSeed(sectionIndex: item.sectionIndex, pageOffset: item.pageOffset,
            item: item.photo, page: page?.completeItems, pageVerified: page?.verified ?? item.verified)
        onOpenPhoto?(PhotoViewerOpenRequest(seed: seed, source: anchor))
    }

    func openPendingIfPossible() {
        guard let request = pendingOpen,
              request.matches(selection: selection, generation: selectionState.generation,
                              selectionEpoch: selectionEpoch) else {
            pendingOpen = nil; return
        }
        if loadedItem(request.ordinal) != nil { open(ordinal: request.ordinal) }
    }

    func autoScroll(for point: CGPoint) {
        guard let scroll else { return }
        let top = visibleTop(in: scroll), bottom = top + visibleHeight(in: scroll), edge = 28.0
        var target = top
        if point.y < top + edge { target = top - 18 }
        else if point.y > bottom - edge { target = top + 18 }
        guard target != top else { return }
        scrollTo(target)
        viewportChanged()
        let delta = visibleTop(in: scroll) - top
        guard delta != 0, let geometry else { return }
        let adjusted = CGPoint(x: point.x, y: point.y + delta)
        if let rectangle = pointer.move(to: adjusted) { updateMarquee(rectangle, geometry: geometry) }
    }

    func updateMarquee(_ rectangle: CGRect, geometry: LibraryViewportGeometry) {
        document?.marquee = rectangle
        guard var marqueeSelection else { return }
        selection.replace(with: marqueeSelection.update(rectangle: rectangle,
            loadedFrames: geometry.loadedFramesByOrdinal()))
        self.marqueeSelection = marqueeSelection
        publishSelection()
    }

    func refreshMarqueeSelection() {
        guard let rectangle = pointer.rectangle, let geometry else { return }
        updateMarquee(rectangle, geometry: geometry)
    }

    func startAutoscrollIfNeeded() {
        guard autoscrollTask == nil else { return }
        autoscrollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.pointer.dragging {
                if let point = self.pointer.current { self.autoScroll(for: point) }
                try? await Task.sleep(for: .milliseconds(35))
            }
        }
    }

    func cancelPointerInteraction() {
        pointer.cancel()
        pointerShift = false
        pointerOption = false
        marqueeSelection = nil
        autoscrollTask?.cancel(); autoscrollTask = nil
        document?.marquee = nil
    }
}
