import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

/// File drags, context menus and the published command state.
extension LibraryBrowserScrollView.Coordinator {
    func isFileDragOrigin(at point: CGPoint) -> Bool {
        guard let ordinal = geometry?.ordinal(at: point) else { return false }
        return loadedItem(ordinal) != nil
    }

    func cancelFileDragGesture() { cancelPointerInteraction() }

    func beginFileDrag(at point: CGPoint, event: NSEvent) -> Bool {
        guard allowsFileDrag else { return false }
        guard let ordinal = geometry?.ordinal(at: point), let clicked = loadedItem(ordinal),
              let document, let repository,
              let timelineSnapshot, let index else { return false }
        if !selection.contains(ordinal) { selection.replace(with: ordinal); publishSelection() }
        let selected = selection.indexes
        let count = selected.count
        guard count > 0, allowsAlbumMembership || clicked.photo.hasDisplayableStillImage || count > 1 else { return false }
        var known: [Int: Int64] = [:]
        var previews: [NSImage] = []
        if let image = findViewerSourceAnchor(for: clicked.photo.id, in: document)?.image { previews.append(image) }
        for (section, page) in pages {
            for (offset, slot) in page.slots.enumerated() {
                guard let selectedOrdinal = index.ordinal(sectionIndex: section, pageOffset: offset),
                      selected.contains(selectedOrdinal), let item = slot.item else { continue }
                known[selectedOrdinal] = item.id
                if previews.count < 20, selectedOrdinal != ordinal,
                   let image = findViewerSourceAnchor(for: item.id, in: document)?.image { previews.append(image) }
            }
        }
        known[ordinal] = clicked.photo.id
        let command = BrowserCommandSnapshot(owner: commandOwner, active: true, canOpen: count == 1,
            canToggleFavorite: false, collection: collection, indexFingerprint: index.fingerprint,
            selectionGeneration: selectionState.generation, selectedOrdinals: selected,
            knownItemIDsByOrdinal: known, timeline: timelineSnapshot, authority: selectionAuthority, sourceAlbumID: sourceAlbumID)
        let filename: String
        if count == 1 {
            let name = clicked.photo.filename.flatMap { $0.isEmpty ? nil : $0 } ?? "Photo-\(clicked.photo.id)"
            filename = URL(fileURLWithPath: name).lastPathComponent
        } else { filename = "Photos.zip" }
        guard let captured = command.captureSelection(timeline: timelineSnapshot) else { return false }
        let payload = PhotoDragPayload(repository: repository, source: .selection(captured),
                                       count: count, filename: filename)
        cancelPointerInteraction()
        return PhotoFileDragSource.begin(payload: payload, previews: previews,
                                         cropsToSquare: geometry?.cropsThumbnailsToSquare ?? false,
                                         from: document, event: event,
                                         localSelection: allowsAlbumMembership ? .init(selection: captured, sourceAlbumID: sourceAlbumID, namespace: repository.namespace) : nil,
                                         promisesFile: clicked.photo.hasDisplayableStillImage || count > 1)
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let ordinal = geometry?.ordinal(at: point),
              let item = loadedItem(ordinal) else { return nil }
        if !selection.contains(ordinal) { selection.replace(with: ordinal); publishSelection() }
        var known: [Int: Int64] = [:]
        for selected in selection.indexes {
            if let item = loadedItem(selected) { known[selected] = item.photo.id }
        }
        let snapshot = BrowserCommandSnapshot(owner: commandOwner, active: true, canOpen: false,
            canToggleFavorite: false, collection: collection, indexFingerprint: index?.fingerprint,
            selectionGeneration: selectionState.generation, selectedOrdinals: selection.indexes,
            knownItemIDsByOrdinal: known, timeline: timelineSnapshot, authority: selectionAuthority, sourceAlbumID: sourceAlbumID)
        let menu = item.photo.hasDisplayableStillImage && allowsDownloads
            ? photoDownloadMenu { [weak self] kind, choose in self?.onDownload?(snapshot, kind, choose) }
            : NSMenu()
        if allowsPersonalActions && item.photo.hasDisplayableStillImage {
            let editSnapshot = BrowserCommandSnapshot(owner: commandOwner, active: true, canOpen: true,
                canToggleFavorite: false, collection: collection, indexFingerprint: index?.fingerprint,
                selectionGeneration: selectionState.generation, selectedOrdinals: IndexSet(integer: ordinal),
                knownItemIDsByOrdinal: [ordinal: item.photo.id], timeline: timelineSnapshot, authority: selectionAuthority, sourceAlbumID: sourceAlbumID)
            addEditMenu(to: menu, filename: item.photo.filename) { [weak self] application in
                self?.onEdit?(editSnapshot, application)
            }
        }
        if allowsAlbumMembership { onAlbumMenu?(menu, snapshot) }
        if allowsFileDrag, let onDelete {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(PhotoDownloadMenuItem(title: "Delete…") { onDelete(snapshot) })
        }
        return menu.items.isEmpty ? nil : menu
    }

    func publishCommandState(active: Bool) {
        let active = active && (scroll as? TimelineScrollView)?.browserCommandContextActive == true
        if !active { cancelPointerInteraction(); selection.endExtension(); pendingOpen = nil }
        let canOpen = active && selection.count == 1
        let canToggleFavorite = active && !selection.indexes.isEmpty && allowNetwork
        let callback = onCommandStateChanged, owner = commandOwner
        let handler: ((BrowserSelectionCommand) -> Void)? = active ? { [weak self] in self?.perform($0) } : nil
        let knownItemIDs: [Int: Int64]
        if active {
            var map: [Int: Int64] = [:]
            for ordinal in selection.indexes {
                if let item = loadedItem(ordinal) { map[ordinal] = item.photo.id }
            }
            knownItemIDs = map
        } else {
            knownItemIDs = [:]
        }
        let snapshot = BrowserCommandSnapshot(
            owner: owner, active: active, canOpen: canOpen,
            canToggleFavorite: canToggleFavorite,
            collection: collection,
            indexFingerprint: index?.fingerprint,
            selectionGeneration: selectionState.generation,
            selectedOrdinals: selection.indexes,
            knownItemIDsByOrdinal: knownItemIDs, timeline: timelineSnapshot, authority: selectionAuthority, sourceAlbumID: sourceAlbumID
        )
        DispatchQueue.main.async { callback?(snapshot, handler) }
    }
}
