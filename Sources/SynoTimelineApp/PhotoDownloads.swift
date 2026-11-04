import AppKit
import Darwin
import PhotoCache
import SwiftUI
import SynologyAPI
import UniformTypeIdentifiers

enum PhotoDownloadSource: Sendable {
    case item(PhotoItem, collection: PhotoCollectionDescriptor)
    /// Already verified items, used to retry a resolved download.
    case items([PhotoItem], collection: PhotoCollectionDescriptor)
    case selection(PhotoSelectionSnapshot)
    case album(Int64)
    case incomingAlbum(PhotoCollectionDescriptor)

    func resolve(repository: CachedPhotosRepository) async throws -> [PhotoItem] {
        let items: [PhotoItem]?
        switch self {
        case .item(let item, _): items = [item]
        case .items(let resolved, _): items = resolved
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
        case .item(_, let collection), .items(_, let collection): return collection
        case .selection(let selection): return selection.collection
        case .album(let id): return .album(id)
        case .incomingAlbum(let collection): return collection
        }
    }

    var initialName: String {
        switch self {
        case .item(let item, _): return item.filename ?? "Photo"
        case .items(let items, _) where !items.isEmpty: return PhotoDownloadManager.jobName(items)
        default: return "Preparing download…"
        }
    }

    /// A selection snapshot can be resolved only once, so it is retried with its resolved items.
    var isRepeatable: Bool {
        if case .selection = self { return false }
        return true
    }
}

/// Runs downloads, editor handoffs and file promises. Their progress and results are
/// reported to the Activity panel.
@MainActor
final class PhotoDownloadManager {
    static let shared = PhotoDownloadManager()
    var hasActiveJobs: Bool { !tasks.isEmpty }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let activity: ActivityCenter
    private let editDirectoryProvider: @Sendable () throws -> URL
    private let editorOpener: @MainActor (URL, URL) async throws -> Void

    init(activity: ActivityCenter = .shared,
         editDirectoryProvider: @escaping @Sendable () throws -> URL = { try PhotoDownloadManager.editDirectory() },
         editorOpener: @escaping @MainActor (URL, URL) async throws -> Void = { file, application in
             _ = try await NSWorkspace.shared.open([file], withApplicationAt: application,
                                                   configuration: NSWorkspace.OpenConfiguration())
         }) {
        self.activity = activity
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
        start(repository: repository, source: source, kind: kind, directory: directory)
    }

    func start(repository: CachedPhotosRepository, source: PhotoDownloadSource,
               kind: PhotoDownloadKind, directory: URL) {
        let id = UUID()
        let handle = activity.begin(.download(name: source.initialName), id: id, cancel: { [weak self] in self?.cancel(id) })
        handle.status("Preparing…")
        func retry(_ source: PhotoDownloadSource) -> ActivityRetry {
            { [weak self] _ in
                guard let self else { return false }
                start(repository: repository, source: source, kind: kind, directory: directory)
                return true
            }
        }
        if source.isRepeatable { handle.setRetry(retry(source)) }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let mediaCollection = await repository.mediaCollection(for: source.collection)
                let items = try await source.resolve(repository: repository)
                handle.rename(.download(name: Self.jobName(items)))
                handle.setRetry(retry(.items(items, collection: source.collection)))
                handle.status("Downloading…")
                let reusable = mediaCollection.incomingAlbumIdentity == nil && !mediaCollection.isLibraryFilter
                let cached = try await (reusable && items.count == 1 && kind == .original
                    ? repository.cachedOriginalForDownload(items[0], collection: mediaCollection) : nil)
                let result: PhotoDownloadResponse
                if let cached { result = cached }
                else {
                    result = try await repository.downloadPhotos(itemIDs: items.map(\.id), kind: kind, collection: mediaCollection) { progress in
                        Task { @MainActor in handle.progress(fraction: progress.fractionCompleted) }
                    }
                }
                defer { try? FileManager.default.removeItem(at: result.temporaryURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                handle.status("Saving…")
                let saveTask = Task.detached(priority: .utility) {
                    try Self.save(result.temporaryURL, filename: result.filename, directory: directory)
                }
                let final = try await withTaskCancellationHandler {
                    try await saveTask.value
                } onCancel: { saveTask.cancel() }
                handle.status("Saved to \(final.path)")
                handle.succeed(savedURL: final)
            } catch {
                handle.fail(error, operation: "Download")
            }
            tasks[id] = nil
        }
    }

    func edit(repository: CachedPhotosRepository, snapshot: TimelineSnapshot?, selection: BrowserCommandSnapshot?,
              item: PhotoItem?, collection: PhotoCollectionDescriptor, applicationURL: URL) {
        let capturedSelection = selection?.captureSelection(timeline: snapshot)
        let id = UUID()
        let application = Self.applicationName(applicationURL)
        let handle = activity.begin(.editHandoff(name: item?.filename ?? "Preparing photo…", application: application),
                                    id: id, cancel: { [weak self] in self?.cancel(id) })
        handle.status("Preparing…")
        func retry(_ photo: PhotoItem) -> ActivityRetry {
            { [weak self] _ in
                guard let self else { return false }
                edit(repository: repository, snapshot: nil, selection: nil, item: photo,
                     collection: capturedSelection?.collection ?? collection, applicationURL: applicationURL)
                return true
            }
        }
        if let item { handle.setRetry(retry(item)) }
        activity.present()
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
                handle.rename(.editHandoff(name: photo.filename ?? "Photo", application: application))
                handle.setRetry(retry(photo))
                let mediaCollection = try await repository.collectionForPhotoEditing(
                    itemID: photo.id, collection: capturedSelection?.collection ?? collection)
                handle.status("Downloading…")
                let progress: @Sendable (TransferProgress) -> Void = { value in
                    Task { @MainActor in handle.progress(fraction: value.fractionCompleted) }
                }
                let cached = try await repository.cachedOriginalForDownload(photo, includeLivePhoto: true, collection: mediaCollection)
                let response: PhotoDownloadResponse
                if let cached { response = cached }
                else if photo.mediaKind == .livePhoto {
                    guard let still = try await repository.livePhotoStillForEditing(photo, collection: mediaCollection, progress: progress) else {
                        throw DownloadFailure.message("The Live Photo still is unavailable.")
                    }
                    response = still
                }
                else {
                    response = try await repository.downloadPhotos(itemIDs: [photo.id], kind: .original, collection: mediaCollection,
                                                                   progress: progress)
                }
                defer { try? FileManager.default.removeItem(at: response.temporaryURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                handle.status("Saving…")
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
                handle.status("Opening…")
                try await editorOpener(file, applicationURL)
                handle.status("Saved to \(file.path)")
                handle.succeed(savedURL: file)
            } catch {
                handle.fail(error, operation: "Edit With", note: saved.map { "File saved to \($0.path)" })
            }
            tasks[id] = nil
        }
    }

    nonisolated static func applicationName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    nonisolated static func editDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DownloadFailure.message("The Documents folder is unavailable.")
        }
        return documents.appendingPathComponent("SynoTimeline Edits", isDirectory: true)
    }

    func fulfillPromise(_ payload: PhotoDragPayload, destination: URL, completion: @escaping (Error?) -> Void) {
        let id = UUID()
        let handle = activity.begin(.filePromise(name: payload.source.initialName), id: id,
                                    cancel: { [weak self] in self?.cancel(id) })
        handle.status("Preparing…")
        tasks[id] = Task { [weak self] in
            guard let self else { completion(CancellationError()); return }
            do {
                let mediaCollection = await payload.repository.mediaCollection(for: payload.source.collection)
                let items = try await payload.source.resolve(repository: payload.repository)
                handle.rename(.filePromise(name: Self.jobName(items)))
                handle.status("Downloading…")
                let progress: @Sendable (TransferProgress) -> Void = { value in
                    Task { @MainActor in handle.progress(fraction: value.fractionCompleted) }
                }
                let response: PhotoDownloadResponse
                if payload.delivery == .file, items.count == 1,
                   let cached = try await payload.repository.cachedOriginalForDownload(items[0], includeLivePhoto: true, collection: mediaCollection) {
                    response = cached
                } else if payload.delivery == .file, items.count == 1, items[0].mediaKind == .livePhoto {
                    guard let still = try await payload.repository.livePhotoStillForEditing(items[0], collection: mediaCollection, progress: progress) else {
                        throw DownloadFailure.message("The Live Photo still is unavailable.")
                    }
                    response = still
                } else {
                    response = try await payload.repository.downloadPhotos(itemIDs: items.map(\.id), kind: .original, collection: mediaCollection, progress: progress)
                }
                defer { try? FileManager.default.removeItem(at: response.temporaryURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                handle.status(payload.delivery == .folder ? "Unzipping…" : "Saving…")
                let delivery = payload.delivery
                let writeTask = Task.detached(priority: .utility) {
                    switch delivery {
                    case .file: try Self.writePromise(response.temporaryURL, destination: destination)
                    case .folder: try Self.writeFolderPromise(response.temporaryURL, filename: response.filename, destination: destination)
                    }
                }
                try await withTaskCancellationHandler {
                    try await writeTask.value
                } onCancel: { writeTask.cancel() }
                handle.status("Saved to \(destination.path)")
                handle.succeed(savedURL: destination)
                completion(nil)
            } catch {
                handle.fail(error, operation: "File promise")
                completion(error)
            }
            tasks[id] = nil
        }
    }

    nonisolated static func writePromise(_ source: URL, destination: URL) throws {
        let fm = FileManager.default
        let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("payload")
        try Task.checkCancellation()
        try fm.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        try publish(staged, at: destination)
    }

    /// Delivers a download as a folder of files. A ZIP response is unzipped and a single-file
    /// response is copied in. The finished folder appears at `destination` in one rename, so the
    /// receiver never sees it half-populated.
    nonisolated static func writeFolderPromise(_ source: URL, filename: String, destination: URL) throws {
        let fm = FileManager.default
        let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("payload", isDirectory: true)
        try populateFolder(folder, from: source, filename: filename)
        try publish(folder, at: destination)
    }

    /// Fills a new folder with the contents of a ZIP download, or with a single-file response.
    nonisolated static func populateFolder(_ folder: URL, from source: URL, filename: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Task.checkCancellation()
        if try isZIPArchive(source) {
            try unzip(source, into: folder)
            try tidyExtractedFolder(folder)
        } else {
            let name = URL(fileURLWithPath: filename).lastPathComponent
            try fm.copyItem(at: source, to: folder.appendingPathComponent(name.isEmpty ? "Photo" : name))
        }
        try Task.checkCancellation()
        guard !(try fm.contentsOfDirectory(atPath: folder.path)).isEmpty else {
            throw DownloadFailure.message("The download contained no files.")
        }
    }

    /// The file-promise receiver coordinates this write while waiting for our completion.
    /// Coordinating again here would wait on the receiver itself.
    private nonisolated static func publish(_ staged: URL, at destination: URL) throws {
        if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated static func isZIPArchive(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Local file header, or the end record of an empty archive.
        let signature = [UInt8](try handle.read(upToCount: 4) ?? Data())
        return signature == [0x50, 0x4b, 0x03, 0x04] || signature == [0x50, 0x4b, 0x05, 0x06]
    }

    private nonisolated static func unzip(_ archive: URL, into folder: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, folder.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        while task.isRunning {
            if Task.isCancelled { task.terminate(); task.waitUntilExit(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard task.terminationStatus == 0 else { throw DownloadFailure.message("Could not unzip the download.") }
    }

    /// Drops archive metadata, rejects links that could point outside the folder, and lifts the
    /// contents out of a lone wrapper directory so the promised folder is the container.
    private nonisolated static func tidyExtractedFolder(_ folder: URL) throws {
        let fm = FileManager.default
        for entry in ["__MACOSX", ".DS_Store"] { try? fm.removeItem(at: folder.appendingPathComponent(entry)) }
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in walker {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw DownloadFailure.message("The download contained an unsafe link.")
                }
            }
        }
        let entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        guard entries.count == 1, let wrapper = entries.first,
              try wrapper.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return }
        for child in try fm.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil) {
            try fm.moveItem(at: child, to: folder.appendingPathComponent(child.lastPathComponent))
        }
        try fm.removeItem(at: wrapper)
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    /// Cancels every transfer; each settles as cancelled in the Activity panel.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
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
        // A ZIP response is a multi-item download; save its files as a folder rather than the archive.
        var unzips = URL(fileURLWithPath: filename).pathExtension.lowercased() == "zip"
        if unzips { unzips = try isZIPArchive(source) }
        if unzips { try populateFolder(staging, from: source, filename: filename) }
        else { try fm.copyItem(at: source, to: staging) }
        try Task.checkCancellation()
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = unzips ? "" : URL(fileURLWithPath: filename).pathExtension
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
        let item = PhotoDownloadMenuItem(title: PhotoDownloadManager.applicationName(application)) { onChoose(application) }
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
