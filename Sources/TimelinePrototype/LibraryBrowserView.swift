import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

struct LibraryBrowserView: View {
    let isActive: Bool
    @EnvironmentObject private var library: LibraryModel
    @State private var selectedDay: String?
    @State private var jumpRequest: DayJumpRequest?

    private var selection: Binding<Int> {
        Binding(
            get: { library.snapshot?.timeline.index(keeping: selectedDay) ?? 0 },
            set: { index in
                guard let days = library.snapshot?.timeline.days, days.indices.contains(index) else { return }
                let day = days[index].id
                selectedDay = day
                jumpRequest = DayJumpRequest(dayID: day)
            }
        )
    }

    var body: some View {
        Group {
            if !isActive {
                Color.clear
            } else if let snapshot = library.snapshot, !snapshot.timeline.days.isEmpty,
               let repository = library.repository {
                HStack(spacing: 0) {
                    LibraryBrowserScrollView(snapshot: snapshot,
                                             revision: library.snapshotRevision,
                                             retryRevision: library.retryRevision,
                                             repository: repository, allowNetwork: library.timelineVerified,
                                             thumbnailSize: library.thumbnailSize, jumpToDay: jumpRequest,
                                             unavailableOffline: library.error != nil || library.authenticationFailed,
                                             onRetry: { Task { await library.reload() } }) { day in
                        if snapshot.timeline.days.contains(where: { $0.id == day }) { selectedDay = day }
                    }
                    TimelineNavigator(timeline: snapshot.timeline, selected: selection)
                        .frame(width: 190).padding(.vertical, 24).padding(.trailing, 16)
                }
            } else if library.snapshot?.timeline.days.isEmpty == true {
                ContentUnavailableView("No photos", systemImage: "photo",
                    description: Text(library.error != nil ? "Cached library is empty. Connection unavailable." :
                        (library.timelineVerified ? "Personal Space is empty." : "Cached library is empty. Checking Cirrus…")))
            } else if let error = library.error, library.snapshot == nil {
                ContentUnavailableView {
                    Label("Library unavailable", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await library.reload() } }.disabled(library.isLoading)
                }
            } else {
                ProgressView("Opening library…")
            }
        }
        .background(Color(red: 0.065, green: 0.065, blue: 0.07))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack { Spacer(); connectionIndicator.padding(.trailing, 16).padding(.vertical, 5) }
                .background(Color(red: 0.065, green: 0.065, blue: 0.07))
        }
        .onChange(of: library.snapshotRevision) { _, _ in
            guard let timeline = library.snapshot?.timeline,
                  let index = timeline.index(keeping: selectedDay) else { selectedDay = nil; return }
            selectedDay = timeline.days[index].id
        }
        .onChange(of: isActive) { _, active in
            if !active, let selectedDay { jumpRequest = DayJumpRequest(dayID: selectedDay) }
        }
    }

    @ViewBuilder private var connectionIndicator: some View {
        HStack(spacing: 6) {
            switch library.authenticationStatus {
            case .notStarted:
                Text(library.error == nil ? "Opening library…" : "Library unavailable")
            case .loggingIn:
                ProgressView().controlSize(.mini)
                Text("Logging in…")
            case .signedIn:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(library.error == nil ? "Connected" : "Connected · Metadata unavailable")
                    .help(library.error ?? "Signed in")
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("Login failed").help(message)
            }
            Button("Retry") { Task { await library.reload() } }
                .controlSize(.small).disabled(library.isLoading)
        }
        .font(.caption)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }
}

fileprivate final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct HostedRow: View {
    let row: LibraryViewportGeometry.Row
    let repository: CachedPhotosRepository
    let size: ThumbnailSize

    var body: some View {
        HStack(alignment: .top, spacing: row.layout.gap) {
            ForEach(row.layout.cells.indices, id: \.self) { position in
                let cell = row.layout.cells[position]
                let item = row.items[position]
                ThumbnailCell(item: item.photo, repository: repository,
                              size: size, allowNetwork: item.verified)
                    .frame(width: cell.width, height: row.layout.height)
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
    let revision: Int
    let retryRevision: Int
    let repository: CachedPhotosRepository
    let allowNetwork: Bool
    let thumbnailSize: ThumbnailSize
    let jumpToDay: DayJumpRequest?
    let unavailableOffline: Bool
    let onRetry: () -> Void
    let onVisibleDay: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let document = FlippedDocumentView()
        scroll.documentView = document
        context.coordinator.scroll = scroll
        context.coordinator.document = document
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
        private var onVisibleDay: ((String) -> Void)?
        private var lastVisibleDay: String?
        private var lastJump: UUID?
        private var unavailableOffline = false
        private var onRetry: (() -> Void)?
        private var demandedVisible: [Int] = []
        private var demandedPrefetch: [Int] = []
        private var suppressFeedback = false
        private var pendingAnchor: LibraryViewportGeometry.Anchor?
        private var feedbackTask: Task<Void, Never>?
        private var programmaticY: Double?

        func configure(_ input: LibraryBrowserScrollView) {
            guard let scroll else { return }
            onVisibleDay = input.onVisibleDay
            onRetry = input.onRetry
            repository = input.repository
            if thumbnailSize != input.thumbnailSize { viewRevision += 1 }
            thumbnailSize = input.thumbnailSize
            let width = max(1, Double(scroll.contentSize.width))
            if revision != input.revision {
                let previous = geometry?.anchor(at: Double(scroll.contentView.bounds.minY))
                stopWindow()
                let newIndex = LibraryIndex(snapshot: input.snapshot)
                index = newIndex
                geometry = LibraryViewportGeometry(index: newIndex, width: width)
                revision = input.revision
                allowNetwork = input.allowNetwork
                window = LibraryPageWindow(repository: input.repository, maximumPages: 8)
                pendingAnchor = previous
                updateDocumentHeight()
                if let previous, let geometry {
                    let day = geometry.nearestDay(to: previous.dayID, orderedDays: newIndex.dayIDs)
                    let target = geometry.y(for: previous) ?? day.flatMap { geometry.y(forDay: $0) } ?? 0
                    scrollTo(target)
                }
                startEvents()
            } else {
                if allowNetwork != input.allowNetwork {
                    allowNetwork = input.allowNetwork
                    viewRevision += 1
                    demandedVisible = []
                    demandedPrefetch = []
                }
                if let current = geometry, abs(current.width - width) > 0.5 {
                    let anchor = current.anchor(at: Double(scroll.contentView.bounds.minY))
                    geometry?.setWidth(width, pages: pages)
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
            if let request = input.jumpToDay, request.id != lastJump {
                lastJump = request.id
                jump(to: request.dayID)
            }
            viewportChanged()
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            feedbackTask?.cancel()
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
                    let anchor = self.geometry?.anchor(at: Double(self.scroll?.contentView.bounds.minY ?? 0))
                    self.pages = Dictionary(uniqueKeysWithValues: retained.map { ($0.sectionIndex, $0) })
                    let newSignatures = Dictionary(uniqueKeysWithValues: retained.map {
                        ($0.sectionIndex, Self.signature($0))
                    })
                    for (section, signature) in newSignatures where self.pageSignatures[section] != signature {
                        self.rowRevisions[section, default: 0] += 1
                    }
                    self.pageSignatures = newSignatures
                    self.errors = self.errors.filter { self.demandedVisible.contains($0.key) }
                    self.geometry?.reconcile(pages: self.pages)
                    self.viewRevision += 1
                    self.updateDocumentHeight()
                    if let pending = self.pendingAnchor, let itemID = pending.itemID,
                       let exact = self.geometry?.y(forItem: itemID, offset: pending.localOffset) {
                        self.scrollTo(exact)
                        self.pendingAnchor = nil
                    } else if let anchor, let target = self.geometry?.y(for: anchor) {
                        self.scrollTo(target)
                    }
                    self.viewportChanged()
                }
            }
        }

        func viewportChanged() {
            guard let scroll, let document else { return }
            if let current = geometry {
                let width = max(1, Double(scroll.contentSize.width))
                if abs(current.width - width) > 0.5 {
                    let anchor = current.anchor(at: Double(scroll.contentView.bounds.minY))
                    geometry?.setWidth(width, pages: pages)
                    viewRevision += 1
                    updateDocumentHeight()
                    if let anchor, let target = geometry?.y(for: anchor) { scrollTo(target) }
                }
            }
            guard let geometry, let index,
                  let repository, !geometry.slices.isEmpty else { return }
            let visible = scroll.contentView.bounds
            let y = Double(visible.minY), height = Double(visible.height)
            if let programmaticY, abs(y - programmaticY) > 2 {
                pendingAnchor = nil
                self.programmaticY = nil
            }
            let overscan = min(240, height * 0.35)
            let range = geometry.sliceRange(y: max(0, y - overscan), height: height + 2 * overscan)
            var wanted: Set<String> = []
            var visibleSections: [Int] = []
            for position in range {
                let slice = geometry.slices[position]
                let section = slice.source.sectionIndex
                if !visibleSections.contains(section) { visibleSections.append(section) }
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
                                                       size: thumbnailSize)),
                            revision: (viewRevision, rowRevisions[section] ?? 0),
                            wanted: &wanted, document: document)
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
            if visibleSections != demandedVisible || prefetch != demandedPrefetch {
                demandedVisible = visibleSections
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
                                            visible: visibleSections, prefetch: prefetch,
                                            retryRevision: retry)
                    }
                }
            }
        }

        private func addHost(_ key: String, frame: CGRect, content: AnyView,
                             revision: (Int, Int), wanted: inout Set<String>, document: NSView) {
            wanted.insert(key)
            if let host = hosts[key] {
                host.frame = frame
                if let previous = hostRevisions[key], previous != revision {
                    host.rootView = content
                    hostRevisions[key] = revision
                }
            } else {
                let host = NSHostingView(rootView: content)
                host.frame = frame
                document.addSubview(host)
                hosts[key] = host
                hostRevisions[key] = revision
            }
        }

        private func updateDocumentHeight() {
            guard let scroll, let document, let geometry else { return }
            let frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width,
                               height: max(CGFloat(geometry.totalHeight), scroll.contentSize.height))
            if document.frame != frame { document.frame = frame }
        }

        private func scrollTo(_ y: Double) {
            guard let scroll, let geometry else { return }
            suppressFeedback = true
            let maximum = max(0, geometry.totalHeight - Double(scroll.contentSize.height))
            let target = min(max(0, y), maximum)
            programmaticY = target
            scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            suppressFeedback = false
        }

        private func jump(to requested: String) {
            pendingAnchor = nil
            guard let geometry, let index,
                  let day = geometry.nearestDay(to: requested, orderedDays: index.dayIDs),
                  let y = geometry.y(forDay: day) else { return }
            scrollTo(y)
            viewportChanged()
        }

        private static func signature(_ page: LibraryPage) -> Int {
            var hash = Hasher()
            hash.combine(page.verified)
            hash.combine(page.items.count)
            for item in page.items {
                hash.combine(item.id)
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
    }
}
