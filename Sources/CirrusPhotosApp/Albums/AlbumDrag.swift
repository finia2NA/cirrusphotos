import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// Only the random handle crosses the pasteboard. Registry entries never leave this process
/// and belong to one session.
@MainActor
final class AlbumDragRegistry {
    static let type = NSPasteboard.PasteboardType("io.github.finia2na.cirrusphotos.local-album")
    private var entries: [UUID: (collection: PhotoCollectionDescriptor, namespace: String)] = [:]
    func register(collection: PhotoCollectionDescriptor, namespace: String) -> UUID {
        let nonce = UUID()
        entries[nonce] = (collection, namespace)
        return nonce
    }
    func remove(_ nonce: UUID) { entries[nonce] = nil }
    func album(_ value: String?, namespace: String) -> PhotoCollectionDescriptor? {
        guard let value, let nonce = UUID(uuidString: value), let entry = entries[nonce],
              entry.namespace == namespace else { return nil }
        return entry.collection
    }
    func insert(_ value: String?, namespace: String, before: PhotoCollectionDescriptor?, presentation: AlbumPresentationStore) -> Bool {
        guard let id = album(value, namespace: namespace) else { return false }
        presentation.insert(id, before: before)
        return true
    }
    func removeAll() { entries.removeAll() }
}

/// Local selection handles are consumed once on acceptance; they never contain pasteboard data.
@MainActor
final class SelectionDragRegistry {
    static let type = NSPasteboard.PasteboardType("io.github.finia2na.cirrusphotos.local-selection")
    struct Entry {
        let selection: PhotoSelectionSnapshot
        let sourceAlbumID: Int64?
        let namespace: String
    }
    private var entries: [UUID: Entry] = [:]
    private var endObservers: [UUID: [() -> Void]] = [:]
    func register(_ entry: Entry) -> UUID {
        let nonce = UUID(); entries[nonce] = entry; return nonce
    }
    func lookup(_ value: String?, namespace: String) -> Entry? {
        guard let value, let nonce = UUID(uuidString: value), let entry = entries[nonce],
              entry.namespace == namespace else { return nil }
        return entry
    }
    func take(_ value: String?, namespace: String) -> Entry? {
        guard let entry = lookup(value, namespace: namespace), let value, let nonce = UUID(uuidString: value) else { return nil }
        entries[nonce] = nil
        return entry
    }
    func observeEnd(_ value: String, namespace: String, action: @escaping () -> Void) -> Bool {
        guard lookup(value, namespace: namespace) != nil, let nonce = UUID(uuidString: value) else { return false }
        endObservers[nonce, default: []].append(action)
        return true
    }
    func remove(_ nonce: UUID) {
        entries[nonce] = nil
        let observers = endObservers.removeValue(forKey: nonce) ?? []
        observers.forEach { $0() }
    }
    /// Drops every handle and runs the end observers, as if each drag had ended.
    func removeAll() {
        let observers = endObservers.values.flatMap { $0 }
        entries.removeAll()
        endObservers.removeAll()
        observers.forEach { $0() }
    }
}

/// One session's in-process drag state: album and selection handles, and the drag sources
/// AppKit needs kept alive until their drags end.
@MainActor
final class LocalDragRegistry {
    let albums = AlbumDragRegistry()
    let selections = SelectionDragRegistry()
    private(set) var isEnded = false
    private var sources: [UUID: PhotoFileDragSource] = [:]
    var activeSourceCount: Int { sources.count }

    func retain(_ source: PhotoFileDragSource, id: UUID) { sources[id] = source }
    func release(_ id: UUID) { sources[id] = nil }

    /// Drops every handle so a drop that arrives later finds nothing. Running drag sources stay
    /// until AppKit ends their drags; they hold only handles and an end action.
    func end() {
        isEnded = true
        albums.removeAll()
        selections.removeAll()
    }
}

/// A file promise that also carries an in-process handle type. The provider itself must be the
/// pasteboard writer for Finder to fulfil the promise; wrapping it in another writer is rejected.
final class LocalHandlePromiseProvider: NSFilePromiseProvider {
    var localType: NSPasteboard.PasteboardType?
    var nonce: UUID?
    /// Offered as plain text beside the file promise; text fields take it and Finder takes the file.
    /// It is written when the drag starts: a file promise provider never serves other types lazily.
    var text: String?
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + (localType.map { [$0] } ?? []) + (text == nil ? [] : [.string])
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string, let text { return text }
        return type == localType ? nonce?.uuidString : super.pasteboardPropertyList(forType: type)
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        return type == localType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

/// Local handle without a file promise, for items that cannot be exported.
final class LocalHandleWriter: NSObject, NSPasteboardWriting {
    private let type: NSPasteboard.PasteboardType
    private let nonce: UUID
    private let text: String?
    init(type: NSPasteboard.PasteboardType, nonce: UUID, text: String? = nil) {
        self.type = type; self.nonce = nonce; self.text = text
    }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { text == nil ? [type] : [type, .string] }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .string ? text : nonce.uuidString
    }
}

/// Accepts only in-process selection handles; never requests a promised file.
struct AlbumMembershipTarget: NSViewRepresentable {
    let collection: PhotoCollectionDescriptor
    var model: LibraryModel
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) { view.collection = collection; view.model = model }
    @MainActor final class TargetView: NSView {
        var collection: PhotoCollectionDescriptor = .album(0)
        weak var model: LibraryModel?
        private var active = false { didSet { needsDisplay = true } }
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([SelectionDragRegistry.type, .fileURL]) }
        required init?(coder: NSCoder) { fatalError() }
        private func value(_ sender: NSDraggingInfo) -> String? { sender.draggingPasteboard.string(forType: SelectionDragRegistry.type) }
        private func valid(_ sender: NSDraggingInfo) -> Bool {
            guard let model, let namespace = model.repository?.namespace, model.albumOperation == nil,
                  model.albums.contains(where: { $0.collection == collection && (!$0.isIncoming || $0.recipientCanUpload) }) else { return false }
            let uploads = model.session.uploads
            if collection.albumID != nil, !uploads.isEnded, !uploads.active, !PhotoUploadManager.fileURLs(sender).isEmpty { return true }
            return model.session.drags.selections.lookup(value(sender), namespace: namespace) != nil
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            active = valid(sender)
            // Only the first pasteboard item carries the handle; report the whole selection to AppKit's count.
            if active, let namespace = model?.repository?.namespace,
               let entry = model?.session.drags.selections.lookup(value(sender), namespace: namespace) {
                sender.numberOfValidItemsForDrop = entry.selection.selectedOrdinals.count
            }
            return active ? .copy : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { active = false }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { valid(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { active = false }
            guard valid(sender), let model, let repository = model.repository else { return false }
            let urls = PhotoUploadManager.fileURLs(sender)
            if let albumID = collection.albumID, !urls.isEmpty {
                return model.session.uploads.start(urls, repository: repository, destination: .album(albumID)) { [weak model] in await model?.reload() }
            }
            let namespace = repository.namespace
            guard
                  let entry = model.session.drags.selections.take(value(sender), namespace: namespace) else { return false }
            return model.addCapturedSelection(entry.selection, sourceAlbumID: entry.sourceAlbumID, to: collection)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard active else { return }
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            path.lineWidth = 2; path.stroke()
        }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

struct AlbumDragGesture: ViewModifier {
    let collection: PhotoCollectionDescriptor
    let name: String
    let repository: CachedPhotosRepository?
    let session: AppSession
    let preview: NSImage?
    func body(content: Content) -> some View {
        content
            .background(AlbumDragSourceView { view, event in
                guard let repository else { return false }
                let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
                    .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                let filename = safe.isEmpty || safe == "." || safe == ".." ? "Album" : safe
                let payload = PhotoDragPayload(repository: repository, source: .album(collection.albumID ?? 0), count: 1,
                                               delivery: .folder(name: filename))
                return PhotoFileDragSource.begin(session: session, payload: payload, previews: [preview].compactMap { $0 },
                                                 cropsToSquare: true, from: view, event: event, albumCollection: collection, promisesFile: collection.albumID != nil)
            })
    }
}

struct AlbumDragSourceView: NSViewRepresentable {
    let begin: (NSView, NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView {
        let view = AlbumDragAnchorView()
        view.begin = begin
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? AlbumDragAnchorView)?.begin = begin }
}

/// Opens the overview after a local photo selection hovers over Albums.
struct AlbumOverviewSpringTarget: NSViewRepresentable {
    let namespace: String?
    let selections: SelectionDragRegistry
    let open: (String) -> Void
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) { view.namespace = namespace; view.selections = selections; view.open = open }
    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.cancel() }

    @MainActor final class TargetView: NSView {
        var namespace: String?
        weak var selections: SelectionDragRegistry?
        var open: ((String) -> Void)?
        private var pending: DispatchWorkItem?
        private var generation = 0
        var hoverDelay: TimeInterval = 0.7
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([SelectionDragRegistry.type])
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            beginHover(sender.draggingPasteboard.string(forType: SelectionDragRegistry.type)) ? .copy : []
        }
        @discardableResult
        func beginHover(_ value: String?) -> Bool {
            cancel()
            guard let namespace, let value,
                  selections?.lookup(value, namespace: namespace) != nil else { return false }
            let expected = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == expected, self.namespace == namespace,
                      self.selections?.lookup(value, namespace: namespace) != nil else { return }
                self.pending = nil
                self.open?(value)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
            return true
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let namespace, selections?.lookup(
                sender.draggingPasteboard.string(forType: SelectionDragRegistry.type), namespace: namespace
            ) != nil else { cancel(); return [] }
            return .copy
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { cancel() }
        override func draggingEnded(_ sender: NSDraggingInfo) { cancel() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { cancel(); return false }
        func cancel() { generation += 1; pending?.cancel(); pending = nil }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

/// A narrow insertion target leaves the middle of each row free for future membership drops.
struct AlbumInsertionTarget: NSViewRepresentable {
    let before: PhotoCollectionDescriptor?
    let namespace: String?
    let albums: AlbumDragRegistry
    @ObservedObject var presentation: AlbumPresentationStore
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) {
        view.before = before; view.namespace = namespace; view.albums = albums; view.presentation = presentation
    }
    @MainActor final class TargetView: NSView {
        var before: PhotoCollectionDescriptor?
        var namespace: String?
        weak var albums: AlbumDragRegistry?
        weak var presentation: AlbumPresentationStore?
        private var active = false { didSet { needsDisplay = true } }
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([AlbumDragRegistry.type]) }
        required init?(coder: NSCoder) { fatalError() }
        private func album(_ sender: NSDraggingInfo) -> PhotoCollectionDescriptor? {
            guard let namespace else { return nil }
            return albums?.album(sender.draggingPasteboard.string(forType: AlbumDragRegistry.type), namespace: namespace)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            active = album(sender) != nil
            return active ? .move : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { active = false }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { album(sender) != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { active = false }
            guard let namespace, let presentation, let albums else { return false }
            return albums.insert(sender.draggingPasteboard.string(forType: AlbumDragRegistry.type),
                                 namespace: namespace, before: before, presentation: presentation)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard active else { return }
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2).fill()
        }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

@MainActor
final class AlbumDragAnchorView: NSView {
    var begin: ((NSView, NSEvent) -> Bool)?
    private var monitor: Any?
    private var mouseDownPoint: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        mouseDownPoint = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event)
        }
    }

    func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { mouseDownPoint = nil; return event }
        switch event.type {
        case .leftMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), visibleRect.contains(point), let parent = superview,
                  let content = window?.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                  hit === parent || hit.isDescendant(of: parent) || parent.isDescendant(of: hit) else {
                mouseDownPoint = nil
                return event
            }
            mouseDownPoint = event.locationInWindow
        case .leftMouseDragged:
            guard let start = mouseDownPoint,
                  hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return event }
            mouseDownPoint = nil
            if begin?(self, event) == true { return nil }
        case .leftMouseUp:
            mouseDownPoint = nil
        default: break
        }
        return event
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
