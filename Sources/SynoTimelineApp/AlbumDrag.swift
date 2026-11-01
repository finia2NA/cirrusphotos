import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// Only the random handle crosses the pasteboard. Registry entries never leave this process.
@MainActor
enum AlbumDragRegistry {
    static let type = NSPasteboard.PasteboardType("com.synotimeline.local-album")
    private static var entries: [UUID: (id: Int64, namespace: String)] = [:]
    static func register(albumID: Int64, namespace: String) -> UUID {
        let nonce = UUID()
        entries[nonce] = (albumID, namespace)
        return nonce
    }
    static func remove(_ nonce: UUID) { entries[nonce] = nil }
    static func album(_ value: String?, namespace: String) -> Int64? {
        guard let value, let nonce = UUID(uuidString: value), let entry = entries[nonce],
              entry.namespace == namespace else { return nil }
        return entry.id
    }
    static func insert(_ value: String?, namespace: String, before: Int64?, presentation: AlbumPresentationStore) -> Bool {
        guard let id = album(value, namespace: namespace) else { return false }
        presentation.insert(id, before: before)
        return true
    }
}

/// Local selection handles are consumed once on acceptance; they never contain pasteboard data.
@MainActor
enum SelectionDragRegistry {
    static let type = NSPasteboard.PasteboardType("com.synotimeline.local-selection")
    struct Entry {
        let selection: PhotoSelectionSnapshot
        let sourceAlbumID: Int64?
        let namespace: String
    }
    private static var entries: [UUID: Entry] = [:]
    static func register(_ entry: Entry) -> UUID {
        let nonce = UUID(); entries[nonce] = entry; return nonce
    }
    static func lookup(_ value: String?, namespace: String) -> Entry? {
        guard let value, let nonce = UUID(uuidString: value), let entry = entries[nonce],
              entry.namespace == namespace else { return nil }
        return entry
    }
    static func take(_ value: String?, namespace: String) -> Entry? {
        guard let entry = lookup(value, namespace: namespace), let value, let nonce = UUID(uuidString: value) else { return nil }
        entries[nonce] = nil
        return entry
    }
    static func remove(_ nonce: UUID) { entries[nonce] = nil }
}

@MainActor
final class SelectionPromiseWriter: NSObject, @preconcurrency NSPasteboardWriting {
    private let provider: NSFilePromiseProvider?
    private let nonce: UUID
    init(provider: NSFilePromiseProvider?, nonce: UUID) { self.provider = provider; self.nonce = nonce }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        (provider?.writableTypes(for: pasteboard) ?? []) + [SelectionDragRegistry.type]
    }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == SelectionDragRegistry.type ? nonce.uuidString : provider?.pasteboardPropertyList(forType: type)
    }
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == SelectionDragRegistry.type ? [] : (provider?.writingOptions(forType: type, pasteboard: pasteboard) ?? [])
    }
}

/// Accepts only in-process selection handles; never requests a promised file.
struct AlbumMembershipTarget: NSViewRepresentable {
    let albumID: Int64
    @ObservedObject var model: LibraryModel
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) { view.albumID = albumID; view.model = model }
    @MainActor final class TargetView: NSView {
        var albumID: Int64 = 0
        weak var model: LibraryModel?
        private var active = false { didSet { needsDisplay = true } }
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([SelectionDragRegistry.type]) }
        required init?(coder: NSCoder) { fatalError() }
        private func value(_ sender: NSDraggingInfo) -> String? { sender.draggingPasteboard.string(forType: SelectionDragRegistry.type) }
        private func valid(_ sender: NSDraggingInfo) -> Bool {
            guard let model, let namespace = model.repository?.namespace, model.albumOperation == nil,
                  model.albums.contains(where: { $0.id == albumID }) else { return false }
            return SelectionDragRegistry.lookup(value(sender), namespace: namespace) != nil
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { active = valid(sender); return active ? .copy : [] }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { active = false }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { valid(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { active = false }
            guard valid(sender), let model, let namespace = model.repository?.namespace,
                  let entry = SelectionDragRegistry.take(value(sender), namespace: namespace) else { return false }
            return model.addDroppedSelection(entry.selection, sourceAlbumID: entry.sourceAlbumID, to: albumID)
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

@MainActor
final class AlbumPromiseWriter: NSObject, @preconcurrency NSPasteboardWriting {
    private let provider: NSFilePromiseProvider
    private let nonce: UUID
    init(provider: NSFilePromiseProvider, nonce: UUID) { self.provider = provider; self.nonce = nonce }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        provider.writableTypes(for: pasteboard) + [AlbumDragRegistry.type]
    }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == AlbumDragRegistry.type ? nonce.uuidString : provider.pasteboardPropertyList(forType: type)
    }
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == AlbumDragRegistry.type ? [] : provider.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

/// Monitors the gesture over the SwiftUI control without replacing its click handling.
struct AlbumDragGesture: NSViewRepresentable {
    let albumID: Int64
    let name: String
    let repository: CachedPhotosRepository?
    let preview: NSImage?
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.albumID = albumID; view.name = name; view.repository = repository; view.preview = preview
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    @MainActor final class MonitorView: NSView {
        var albumID: Int64 = 0
        var name = ""
        var repository: CachedPhotosRepository?
        var preview: NSImage?
        private var monitor: Any?
        private var down: NSPoint?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                switch event.type {
                case .leftMouseDown:
                    self.down = self.bounds.contains(point) ? event.locationInWindow : nil
                case .leftMouseUp: self.down = nil
                case .leftMouseDragged:
                    guard let down = self.down, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4,
                          let repository = self.repository else { break }
                    self.down = nil
                    let safe = self.name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let filename = (safe.isEmpty || safe == "." || safe == ".." ? "Album" : safe) + ".zip"
                    let payload = PhotoDragPayload(repository: repository, source: .album(self.albumID), count: 1,
                                                   filename: filename, forcesArchive: true)
                    if PhotoFileDragSource.begin(payload: payload, previews: [self.preview].compactMap { $0 },
                                                 cropsToSquare: true, from: self, event: event, albumID: self.albumID) { return nil }
                default: break
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; down = nil }
    }
}

/// A narrow insertion target leaves the middle of each row free for future membership drops.
struct AlbumInsertionTarget: NSViewRepresentable {
    let before: Int64?
    let namespace: String?
    @ObservedObject var presentation: AlbumPresentationStore
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) {
        view.before = before; view.namespace = namespace; view.presentation = presentation
    }
    @MainActor final class TargetView: NSView {
        var before: Int64?
        var namespace: String?
        weak var presentation: AlbumPresentationStore?
        private var active = false { didSet { needsDisplay = true } }
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([AlbumDragRegistry.type]) }
        required init?(coder: NSCoder) { fatalError() }
        private func album(_ sender: NSDraggingInfo) -> Int64? {
            guard let namespace else { return nil }
            return AlbumDragRegistry.album(sender.draggingPasteboard.string(forType: AlbumDragRegistry.type), namespace: namespace)
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
            guard let namespace, let presentation else { return false }
            return AlbumDragRegistry.insert(sender.draggingPasteboard.string(forType: AlbumDragRegistry.type),
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
