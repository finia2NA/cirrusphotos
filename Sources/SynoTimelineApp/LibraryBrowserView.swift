import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

enum BrowserSelectionCommand {
    case move(LibrarySelectionDirection, extending: Bool)
    case openSelected
    case toggleFavorite
    case endExtension
}

/// Immutable snapshot of browser command context published to the shell.
struct BrowserCommandSnapshot: Sendable {
    let owner: UUID
    let active: Bool
    let canOpen: Bool
    let canToggleFavorite: Bool
    let collection: PhotoCollectionDescriptor
    let indexFingerprint: String?
    let selectionGeneration: String?
    let selectedOrdinals: IndexSet
    let knownItemIDsByOrdinal: [Int: Int64]

    static let inactive = BrowserCommandSnapshot(
        owner: UUID(),
        active: false,
        canOpen: false,
        canToggleFavorite: false,
        collection: .personalLibrary,
        indexFingerprint: nil,
        selectionGeneration: nil,
        selectedOrdinals: IndexSet(),
        knownItemIDsByOrdinal: [:]
    )
}

struct BrowserSelectionState: Equatable {
    var selection = LibrarySelection()
    var descriptorFingerprint: String?
    var membershipRevision = 0
    var membershipSignatures: [Int: Int] = [:]

    var generation: String? { descriptorFingerprint.map { "\($0):\(membershipRevision)" } }

    mutating func bind(to fingerprint: String) {
        guard descriptorFingerprint != fingerprint else { return }
        descriptorFingerprint = fingerprint
        membershipRevision = 0
        membershipSignatures.removeAll()
        selection.bind(to: "\(fingerprint):0")
    }

    @discardableResult
    mutating func reconcileMembership(_ updates: [Int: Int]) -> Bool {
        let changed = updates.contains { section, signature in
            membershipSignatures[section] != nil && membershipSignatures[section] != signature
        }
        if changed {
            membershipRevision += 1
            if let generation { selection.bind(to: generation) }
        }
        for (section, signature) in updates { membershipSignatures[section] = signature }
        return changed
    }
}

struct BrowserMarqueeSelection {
    let baseline: IndexSet
    let toggles: Bool
    private(set) var knownFrames: [Int: CGRect] = [:]

    mutating func update(rectangle: CGRect, loadedFrames: [Int: CGRect]) -> IndexSet {
        for (ordinal, frame) in loadedFrames { knownFrames[ordinal] = frame }
        let hits = IndexSet(knownFrames.compactMap { $0.value.intersects(rectangle) ? $0.key : nil })
        guard toggles else { return hits }
        var result = baseline
        result.formSymmetricDifference(hits)
        return result
    }
}

struct BrowserPendingOpen: Equatable {
    let ordinal: Int
    let generation: String?
    let selectionEpoch: UInt64

    func matches(selection: LibrarySelection, generation: String?, selectionEpoch: UInt64) -> Bool {
        selection.count == 1 && selection.contains(ordinal) && self.generation == generation &&
            self.selectionEpoch == selectionEpoch
    }
}

struct BrowserPointerInteraction {
    private(set) var start: CGPoint?
    private(set) var current: CGPoint?
    private(set) var dragging = false
    var isActive: Bool { start != nil }
    var rectangle: CGRect? {
        guard dragging, let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    mutating func begin(at point: CGPoint) {
        start = point; current = point; dragging = false
    }

    mutating func drag(to point: CGPoint, threshold: CGFloat = 3) -> CGRect? {
        current = point
        if let start, !dragging,
           hypot(point.x - start.x, point.y - start.y) >= threshold { dragging = true }
        return rectangle
    }

    mutating func move(to point: CGPoint) -> CGRect? {
        current = point
        return rectangle
    }

    mutating func finish(at point: CGPoint) -> CGRect? {
        current = point
        return rectangle
    }

    mutating func cancel() {
        start = nil; current = nil; dragging = false
    }
}

@MainActor
final class LibraryBrowserBridge: ObservableObject {
    fileprivate var revealHandler: ((BrowserRevealRequest, @escaping (CGRect?) -> Void) -> Void)?
    fileprivate var focusHandler: (() -> Void)?

    func reveal(_ request: BrowserRevealRequest, completion: @escaping (CGRect?) -> Void = { _ in }) {
        guard let revealHandler else { completion(nil); return }
        final class CompletionGate {
            var completed = false
            let completion: (CGRect?) -> Void
            init(_ completion: @escaping (CGRect?) -> Void) { self.completion = completion }
            func finish(_ rect: CGRect?) {
                guard !completed else { return }
                completed = true
                completion(rect)
            }
        }
        let gate = CompletionGate(completion)
        revealHandler(request) { gate.finish($0) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            gate.finish(nil)
        }
    }

    func focusTimeline() { focusHandler?() }
}

struct LibraryBrowserView: View {
    let collection: PhotoCollectionDescriptor
    var restorationAnchor: PhotoTimelineRestorationAnchor?
    let bridge: LibraryBrowserBridge
    var contentTopInset: CGFloat = 0
    var onOpenPhoto: (PhotoViewerOpenRequest) -> Void = { _ in }
    var onRestorationAnchorChanged: (PhotoTimelineRestorationAnchor) -> Void = { _ in }
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDay: String?
    @State private var jumpRequest: DayJumpRequest?

    private var selection: Binding<Int> {
        Binding(
            get: { library.snapshot(for: collection)?.timeline.index(keeping: selectedDay) ?? 0 },
            set: { index in
                guard let days = library.snapshot(for: collection)?.timeline.days, days.indices.contains(index) else { return }
                let day = days[index].id
                selectedDay = day
                jumpRequest = DayJumpRequest(dayID: day)
            }
        )
    }

    var body: some View {
        Group {
            if let snapshot = library.snapshot(for: collection), !snapshot.timeline.days.isEmpty,
               let repository = library.repository {
                HStack(spacing: 0) {
                    LibraryBrowserScrollView(snapshot: snapshot,
                                             collection: collection,
                                             revision: library.snapshotRevision(for: collection),
                                             retryRevision: library.retryRevision,
                                             repository: repository, allowNetwork: library.timelineVerified(for: collection),
                                             thumbnailSize: library.thumbnailSize,
                                             itemsPerRow: library.itemsPerRow,
                                             selectionState: library.selectionState(for: collection),
                                             restorationAnchor: restorationAnchor,
                                             bridge: bridge,
                                             jumpToDay: jumpRequest,
                                             unavailableOffline: library.error(for: collection) != nil || library.authenticationFailed,
                                             colorScheme: colorScheme,
                                             contentTopInset: contentTopInset,
                                             onOpenPhoto: onOpenPhoto,
                                             onSelectionStateChanged: { library.setSelectionState($0, for: collection) },
                                             onCommandStateChanged: { snapshot, handler in
                                                 library.installBrowserCommands(snapshot: snapshot, handler: handler)
                                             },
                                             onRestorationAnchorChanged: onRestorationAnchorChanged,
                                             onRetry: { Task { await library.reload() } }) { day in
                        if snapshot.timeline.days.contains(where: { $0.id == day }) { selectedDay = day }
                    }
                    TimelineNavigator(timeline: snapshot.timeline, selected: selection)
                        .frame(width: 72)
                        .padding(.top, contentTopInset + 16)
                        .padding(.bottom, 16)
                        .padding(.trailing, 6)
                }
            } else if library.snapshot(for: collection)?.timeline.days.isEmpty == true {
                ContentUnavailableView(collection == .favorites ? "No favorites" : "No photos",
                    systemImage: collection == .favorites ? "heart" : "photo",
                    description: Text(library.error(for: collection) != nil ? "Cached collection is empty. Connection unavailable." :
                        (library.timelineVerified(for: collection) ?
                         (collection == .favorites ? "No photos are marked as favorites." : "Personal Space is empty.") :
                         "Cached collection is empty. Checking Cirrus…")))
            } else if let error = library.error(for: collection), library.snapshot(for: collection) == nil {
                ContentUnavailableView {
                    Label("Library unavailable", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await library.reload() } }.disabled(library.isLoading)
                }
            } else {
                ProgressView(collection == .favorites ? "Opening favorites…" : "Opening library…")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: library.snapshotRevision(for: collection)) { _, _ in
            guard let timeline = library.snapshot(for: collection)?.timeline,
                  let index = timeline.index(keeping: selectedDay) else { selectedDay = nil; return }
            selectedDay = timeline.days[index].id
        }
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var interaction: ((InteractionPhase) -> Void)?
    var commandHandler: ((BrowserSelectionCommand) -> Void)?
    weak var timelineScrollView: TimelineScrollView?
    weak var overlay: SelectionOverlayView?
    var selectionFrames: [CGRect] = [] { didSet { overlay?.selectionFrames = selectionFrames } }
    var marquee: CGRect? { didSet { overlay?.marquee = marquee } }
    private var downPoint: CGPoint?

    enum InteractionPhase {
        case down(CGPoint, clickCount: Int, shift: Bool)
        case drag(CGPoint)
        case up(CGPoint)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        interaction?(.down(point, clickCount: event.clickCount,
                           shift: event.modifierFlags.contains(.shift)))
    }
    override func mouseDragged(with event: NSEvent) {
        interaction?(.drag(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        interaction?(.up(convert(event.locationInWindow, from: nil)))
        downPoint = nil
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { timelineScrollView?.publishFocusState() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { timelineScrollView?.focusChanged?(false) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard let command = event.browserSelectionCommand else {
            super.keyDown(with: event)
            return
        }
        commandHandler?(command)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift) { commandHandler?(.endExtension) }
        super.flagsChanged(with: event)
    }
}

extension NSEvent {
    var browserSelectionCommand: BrowserSelectionCommand? {
        let disallowed = modifierFlags.intersection([.command, .option, .control])
        guard disallowed.isEmpty else { return nil }
        switch keyCode {
        case 123: return .move(.left, extending: modifierFlags.contains(.shift))
        case 124: return .move(.right, extending: modifierFlags.contains(.shift))
        case 126: return .move(.up, extending: modifierFlags.contains(.shift))
        case 125: return .move(.down, extending: modifierFlags.contains(.shift))
        case 49 where !modifierFlags.contains(.shift): return .openSelected
        default: return nil
        }
    }
}

final class SelectionOverlayView: NSView {
    override var isFlipped: Bool { true }
    var selectionFrames: [CGRect] = [] { didSet { needsDisplay = true } }
    var marquee: CGRect? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemBlue.setStroke()
        for frame in selectionFrames {
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
            path.lineWidth = 3
            path.stroke()
        }
        if let marquee {
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: marquee).fill()
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: marquee); path.lineWidth = 1; path.stroke()
        }
    }
}

final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassThroughSourceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class BrowserSelectionObservation: ObservableObject {
    @Published var indexes = IndexSet()
}

/// Owns timeline scrolling and tracks whether its document or an accessibility item has focus.
final class TimelineScrollView: NSScrollView {
    var focusChanged: ((Bool) -> Void)?
    weak var keyboardResponder: NSView?

    var browserCommandContextActive: Bool {
        guard let window, window.isKeyWindow else { return false }
        if window.firstResponder === keyboardResponder { return true }
        return (window.firstResponder as? ThumbnailActivationSurface.ActivationView)?.enclosingScrollView === self
    }

    @discardableResult
    func focusTimeline() -> Bool {
        guard let keyboardResponder else { return false }
        return window?.makeFirstResponder(keyboardResponder) == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateChanged(_:)),
                                                   name: name, object: window)
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if window.isKeyWindow,
               window.firstResponder == nil || window.firstResponder === window {
                self.focusTimeline()
            }
            self.publishFocusState()
        }
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        if notification.name == NSWindow.didBecomeKeyNotification, let window,
           window.firstResponder == nil || window.firstResponder === window {
            focusTimeline()
        }
        publishFocusState()
    }

    func publishFocusState() { focusChanged?(browserCommandContextActive) }

    override func mouseDown(with event: NSEvent) {
        focusTimeline()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        focusTimeline()
        super.scrollWheel(with: event)
    }
}

private struct HostedRow: View {
    let row: LibraryViewportGeometry.Row
    let repository: CachedPhotosRepository
    let size: ThumbnailSize
    let pages: [Int: LibraryPage]
    let onSelect: (Int) -> Void
    let onCommand: (BrowserSelectionCommand) -> Void
    let onOpenPhoto: (Int, PhotoViewerOpenRequest) -> Void
    @ObservedObject var selection: BrowserSelectionObservation

    var body: some View {
        HStack(alignment: .top, spacing: row.layout.gap) {
            ForEach(row.layout.cells.indices, id: \.self) { position in
                let cell = row.layout.cells[position]
                if let item = row.slots[position] {
                    let ratio = max(0.0001, item.photo.displayAspectRatio)
                    let fittedWidth = min(cell.width, row.layout.height * ratio)
                    let fittedHeight = min(row.layout.height, cell.width / ratio)
                    ThumbnailCell(item: item.photo, repository: repository,
                                  size: size, allowNetwork: item.verified,
                                  isSelected: selection.indexes.contains(item.ordinal),
                                  onSelect: { onSelect(item.ordinal) },
                                  onCommand: onCommand) { source in
                        let page = pages[item.sectionIndex]
                        let seed = PhotoViewerSeed(sectionIndex: item.sectionIndex,
                            pageOffset: item.pageOffset, item: item.photo, page: page?.items,
                            pageVerified: page?.verified ?? item.verified)
                        onOpenPhoto(item.ordinal, PhotoViewerOpenRequest(seed: seed, source: source))
                    }
                        .frame(width: fittedWidth, height: fittedHeight)
                        .frame(width: cell.width, height: row.layout.height)
                } else {
                    Color.clear.frame(width: cell.width, height: row.layout.height)
                }
            }
        }
        .frame(width: row.layout.width, height: row.layout.height, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HostedPlaceholder: View {
    let message: String
    var body: some View {
        Text(message).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
    }
}

struct LibraryBrowserScrollView: NSViewRepresentable {
    let snapshot: TimelineSnapshot
    let collection: PhotoCollectionDescriptor
    let revision: Int
    let retryRevision: Int
    let repository: CachedPhotosRepository
    let allowNetwork: Bool
    let thumbnailSize: ThumbnailSize
    let itemsPerRow: Int
    let selectionState: BrowserSelectionState
    let restorationAnchor: PhotoTimelineRestorationAnchor?
    let bridge: LibraryBrowserBridge
    let jumpToDay: DayJumpRequest?
    let unavailableOffline: Bool
    let colorScheme: ColorScheme
    let contentTopInset: CGFloat
    let onOpenPhoto: (PhotoViewerOpenRequest) -> Void
    let onSelectionStateChanged: (BrowserSelectionState) -> Void
    let onCommandStateChanged: (BrowserCommandSnapshot, ((BrowserSelectionCommand) -> Void)?) -> Void
    let onRestorationAnchorChanged: (PhotoTimelineRestorationAnchor) -> Void
    let onRetry: () -> Void
    let onVisibleDay: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let document = FlippedDocumentView()
        let overlay = SelectionOverlayView()
        document.overlay = overlay
        document.addSubview(overlay)
        scroll.documentView = document
        scroll.keyboardResponder = document
        document.timelineScrollView = scroll
        context.coordinator.scroll = scroll
        context.coordinator.document = document
        document.commandHandler = { [weak coordinator = context.coordinator] command in
            coordinator?.perform(command)
        }
        scroll.focusChanged = { [weak coordinator = context.coordinator] active in
            coordinator?.publishCommandState(active: active)
        }
        document.interaction = { [weak coordinator = context.coordinator] phase in
            coordinator?.interact(phase)
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.viewportChanged() }
        }
        context.coordinator.configure(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.configure(self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var scroll: NSScrollView?
        fileprivate weak var document: FlippedDocumentView?
        var observer: NSObjectProtocol?
        private var index: LibraryIndex?
        private var geometry: LibraryViewportGeometry?
        private var window: LibraryPageWindow?
        private var pages: [Int: LibraryPage] = [:]
        private var errors: [Int: String] = [:]
        private var pageSignatures: [Int: Int] = [:]
        private var rowRevisions: [Int: Int] = [:]
        private var viewRevision = 0
        private var hosts: [String: NSHostingView<AnyView>] = [:]
        private var hostRevisions: [String: (Int, Int)] = [:]
        private var eventTask: Task<Void, Never>?
        private var demandTask: Task<Void, Never>?
        private var revision = -1
        private var retryRevision = 0
        private var allowNetwork = false
        private var thumbnailSize: ThumbnailSize = .m
        private var repository: CachedPhotosRepository?
        private var collection: PhotoCollectionDescriptor = .personalLibrary
        private var onVisibleDay: ((String) -> Void)?
        private var lastVisibleDay: String?
        private var unavailableOffline = false
        private var colorScheme: ColorScheme = .light
        private var onRetry: (() -> Void)?
        private var onOpenPhoto: ((PhotoViewerOpenRequest) -> Void)?
        private var onSelectionStateChanged: ((BrowserSelectionState) -> Void)?
        private var onCommandStateChanged: ((BrowserCommandSnapshot, ((BrowserSelectionCommand) -> Void)?) -> Void)?
        private var onRestorationAnchorChanged: ((PhotoTimelineRestorationAnchor) -> Void)?
        private var demandedVisible: [Int] = []
        private var demandedPrefetch: [Int] = []
        private var suppressFeedback = false
        private var scrollIntent = BrowserScrollIntentCoordinator()
        private var feedbackTask: Task<Void, Never>?
        private var restorationFeedbackTask: Task<Void, Never>?
        private var pendingReveal: (id: UUID, completion: (CGRect?) -> Void)?
        private var selectionState = BrowserSelectionState()
        private var selection: LibrarySelection {
            get { selectionState.selection }
            set { selectionState.selection = newValue }
        }
        private let selectionObservation = BrowserSelectionObservation()
        private let commandOwner = UUID()
        private var pointer = BrowserPointerInteraction()
        private var pointerShift = false
        private var marqueeSelection: BrowserMarqueeSelection?
        private var autoscrollTask: Task<Void, Never>?
        private var pendingOpen: BrowserPendingOpen?
        private var selectionEpoch: UInt64 = 0
        private var selectAfterRevealItemID: Int64?
        private weak var sourceProxy: NSView?

        func configure(_ input: LibraryBrowserScrollView) {
            guard let scroll else { return }
            collection = input.collection
            onVisibleDay = input.onVisibleDay
            onRetry = input.onRetry
            onOpenPhoto = input.onOpenPhoto
            onSelectionStateChanged = input.onSelectionStateChanged
            onCommandStateChanged = input.onCommandStateChanged
            onRestorationAnchorChanged = input.onRestorationAnchorChanged
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
            let insets = NSEdgeInsets(top: input.contentTopInset, left: 0, bottom: 0, right: 0)
            scroll.contentInsets = insets
            let insetsChanged = abs(oldInsets.top - insets.top) > 0.5 ||
                abs(oldInsets.left - insets.left) > 0.5
            if thumbnailSize != input.thumbnailSize { viewRevision += 1 }
            thumbnailSize = input.thumbnailSize
            if colorScheme != input.colorScheme { viewRevision += 1 }
            colorScheme = input.colorScheme
            let width = availableWidth(in: scroll)
            let rebuilding = revision != input.revision
            if rebuilding {
                let oldIndex = index
                let previous = geometry?.anchor(at: visibleTop(in: scroll))
                cancelPointerInteraction()
                pendingOpen = nil
                stopWindow()
                let newIndex = LibraryIndex(snapshot: input.snapshot)
                index = newIndex
                geometry = LibraryViewportGeometry(index: newIndex, width: width,
                                                   itemsPerRow: input.itemsPerRow)
                selectionState = input.selectionState
                selectionState.bind(to: newIndex.fingerprint)
                publishSelection()
                revision = input.revision
                allowNetwork = input.allowNetwork
                window = LibraryPageWindow(repository: input.repository,
                                           collection: input.collection, maximumPages: 8)
                updateDocumentHeight()
                if let geometry, let target = scrollIntent.rebuild(index: newIndex, geometry: geometry,
                    previousIndex: oldIndex, visibleAnchor: previous, timelineVerified: input.allowNetwork) {
                    scrollTo(target)
                }
                startEvents()
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
                if let current = geometry,
                   abs(current.width - width) > 0.5 || current.itemsPerRow != input.itemsPerRow {
                    let anchor = current.anchor(at: visibleTop(in: scroll))
                    geometry?.setLayout(width: width, itemsPerRow: input.itemsPerRow,
                                        pages: pages)
                    selection.endExtension()
                    cancelPointerInteraction()
                    pendingOpen = nil
                    viewRevision += 1
                    updateDocumentHeight()
                    if let anchor, let target = geometry?.y(for: anchor) { scrollTo(target) }
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
        }

        private func stopWindow() {
            eventTask?.cancel()
            demandTask?.cancel()
            if let window { Task { await window.cancelAll() } }
            eventTask = nil
            demandTask = nil
            window = nil
            pages.removeAll()
            errors.removeAll()
            pageSignatures.removeAll()
            rowRevisions.removeAll()
            demandedVisible = []
            demandedPrefetch = []
            hosts.values.forEach { $0.removeFromSuperview() }
            hosts.removeAll()
            hostRevisions.removeAll()
        }

        private func startEvents() {
            guard let window else { return }
            eventTask = Task { [weak self] in
                for await event in await window.events() {
                    guard let self, !Task.isCancelled else { break }
                    switch event {
                    case .failure(let section, let message):
                        self.errors[section] = message
                        self.rowRevisions[section, default: 0] += 1
                    case .page: break
                    case .removed: break
                    }
                    // Events use a bounded newest buffer, so reconcile against the authoritative window.
                    let retained = await window.retainedPages()
                    guard !Task.isCancelled, self.window === window else { break }
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
                    self.viewRevision += 1
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
            if let current = geometry {
                let width = availableWidth(in: scroll)
                if abs(current.width - width) > 0.5 {
                    let anchor = current.anchor(at: visibleTop(in: scroll))
                    geometry?.setLayout(width: width, itemsPerRow: current.itemsPerRow,
                                        pages: pages)
                    selection.endExtension()
                    cancelPointerInteraction()
                    pendingOpen = nil
                    viewRevision += 1
                    updateDocumentHeight()
                    if let anchor, let target = geometry?.y(for: anchor) { scrollTo(target) }
                }
            }
            guard let geometry, let index,
                  let repository, !geometry.slices.isEmpty else { return }
            let visible = scroll.contentView.bounds
            let y = visibleTop(in: scroll)
            let height = visibleHeight(in: scroll)
            let clipY = Double(visible.minY)
            scrollIntent.viewportMoved(to: clipY)
            cancelSupersededReveal()
            let overscan = min(240, height * 0.35)
            let range = geometry.sliceRange(y: max(0, y - overscan), height: height + 2 * overscan)
            var wanted: Set<String> = []
            let visibleSections = geometry.sectionIndices(y: max(0, y - overscan),
                                                          height: height + 2 * overscan)
            for position in range {
                let slice = geometry.slices[position]
                let section = slice.source.sectionIndex
                if slice.heading {
                    addHost("h:\(position)", frame: CGRect(x: 0, y: slice.y, width: geometry.width, height: 32),
                            content: AnyView(Text(slice.source.dayID).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)),
                            revision: (viewRevision, 0), wanted: &wanted, document: document)
                }
                if let page = pages[section] {
                    if page.items.count <= slice.source.pageRange.lowerBound {
                        addHost("e:\(position)",
                                frame: CGRect(x: 0, y: slice.y + (slice.heading ? 38 : 0),
                                              width: geometry.width, height: 28),
                                content: AnyView(HostedPlaceholder(message: "No photos in this section")),
                                revision: (viewRevision, rowRevisions[section] ?? 0),
                                wanted: &wanted, document: document)
                    }
                } else {
                    let message = errors[section] ?? (unavailableOffline ? "Unavailable offline" : "Loading photos…")
                    addHost("p:\(position)",
                            frame: CGRect(x: 0, y: slice.y + (slice.heading ? 38 : 0),
                                          width: geometry.width, height: 28),
                            content: AnyView(HStack {
                                HostedPlaceholder(message: message)
                                if errors[section] != nil { Button("Retry", action: onRetry ?? {}) }
                            }),
                            revision: (viewRevision, rowRevisions[section] ?? 0),
                            wanted: &wanted, document: document)
                }
                for (rowIndex, row) in geometry.rows(in: position).enumerated() {
                    let rowY = slice.y + row.y
                    guard rowY + row.layout.height >= y - overscan,
                          rowY <= y + height + overscan else { continue }
                    addHost("r:\(position):\(rowIndex)",
                            frame: CGRect(x: 0, y: rowY, width: geometry.width, height: row.layout.height),
                            content: AnyView(HostedRow(row: row, repository: repository,
                                                       size: thumbnailSize, pages: pages,
                                                       onSelect: { [weak self] in self?.selectFromAccessibility($0) },
                                                       onCommand: { [weak self] in self?.perform($0) },
                                                       onOpenPhoto: { [weak self] ordinal, request in
                                                           self?.openFromAccessibility(ordinal, request: request)
                                                       },
                                                       selection: selectionObservation)),
                            revision: (viewRevision, rowRevisions[section] ?? 0),
                            wanted: &wanted, document: document, passThrough: true)
                }
            }
            for key in hosts.keys where !wanted.contains(key) {
                hosts.removeValue(forKey: key)?.removeFromSuperview()
                hostRevisions.removeValue(forKey: key)
            }
            if !suppressFeedback {
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
            // At most eight current pages, plus immediate neighbors in either direction.
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
            if demandedSections != demandedVisible || prefetch != demandedPrefetch {
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

        private func reveal(_ request: BrowserRevealRequest, completion: @escaping (CGRect?) -> Void) {
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

        private func finishRevealIfPossible(id: UUID, itemID: Int64) {
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

        private func finishReveal(id: UUID, rect: CGRect?) {
            guard scrollIntent.finishReveal(id: id), pendingReveal?.id == id else { return }
            let completion = pendingReveal?.completion
            pendingReveal = nil
            completion?(rect)
            scheduleRestorationFeedback()
        }

        private func cancelSupersededReveal() {
            guard let pendingReveal, pendingReveal.id != scrollIntent.revealID else { return }
            self.pendingReveal = nil
            selectAfterRevealItemID = nil
            pendingReveal.completion(nil)
        }

        func publishCommandState(active: Bool) {
            let active = active && (scroll as? TimelineScrollView)?.browserCommandContextActive == true
            if !active { cancelPointerInteraction(); selection.endExtension(); pendingOpen = nil }
            let canOpen = active && selection.count == 1 && selection.first.flatMap(loadedItem)?.photo.type != "video"
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
                knownItemIDsByOrdinal: knownItemIDs
            )
            DispatchQueue.main.async { callback?(snapshot, handler) }
        }

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
            case .down(let point, let clickCount, let shift):
                (scroll as? TimelineScrollView)?.focusTimeline()
                pointer.begin(at: point); pointerShift = shift
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
                        if pointerShift { selection.add(ordinal) } else { selection.replace(with: ordinal) }
                    } else if !pointerShift { selection.replace(with: nil) }
                    publishSelection()
                }
            }
        }

        private func publishSelection() {
            selectionEpoch &+= 1
            pendingOpen = nil
            selectionObservation.indexes = selection.indexes
            persistSelectionState()
            updateSelectionDrawing()
            if let scroll = scroll as? TimelineScrollView {
                publishCommandState(active: scroll.browserCommandContextActive)
            }
        }

        private func persistSelectionState() {
            let value = selectionState, callback = onSelectionStateChanged
            DispatchQueue.main.async { callback?(value) }
        }

        private func updateSelectionDrawing() {
            guard let geometry else { document?.selectionFrames = []; return }
            document?.selectionFrames = geometry.frames(for: selection.indexes)
        }

        private func loadedItem(_ ordinal: Int) -> LibraryViewportGeometry.RowItem? {
            guard let location = index?.location(forOrdinal: ordinal), let page = pages[location.sectionIndex],
                  page.items.indices.contains(location.pageOffset) else { return nil }
            return LibraryViewportGeometry.RowItem(photo: page.items[location.pageOffset], verified: page.verified,
                sectionIndex: location.sectionIndex, pageOffset: location.pageOffset, ordinal: ordinal)
        }

        private func selectFromAccessibility(_ ordinal: Int) {
            selection.replace(with: ordinal)
            scrollIntent.selectionNavigation()
            publishSelection()
        }

        private func openFromAccessibility(_ ordinal: Int, request: PhotoViewerOpenRequest) {
            guard loadedItem(ordinal)?.photo.type != "video" else { return }
            selectFromAccessibility(ordinal)
            onOpenPhoto?(request)
        }

        private func revealSelectionCursor(_ ordinal: Int) {
            guard let scroll, let frame = geometry?.slotFrame(for: ordinal) else { return }
            let top = visibleTop(in: scroll), bottom = top + visibleHeight(in: scroll)
            if frame.minY < top { scrollTo(frame.minY) }
            else if frame.maxY > bottom { scrollTo(frame.maxY - visibleHeight(in: scroll)) }
            viewportChanged()
        }

        private func open(ordinal: Int) {
            if loadedItem(ordinal)?.photo.type == "video" { pendingOpen = nil; return }
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
                    item: item.photo, page: page?.items, pageVerified: page?.verified ?? item.verified)
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
                item: item.photo, page: page?.items, pageVerified: page?.verified ?? item.verified)
            onOpenPhoto?(PhotoViewerOpenRequest(seed: seed, source: anchor))
        }

        private func openPendingIfPossible() {
            guard let request = pendingOpen,
                  request.matches(selection: selection, generation: selectionState.generation,
                                  selectionEpoch: selectionEpoch) else {
                pendingOpen = nil; return
            }
            if loadedItem(request.ordinal) != nil { open(ordinal: request.ordinal) }
        }

        private func autoScroll(for point: CGPoint) {
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

        private func updateMarquee(_ rectangle: CGRect, geometry: LibraryViewportGeometry) {
            document?.marquee = rectangle
            guard var marqueeSelection else { return }
            selection.replace(with: marqueeSelection.update(rectangle: rectangle,
                loadedFrames: geometry.loadedFramesByOrdinal()))
            self.marqueeSelection = marqueeSelection
            publishSelection()
        }

        private func refreshMarqueeSelection() {
            guard let rectangle = pointer.rectangle, let geometry else { return }
            updateMarquee(rectangle, geometry: geometry)
        }

        private func startAutoscrollIfNeeded() {
            guard autoscrollTask == nil else { return }
            autoscrollTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.pointer.dragging {
                    if let point = self.pointer.current { self.autoScroll(for: point) }
                    try? await Task.sleep(for: .milliseconds(35))
                }
            }
        }

        private func cancelPointerInteraction() {
            pointer.cancel()
            marqueeSelection = nil
            autoscrollTask?.cancel(); autoscrollTask = nil
            document?.marquee = nil
        }

        private func scheduleRestorationFeedback() {
            restorationFeedbackTask?.cancel()
            restorationFeedbackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled else { return }
                self.emitCurrentRestorationAnchor()
            }
        }

        private func emitCurrentRestorationAnchor() {
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

        private func addHost(_ key: String, frame: CGRect, content: AnyView,
                             revision: (Int, Int), wanted: inout Set<String>, document: NSView,
                             passThrough: Bool = false) {
            wanted.insert(key)
            if let host = hosts[key] {
                host.frame = frame
                if let previous = hostRevisions[key], previous != revision {
                    host.rootView = AnyView(content.environment(\.colorScheme, colorScheme))
                    hostRevisions[key] = revision
                }
            } else {
                let root = AnyView(content.environment(\.colorScheme, colorScheme))
                let host: NSHostingView<AnyView> = passThrough ?
                    PassThroughHostingView(rootView: root) : NSHostingView(rootView: root)
                host.frame = frame
                if let overlay = (document as? FlippedDocumentView)?.overlay {
                    document.addSubview(host, positioned: .below, relativeTo: overlay)
                } else { document.addSubview(host) }
                hosts[key] = host
                hostRevisions[key] = revision
            }
        }

        private func updateDocumentHeight() {
            guard let scroll, let document, let geometry else { return }
            let frame = CGRect(x: 0, y: 0, width: CGFloat(availableWidth(in: scroll)),
                               height: max(CGFloat(geometry.totalHeight), scroll.contentSize.height))
            if document.frame != frame { document.frame = frame }
            document.overlay?.frame = document.bounds
        }

        private func scrollTo(_ y: Double) {
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

        private static func signature(_ page: LibraryPage) -> Int {
            var hash = Hasher()
            hash.combine(page.verified)
            hash.combine(page.items.count)
            for item in page.items {
                hash.combine(item.id)
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

        private static func membershipSignature(_ page: LibraryPage) -> Int {
            var hash = Hasher()
            hash.combine(page.items.count)
            for item in page.items { hash.combine(item.id) }
            return hash.finalize()
        }

        private func availableWidth(in scroll: NSScrollView) -> Double {
            max(1, Double(scroll.contentSize.width - scroll.contentInsets.left - scroll.contentInsets.right))
        }

        private func visibleTop(in scroll: NSScrollView) -> Double {
            max(0, Double(scroll.contentView.bounds.minY + scroll.contentInsets.top))
        }

        private func visibleHeight(in scroll: NSScrollView) -> Double {
            max(1, Double(scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom))
        }
    }
}
