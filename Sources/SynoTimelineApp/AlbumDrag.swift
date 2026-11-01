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

/// SwiftUI owns hit testing and gesture recognition so clipped or covered cards cannot start a drag.
struct AlbumDragGesture: ViewModifier {
    let albumID: Int64
    let name: String
    let repository: CachedPhotosRepository?
    let preview: NSImage?
    @StateObject private var source = AlbumDragViewReference()
    @State private var started = false

    func body(content: Content) -> some View {
        content
            .background(AlbumDragSourceView(reference: source))
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in
                guard !started, let view = source.view, let repository,
                      let event = NSApp.currentEvent, event.type == .leftMouseDragged,
                      event.window === view.window else { return }
                let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
                    .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                let filename = (safe.isEmpty || safe == "." || safe == ".." ? "Album" : safe) + ".zip"
                let payload = PhotoDragPayload(repository: repository, source: .album(albumID), count: 1,
                                               filename: filename, forcesArchive: true)
                started = PhotoFileDragSource.begin(payload: payload, previews: [preview].compactMap { $0 },
                                                     cropsToSquare: true, from: view, event: event, albumID: albumID,
                                                     onEnd: { started = false })
            }.onEnded { _ in started = false })
    }
}

@MainActor
private final class AlbumDragViewReference: ObservableObject {
    weak var view: NSView?
}

private struct AlbumDragSourceView: NSViewRepresentable {
    let reference: AlbumDragViewReference
    func makeNSView(context: Context) -> NSView {
        let view = AlbumDragAnchorView()
        reference.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { reference.view = view }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { }
}

/// Opens the overview after a local photo selection hovers over Albums.
struct AlbumOverviewSpringTarget: NSViewRepresentable {
    let namespace: String?
    let open: () -> Void
    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) { view.namespace = namespace; view.open = open }
    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.cancel() }

    @MainActor final class TargetView: NSView {
        var namespace: String?
        var open: (() -> Void)?
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
                  SelectionDragRegistry.lookup(value, namespace: namespace) != nil else { return false }
            let expected = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == expected, self.namespace == namespace,
                      SelectionDragRegistry.lookup(value, namespace: namespace) != nil else { return }
                self.pending = nil
                self.open?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
            return true
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let namespace, SelectionDragRegistry.lookup(
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

/// The anchor only supplies a coordinate space for AppKit's drag session.
@MainActor
final class AlbumDragAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
