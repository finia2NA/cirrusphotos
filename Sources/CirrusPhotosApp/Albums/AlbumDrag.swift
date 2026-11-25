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

/// Adds dropped photo selections or Finder files to one album. Accepts only in-process
/// selection handles; never requests a promised file.
@MainActor
enum AlbumMembershipDrop {
    private static func value(_ sender: NSDraggingInfo) -> String? { sender.draggingPasteboard.string(forType: SelectionDragRegistry.type) }
    static func valid(_ sender: NSDraggingInfo, collection: PhotoCollectionDescriptor, model: LibraryModel?) -> Bool {
        guard let model, let namespace = model.repository?.namespace, model.canAddDrop(to: collection) else { return false }
        let uploads = model.session.uploads
        if collection.albumID != nil, !uploads.isEnded, !uploads.active, !PhotoUploadManager.fileURLs(sender).isEmpty { return true }
        return model.session.drags.selections.lookup(value(sender), namespace: namespace) != nil
    }
    /// The operation to report while hovering; reports the whole selection to AppKit's count,
    /// since only the first pasteboard item carries the handle.
    static func update(_ sender: NSDraggingInfo, collection: PhotoCollectionDescriptor, model: LibraryModel?) -> NSDragOperation {
        guard valid(sender, collection: collection, model: model) else { return [] }
        if let namespace = model?.repository?.namespace,
           let entry = model?.session.drags.selections.lookup(value(sender), namespace: namespace) {
            sender.numberOfValidItemsForDrop = entry.selection.selectedOrdinals.count
        }
        return .copy
    }
    static func perform(_ sender: NSDraggingInfo, collection: PhotoCollectionDescriptor, model: LibraryModel?) -> Bool {
        guard valid(sender, collection: collection, model: model), let model, let repository = model.repository else { return false }
        let urls = PhotoUploadManager.fileURLs(sender)
        if let albumID = collection.albumID, !urls.isEmpty {
            return model.session.uploads.start(urls, repository: repository, destination: .album(albumID)) { [weak model] in await model?.reload() }
        }
        guard let entry = model.session.drags.selections.take(value(sender), namespace: repository.namespace) else { return false }
        return model.addCapturedSelection(entry.selection, sourceAlbumID: entry.sourceAlbumID, to: collection)
    }
    static func drawHighlight(in bounds: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        path.lineWidth = 2; path.stroke()
    }
}

/// An album card's drop target for photo selections and Finder files.
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
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = AlbumMembershipDrop.update(sender, collection: collection, model: model)
            active = !operation.isEmpty
            return operation
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { active = false }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { AlbumMembershipDrop.valid(sender, collection: collection, model: model) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { active = false }
            return AlbumMembershipDrop.perform(sender, collection: collection, model: model)
        }
        override func draw(_ dirtyRect: NSRect) { if active { AlbumMembershipDrop.drawHighlight(in: bounds) } }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

struct AlbumDragGesture: ViewModifier {
    let collection: PhotoCollectionDescriptor
    let name: String
    let repository: CachedPhotosRepository?
    let session: AppSession
    let preview: NSImage?
    /// Sidebar rows sit in a table whose own click tracking hides drag events from the event
    /// monitor, so they track the click themselves and report a plain click through `onClick`.
    var onClick: (() -> Void)? = nil
    func body(content: Content) -> some View {
        content
            .background(AlbumDragSourceView(onClick: onClick) { view, event in
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
    var onClick: (() -> Void)? = nil
    let begin: (NSView, NSEvent) -> Bool
    func makeNSView(context: Context) -> AlbumDragAnchorView {
        let view = AlbumDragAnchorView()
        view.begin = begin; view.onClick = onClick
        return view
    }
    func updateNSView(_ view: AlbumDragAnchorView, context: Context) { view.begin = begin; view.onClick = onClick }
}

/// Opens the overview after a local photo selection hovers over Albums. An album dropped on
/// the row is pinned before the first pin.
struct AlbumOverviewSpringTarget: NSViewRepresentable {
    let namespace: String?
    let selections: SelectionDragRegistry
    let albums: AlbumDragRegistry
    @ObservedObject var presentation: AlbumPresentationStore
    let open: (String) -> Void
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) {
        view.namespace = namespace; view.selections = selections; view.open = open
        view.insertion.configure(namespace: namespace, albums: albums, presentation: presentation)
    }
    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.cancel(); view.insertion.hide() }

    @MainActor final class TargetView: NSView {
        var namespace: String?
        weak var selections: SelectionDragRegistry?
        var open: ((String) -> Void)?
        private var pending: DispatchWorkItem?
        private var generation = 0
        var hoverDelay: TimeInterval = 0.7
        lazy var insertion = AlbumInsertionDrop(owner: self)
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([SelectionDragRegistry.type, AlbumDragRegistry.type])
        }
        required init?(coder: NSCoder) { fatalError() }
        private func insertsAlbum(_ sender: NSDraggingInfo) -> Bool {
            insertion.update(sender, before: insertion.presentation?.pinnedCollections.first, edge: .bottom)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if insertsAlbum(sender) { return .move }
            return beginHover(sender.draggingPasteboard.string(forType: SelectionDragRegistry.type)) ? .copy : []
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
            if insertsAlbum(sender) { return .move }
            guard let namespace, selections?.lookup(
                sender.draggingPasteboard.string(forType: SelectionDragRegistry.type), namespace: namespace
            ) != nil else { cancel(); return [] }
            return .copy
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { cancel(); insertion.hide() }
        override func draggingEnded(_ sender: NSDraggingInfo) { cancel(); insertion.hide() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { cancel(); return insertion.target != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { insertion.perform(sender) }
        func cancel() { generation += 1; pending?.cancel(); pending = nil }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

/// Reorders or pins a dragged album. The indicator is placed on the boundary between the
/// sidebar's table rows rather than inside the row's content, which is shorter than the row.
@MainActor
final class AlbumInsertionDrop {
    enum Edge { case top, bottom }
    private unowned let owner: NSView
    private var namespace: String?
    private weak var albums: AlbumDragRegistry?
    private(set) weak var presentation: AlbumPresentationStore?
    /// The pin the album would be inserted before while hovering; `.some(nil)` appends.
    private(set) var target: PhotoCollectionDescriptor??
    private let indicator = InsertionIndicatorView()

    init(owner: NSView) { self.owner = owner }

    func configure(namespace: String?, albums: AlbumDragRegistry, presentation: AlbumPresentationStore) {
        self.namespace = namespace; self.albums = albums; self.presentation = presentation
    }

    func album(_ sender: NSDraggingInfo) -> PhotoCollectionDescriptor? {
        guard let namespace else { return nil }
        return albums?.album(sender.draggingPasteboard.string(forType: AlbumDragRegistry.type), namespace: namespace)
    }

    /// Shows the indicator and returns true when the drag carries an album of this account.
    @discardableResult
    func update(_ sender: NSDraggingInfo, before: PhotoCollectionDescriptor?, edge: Edge) -> Bool {
        guard album(sender) != nil, presentation != nil else { hide(); return false }
        target = .some(before)
        show(edge)
        return true
    }

    func perform(_ sender: NSDraggingInfo) -> Bool {
        defer { hide() }
        guard let target, let namespace, let presentation, let albums else { return false }
        return albums.insert(sender.draggingPasteboard.string(forType: AlbumDragRegistry.type),
                             namespace: namespace, before: target, presentation: presentation)
    }

    func hide() {
        target = nil
        indicator.removeFromSuperview()
    }

    private func show(_ edge: Edge) {
        var ancestor = owner.superview
        while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
        let content = owner.bounds
        if let table = ancestor as? NSTableView, case let row = table.row(for: owner), row >= 0 {
            let rect = table.rect(ofRow: row)
            let y: CGFloat
            switch edge {
            case .top: y = row > 0 ? (table.rect(ofRow: row - 1).maxY + rect.minY) / 2 : rect.minY + 1
            case .bottom: y = row + 1 < table.numberOfRows ? (rect.maxY + table.rect(ofRow: row + 1).minY) / 2 : rect.maxY - 1
            }
            let frame = owner.convert(content, to: table)
            place(in: table, NSRect(x: frame.minX, y: y - 1, width: frame.width, height: 2))
        } else {
            let top = owner.isFlipped ? content.minY : content.maxY - 2
            let bottom = owner.isFlipped ? content.maxY - 2 : content.minY
            place(in: owner, NSRect(x: content.minX, y: edge == .top ? top : bottom, width: content.width, height: 2))
        }
    }

    private func place(in host: NSView, _ frame: NSRect) {
        if indicator.superview !== host { indicator.removeFromSuperview(); host.addSubview(indicator) }
        indicator.frame = frame
    }

    private final class InsertionIndicatorView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError() }
        override func updateLayer() {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            layer?.cornerRadius = 1
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The drop target of the row shown while nothing is pinned: a dragged album is pinned.
struct AlbumPinPlaceholderTarget: NSViewRepresentable {
    let namespace: String?
    let albums: AlbumDragRegistry
    @ObservedObject var presentation: AlbumPresentationStore
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) {
        view.insertion.configure(namespace: namespace, albums: albums, presentation: presentation)
    }
    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.insertion.hide() }
    @MainActor final class TargetView: NSView {
        lazy var insertion = AlbumInsertionDrop(owner: self)
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([AlbumDragRegistry.type]) }
        required init?(coder: NSCoder) { fatalError() }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            insertion.update(sender, before: nil, edge: .top) ? .move : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { insertion.hide() }
        override func draggingEnded(_ sender: NSDraggingInfo) { insertion.hide() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { insertion.target != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { insertion.perform(sender) }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

/// A pinned sidebar row's drop target across its whole width: photo selections and Finder
/// files are added to the album; a dragged album is inserted above or below the row,
/// depending on which half it hovers.
struct AlbumSidebarRowTarget: NSViewRepresentable {
    let collection: PhotoCollectionDescriptor
    let next: PhotoCollectionDescriptor?
    var model: LibraryModel
    @ObservedObject var presentation: AlbumPresentationStore
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) {
        view.collection = collection; view.next = next; view.model = model
        view.insertion.configure(namespace: model.repository?.namespace, albums: model.session.drags.albums, presentation: presentation)
    }
    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.insertion.hide() }
    @MainActor final class TargetView: NSView {
        var collection: PhotoCollectionDescriptor = .album(0)
        var next: PhotoCollectionDescriptor?
        weak var model: LibraryModel?
        lazy var insertion = AlbumInsertionDrop(owner: self)
        private var active = false { didSet { if active != oldValue { needsDisplay = true } } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([SelectionDragRegistry.type, .fileURL, AlbumDragRegistry.type])
        }
        required init?(coder: NSCoder) { fatalError() }
        private func upperHalf(_ sender: NSDraggingInfo) -> Bool {
            let point = convert(sender.draggingLocation, from: nil)
            return isFlipped ? point.y < bounds.midY : point.y > bounds.midY
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let upper = upperHalf(sender)
            if insertion.update(sender, before: upper ? collection : next, edge: upper ? .top : .bottom) {
                active = false
                return .move
            }
            let operation = AlbumMembershipDrop.update(sender, collection: collection, model: model)
            active = !operation.isEmpty
            return operation
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { active = false; insertion.hide() }
        override func draggingEnded(_ sender: NSDraggingInfo) { active = false; insertion.hide() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            insertion.target != nil || AlbumMembershipDrop.valid(sender, collection: collection, model: model)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { active = false }
            if insertion.target != nil { return insertion.perform(sender) }
            return AlbumMembershipDrop.perform(sender, collection: collection, model: model)
        }
        override func draw(_ dirtyRect: NSRect) { if active { AlbumMembershipDrop.drawHighlight(in: bounds) } }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}

@MainActor
final class AlbumDragAnchorView: NSView {
    var begin: ((NSView, NSEvent) -> Bool)?
    /// When set, a left click is tracked here instead of reaching the enclosing view, and a
    /// click that does not become a drag calls this.
    var onClick: (() -> Void)?
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
            if onClick != nil, !event.modifierFlags.contains(.control) {
                trackClick(from: event)
                return nil
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

    /// Runs the click's tracking loop: a drag past 4 points starts the album drag, otherwise
    /// the mouse-up is a click. The enclosing table never sees this click.
    private func trackClick(from down: NSEvent) {
        guard let window else { return }
        let start = down.locationInWindow
        var attempted = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            guard !attempted, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 else { continue }
            attempted = true
            if begin?(self, next) == true { return }
        }
        var ancestor = superview
        while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
        if let table = ancestor { window.makeFirstResponder(table) }
        onClick?()
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
