import AppKit
import Darwin
import PhotoCache
import SwiftUI
import SynologyAPI
import UniformTypeIdentifiers

struct PhotoDownloadJob: Identifiable {
    let id: UUID
    var name: String
    var progress: Double?
    var status: String
    var active: Bool
}

enum PhotoDownloadSource: Sendable {
    case item(PhotoItem, collection: PhotoCollectionDescriptor)
    case selection(PhotoSelectionSnapshot)
    case album(Int64)
    case incomingAlbum(PhotoCollectionDescriptor)

    func resolve(repository: CachedPhotosRepository) async throws -> [PhotoItem] {
        let items: [PhotoItem]?
        switch self {
        case .item(let item, _): items = [item]
        case .selection(let selection): items = await SelectionDownloadResolver(repository: repository).resolve(selection)
        case .album(let id): items = await AlbumSelectionResolver(repository: repository).resolve(albumID: id)
        case .incomingAlbum(let collection): items = await AlbumSelectionResolver(repository: repository).resolve(collection: collection)
        }
        try Task.checkCancellation()
        guard let items else { throw DownloadFailure.message("The photos could not be verified.") }
        guard !items.isEmpty else { throw DownloadFailure.message("No eligible photos to download.") }
        return items
    }

    var collection: PhotoCollectionDescriptor {
        switch self {
        case .item(_, let collection): return collection
        case .selection(let selection): return selection.collection
        case .album(let id): return .album(id)
        case .incomingAlbum(let collection): return collection
        }
    }

    var initialName: String {
        if case .item(let item, _) = self { return item.filename ?? "Photo" }
        return "Preparing download…"
    }
}

@MainActor
final class PhotoDownloadManager: ObservableObject {
    static let shared = PhotoDownloadManager()
    @Published private(set) var jobs: [PhotoDownloadJob] = []
    @Published var isPresented = false
    var hasActiveJobs: Bool { jobs.contains { $0.active } }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let editDirectoryProvider: @Sendable () throws -> URL
    private let editorOpener: @MainActor (URL, URL) async throws -> Void

    init(editDirectoryProvider: @escaping @Sendable () throws -> URL = { try PhotoDownloadManager.editDirectory() },
         editorOpener: @escaping @MainActor (URL, URL) async throws -> Void = { file, application in
             _ = try await NSWorkspace.shared.open([file], withApplicationAt: application,
                                                   configuration: NSWorkspace.OpenConfiguration())
         }) {
        self.editDirectoryProvider = editDirectoryProvider
        self.editorOpener = editorOpener
    }

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: AppPreferences.Key.photoDownloadDirectory), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.directory
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func start(repository: CachedPhotosRepository, source: PhotoDownloadSource,
               kind: PhotoDownloadKind, choose: Bool) {
        guard let directory = choose ? chooseDirectory() : Self.directory else { return }
        let id = UUID()
        jobs.insert(PhotoDownloadJob(id: id, name: source.initialName, progress: nil,
                                     status: "Preparing…", active: true), at: 0)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let mediaCollection = await repository.mediaCollection(for: source.collection)
                let items = try await source.resolve(repository: repository)
                update(id) { $0.name = Self.jobName(items); $0.status = "Downloading…" }
                let reusable = mediaCollection.incomingAlbumIdentity == nil && !mediaCollection.isLibraryFilter
                let cached = try await (reusable && items.count == 1 && kind == .original
                    ? repository.cachedOriginalForDownload(items[0], collection: mediaCollection) : nil)
                let result: PhotoDownloadResponse
                if let cached { result = cached }
                else {
                    result = try await repository.downloadPhotos(itemIDs: items.map(\.id), kind: kind, collection: mediaCollection) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.update(id) { if $0.active { $0.progress = progress.fractionCompleted } }
                        }
                    }
                }
                defer { try? FileManager.default.removeItem(at: result.temporaryURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                update(id) { $0.status = "Saving…" }
                let saveTask = Task.detached(priority: .utility) {
                    try Self.save(result.temporaryURL, filename: result.filename, directory: directory)
                }
                let final = try await withTaskCancellationHandler {
                    try await saveTask.value
                } onCancel: { saveTask.cancel() }
                update(id) { $0.progress = 1; $0.status = "Saved to \(final.path)"; $0.active = false }
            } catch {
                update(id) { $0.status = error is CancellationError ? "Cancelled" : reportedFailure(error, operation: "Download"); $0.active = false }
            }
            tasks[id] = nil
        }
    }

    func edit(repository: CachedPhotosRepository, snapshot: TimelineSnapshot?, selection: BrowserCommandSnapshot?,
              item: PhotoItem?, collection: PhotoCollectionDescriptor, applicationURL: URL) {
        let capturedSelection = selection?.captureSelection(timeline: snapshot)
        let id = UUID()
        jobs.insert(PhotoDownloadJob(id: id, name: item?.filename ?? "Preparing photo…", progress: nil,
                                     status: "Preparing…", active: true), at: 0)
        isPresented = true
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var saved: URL?
            do {
                let photo: PhotoItem
                if let item { photo = item }
                else if let capturedSelection {
                    guard let items = await SelectionDownloadResolver(repository: repository).resolve(capturedSelection), items.count == 1,
                        let resolved = items.first else {
                        throw DownloadFailure.message("The photo could not be verified.")
                    }
                    photo = resolved
                } else { throw DownloadFailure.message("No photo is selected.") }
                try Task.checkCancellation()
                let mediaCollection = try await repository.collectionForPhotoEditing(
                    itemID: photo.id, collection: capturedSelection?.collection ?? collection)
                update(id) { $0.name = photo.filename ?? "Photo"; $0.status = "Downloading…" }
                let cached = try await repository.cachedOriginalForDownload(photo, includeLivePhoto: true, collection: mediaCollection)
                let response: PhotoDownloadResponse
                if let cached { response = cached }
                else if photo.mediaKind == .livePhoto {
                    guard let still = try await repository.livePhotoStillForEditing(photo, collection: mediaCollection, progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.update(id) { if $0.active { $0.progress = progress.fractionCompleted } }
                        }
                    }) else { throw DownloadFailure.message("The Live Photo still is unavailable.") }
                    response = still
                }
                else {
                    response = try await repository.downloadPhotos(itemIDs: [photo.id], kind: .original, collection: mediaCollection) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.update(id) { if $0.active { $0.progress = progress.fractionCompleted } }
                        }
                    }
                }
                defer { try? FileManager.default.removeItem(at: response.temporaryURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                update(id) { $0.status = "Saving…" }
                let directoryProvider = editDirectoryProvider
                let saveTask = Task.detached(priority: .utility) {
                    let directory = try directoryProvider()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return try Self.save(response.temporaryURL, filename: response.filename, directory: directory)
                }
                let file = try await withTaskCancellationHandler {
                    try await saveTask.value
                } onCancel: { saveTask.cancel() }
                saved = file
                try Task.checkCancellation()
                update(id) { $0.status = "Opening…" }
                try await editorOpener(file, applicationURL)
                update(id) { $0.progress = 1; $0.status = "Saved to \(file.path)"; $0.active = false }
            } catch {
                let description = error is CancellationError ? "Cancelled" : reportedFailure(error, operation: "File promise")
                update(id) {
                    $0.status = saved.map { "\(description) — file saved to \($0.path)" } ?? description
                    $0.active = false
                }
            }
            tasks[id] = nil
        }
    }

    nonisolated static func editDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DownloadFailure.message("The Documents folder is unavailable.")
        }
        return documents.appendingPathComponent("SynoTimeline Edits", isDirectory: true)
    }

    func fulfillPromise(_ payload: PhotoDragPayload, destination: URL, completion: @escaping (Error?) -> Void) {
        let id = UUID()
        jobs.insert(PhotoDownloadJob(id: id, name: payload.source.initialName,
                                     progress: nil, status: "Preparing…", active: true), at: 0)
        tasks[id] = Task { [weak self] in
            guard let self else { completion(CancellationError()); return }
            do {
                let mediaCollection = await payload.repository.mediaCollection(for: payload.source.collection)
                let items = try await payload.source.resolve(repository: payload.repository)
                update(id) { $0.name = Self.jobName(items); $0.status = "Downloading…" }
                let progress: @Sendable (TransferProgress) -> Void = { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.update(id) { if $0.active { $0.progress = value.fractionCompleted } }
                    }
                }
                let response: PhotoDownloadResponse
                if payload.count == 1 && !payload.forcesArchive, let cached = try await payload.repository.cachedOriginalForDownload(items[0], includeLivePhoto: true, collection: mediaCollection) {
                    response = cached
                } else if payload.count == 1 && !payload.forcesArchive, items[0].mediaKind == .livePhoto {
                    guard let still = try await payload.repository.livePhotoStillForEditing(items[0], collection: mediaCollection, progress: progress) else {
                        throw DownloadFailure.message("The Live Photo still is unavailable.")
                    }
                    response = still
                } else {
                    response = try await payload.repository.downloadPhotos(itemIDs: items.map(\.id), kind: .original, collection: mediaCollection, progress: progress)
                }
                defer { try? FileManager.default.removeItem(at: response.temporaryURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                update(id) { $0.status = "Saving…" }
                let writeTask = Task.detached(priority: .utility) {
                    try Self.writePromise(response.temporaryURL, destination: destination,
                                          makeArchive: (payload.forcesArchive || payload.count > 1) && items.count == 1 &&
                                            response.temporaryURL.pathExtension.lowercased() != "zip")
                }
                try await withTaskCancellationHandler {
                    try await writeTask.value
                } onCancel: { writeTask.cancel() }
                update(id) { $0.progress = 1; $0.status = "Saved to \(destination.path)"; $0.active = false }
                completion(nil)
            } catch {
                update(id) { $0.status = error is CancellationError ? "Cancelled" : reportedFailure(error, operation: "Editor handoff"); $0.active = false }
                completion(error)
            }
            tasks[id] = nil
        }
    }

    nonisolated static func writePromise(_ source: URL, destination: URL, makeArchive: Bool) throws {
        let fm = FileManager.default
        let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("payload")
        try Task.checkCancellation()
        if makeArchive {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            task.arguments = ["-c", "-k", "--keepParent", source.path, staged.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw DownloadFailure.message("Could not create the ZIP archive.") }
        } else { try fm.copyItem(at: source, to: staged) }
        try Task.checkCancellation()
        // The file-promise receiver coordinates this write while waiting for our
        // completion. Coordinating again here would wait on the receiver itself.
        if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        for index in jobs.indices where jobs[index].active {
            jobs[index].active = false
            jobs[index].status = "Cancelled"
        }
    }
    func clearFinished() { jobs.removeAll { !$0.active } }
    private func update(_ id: UUID, _ change: (inout PhotoDownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
    nonisolated static func jobName(_ items: [PhotoItem]) -> String {
        if items.count == 1 { return items[0].filename ?? "Photo" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let times = items.map(\.time)
        let first = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(times.min()!)))
        let last = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(times.max()!)))
        return first == last ? first : "\(first) – \(last)"
    }
    nonisolated static func save(_ source: URL, filename: String, directory: URL) throws -> URL {
        let fm = FileManager.default
        let replacementDirectory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: directory.appendingPathComponent(filename), create: true)
        defer { try? fm.removeItem(at: replacementDirectory) }
        let staging = replacementDirectory.appendingPathComponent(UUID().uuidString)
        try Task.checkCancellation()
        try fm.copyItem(at: source, to: staging)
        try Task.checkCancellation()
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        for number in 0..<10000 {
            let suffix = number == 0 ? "" : " \(number)"
            let final = directory.appendingPathComponent(name + suffix + (ext.isEmpty ? "" : "." + ext))
            try Task.checkCancellation()
            if renamex_np(staging.path, final.path, UInt32(RENAME_EXCL)) == 0 { return final }
            if errno == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        throw DownloadFailure.message("Could not find an available filename.")
    }
}

private enum DownloadFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct DownloadsToolbarControl: View {
    @ObservedObject private var downloads = PhotoDownloadManager.shared
    var body: some View {
        Button { downloads.isPresented.toggle() } label: {
            Label("Downloads", systemImage: downloads.hasActiveJobs ? "arrow.down.circle.fill" : "arrow.down.circle")
                .labelStyle(.iconOnly)
        }
            .help("Downloads")
            .accessibilityLabel("Downloads")
            .popover(isPresented: $downloads.isPresented) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Downloads").font(.headline); Spacer(); Button("Clear Finished") { downloads.clearFinished() }.disabled(!downloads.jobs.contains { !$0.active }) }
                    if downloads.jobs.isEmpty { Text("No downloads").foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(downloads.jobs) { job in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(job.name).lineLimit(1); Spacer(); if job.active { Button("Cancel") { downloads.cancel(job.id) }.controlSize(.small) } }
                                    if job.active { ProgressView(value: job.progress) }
                                    Text(job.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }.frame(maxHeight: 300)
                }.padding(16).frame(width: 340)
            }
    }
}

final class PhotoDownloadMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { handler() }
}

let photoDownloadActions: [(String, PhotoDownloadKind, Bool)] = [
    ("Download", .original, false), ("Download to…", .original, true),
    ("Download Compressed JPEG", .compressedJPEG, false), ("Download Compressed JPEG to…", .compressedJPEG, true)
]

func photoDownloadMenu(_ action: @escaping (PhotoDownloadKind, Bool) -> Void) -> NSMenu {
    let menu = NSMenu()
    for (title, kind, choose) in photoDownloadActions {
        menu.addItem(PhotoDownloadMenuItem(title: title) { action(kind, choose) })
    }
    return menu
}

@MainActor
func makeEditorMenu(applications: [URL], onChoose: @escaping (URL) -> Void,
                    onOther: @escaping () -> Void) -> NSMenu {
    let submenu = NSMenu(title: "Edit With")
    for application in applications {
        let name = FileManager.default.displayName(atPath: application.path)
        let title = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let item = PhotoDownloadMenuItem(title: title) { onChoose(application) }
        let icon = (NSWorkspace.shared.icon(forFile: application.path).copy() as? NSImage)
        icon?.size = NSSize(width: 16, height: 16)
        icon?.isTemplate = false
        item.image = icon
        item.preferredImageVisibility = .visible
        submenu.addItem(item)
    }
    if !applications.isEmpty { submenu.addItem(.separator()) }
    submenu.addItem(PhotoDownloadMenuItem(title: "Other…", handler: onOther))
    return submenu
}

@MainActor
func addEditMenu(to menu: NSMenu, filename: String?, onChoose: @escaping (URL) -> Void) {
    let fileExtension = filename.map { URL(fileURLWithPath: $0).pathExtension } ?? ""
    let applications = UTType(filenameExtension: fileExtension).map {
        NSWorkspace.shared.urlsForApplications(toOpen: $0)
    } ?? []
    let submenu = makeEditorMenu(applications: applications, onChoose: onChoose) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let application = panel.url { onChoose(application) }
    }
    menu.addItem(.separator())
    let parent = NSMenuItem(title: "Edit With", action: nil, keyEquivalent: "")
    parent.submenu = submenu
    menu.addItem(parent)
}

@MainActor
func confirmStoppingDownloads() -> Bool {
    guard PhotoDownloadManager.shared.hasActiveJobs || PhotoUploadManager.shared.active else { return true }
    let alert = NSAlert()
    alert.messageText = "Transfers Are Running"
    alert.informativeText = "Closing the app will cancel active uploads and downloads. Check upload destinations before retrying."
    alert.addButton(withTitle: "Close and Cancel Transfers")
    alert.addButton(withTitle: "Keep Open")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    PhotoDownloadManager.shared.cancelAll()
    PhotoUploadManager.shared.cancel()
    return true
}

struct DownloadCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> DownloadCloseGuardView { DownloadCloseGuardView() }
    func updateNSView(_ view: DownloadCloseGuardView, context: Context) {}
}

final class DownloadCloseGuardView: NSView {
    private var proxy: DownloadWindowDelegate?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, proxy == nil else { return }
        let delegate = DownloadWindowDelegate(original: window.delegate)
        proxy = delegate
        window.delegate = delegate
    }
}

final class DownloadWindowDelegate: NSObject, NSWindowDelegate {
    weak var original: (any NSWindowDelegate)?
    init(original: (any NSWindowDelegate)?) { self.original = original }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        return confirmStoppingDownloads()
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
