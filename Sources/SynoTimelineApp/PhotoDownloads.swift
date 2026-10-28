import AppKit
import Darwin
import PhotoCache
import SwiftUI
import SynologyAPI

struct PhotoDownloadJob: Identifiable {
    let id: UUID
    var name: String
    var progress: Double?
    var status: String
    var active: Bool
}

@MainActor
final class PhotoDownloadManager: ObservableObject {
    static let shared = PhotoDownloadManager()
    @Published private(set) var jobs: [PhotoDownloadJob] = []
    @Published var isPresented = false
    var hasActiveJobs: Bool { jobs.contains { $0.active } }
    private var tasks: [UUID: Task<Void, Never>] = [:]

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: "photoDownloadDirectory"), !path.isEmpty {
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

    func start(repository: CachedPhotosRepository, snapshot: TimelineSnapshot?, selection: BrowserCommandSnapshot?,
               item: PhotoItem?, kind: PhotoDownloadKind, choose: Bool) {
        guard let directory = choose ? chooseDirectory() : Self.directory else { return }
        let id = UUID()
        jobs.insert(PhotoDownloadJob(id: id, name: item?.filename ?? "Preparing download…", progress: nil,
                                     status: "Preparing…", active: true), at: 0)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let items: [PhotoItem]
                if let item { items = [item] }
                else if let selection, let snapshot {
                    guard let resolved = await SelectionDownloadResolver(repository: repository).resolve(
                        collection: selection.collection, snapshot: snapshot,
                        selectedOrdinals: selection.selectedOrdinals,
                        knownItemIDsByOrdinal: selection.knownItemIDsByOrdinal,
                        expectedTimelineFingerprint: selection.indexFingerprint), !resolved.isEmpty else {
                        throw DownloadFailure.message("The selected photos could not be verified.")
                    }
                    items = resolved
                } else { throw DownloadFailure.message("No photo is selected.") }
                try Task.checkCancellation()
                guard !items.isEmpty else { throw DownloadFailure.message("No photos are selected.") }
                update(id) { $0.name = Self.jobName(items); $0.status = "Downloading…" }
                let result = try await repository.downloadPhotos(itemIDs: items.map(\.id), kind: kind) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.update(id) { if $0.active { $0.progress = progress.fractionCompleted } }
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
                update(id) { $0.status = error is CancellationError ? "Cancelled" : error.localizedDescription; $0.active = false }
            }
            tasks[id] = nil
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
        Button { downloads.isPresented.toggle() } label: { Image(systemName: "arrow.down.circle") }
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

func photoDownloadMenu(_ action: @escaping (PhotoDownloadKind, Bool) -> Void) -> NSMenu {
    let menu = NSMenu()
    for (title, kind, choose) in [("Download", PhotoDownloadKind.original, false),
                                   ("Download to…", .original, true),
                                   ("Download Compressed JPEG", .compressedJPEG, false),
                                   ("Download Compressed JPEG to…", .compressedJPEG, true)] {
        menu.addItem(PhotoDownloadMenuItem(title: title) { action(kind, choose) })
    }
    return menu
}

@MainActor
func confirmStoppingDownloads() -> Bool {
    guard PhotoDownloadManager.shared.hasActiveJobs else { return true }
    let alert = NSAlert()
    alert.messageText = "Downloads Are Running"
    alert.informativeText = "Closing the app will cancel the active downloads."
    alert.addButton(withTitle: "Close and Cancel Downloads")
    alert.addButton(withTitle: "Keep Open")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    PhotoDownloadManager.shared.cancelAll()
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
