import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

@MainActor
final class PhotoUploadManager: ObservableObject {
    static let shared = PhotoUploadManager()
    @Published var presented = false
    @Published private(set) var status = ""
    @Published private(set) var active = false
    @Published private(set) var progress: Double?
    private var task: Task<Void, Never>?

    static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        guard sender.draggingPasteboard.availableType(from: [SelectionDragRegistry.type, AlbumDragRegistry.type]) == nil else { return [] }
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func start(_ urls: [URL], repository: CachedPhotosRepository, destination: PhotoUploadDestination,
               finished: @escaping @MainActor () async -> Void) -> Bool {
        guard !active, !urls.isEmpty else { return false }
        let access = urls.map { $0.startAccessingSecurityScopedResource() }
        active = true
        presented = true
        status = "Preparing upload…"
        task = Task { [self] in
            defer {
                for (url, started) in zip(urls, access) where started { url.stopAccessingSecurityScopedResource() }
                active = false
                task = nil
            }
            var errors: [String] = []
            var completed = 0
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                status = "Uploading \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                progress = nil
                do {
                    _ = try await repository.uploadPhoto(at: url, destination: destination) { [weak self] transfer in
                        Task { @MainActor in
                            guard let total = transfer.totalBytes, total > 0 else { return }
                            self?.progress = Double(transfer.completedBytes) / Double(total)
                        }
                    }
                    completed += 1
                } catch is CancellationError { break }
                catch { errors.append("\(url.lastPathComponent): \(reportedFailure(error, operation: "Upload"))") }
            }
            progress = nil
            if Task.isCancelled { status = "Upload cancelled. Check the destination before retrying." }
            else if errors.isEmpty { status = "Processed \(completed) \(completed == 1 ? "photo" : "photos")." }
            else { status = "Processed \(completed) of \(urls.count).\n" + errors.joined(separator: "\n") }
            await finished()
        }
        return true
    }

    func cancel() { task?.cancel() }
}

struct UploadsToolbarControl: View {
    @ObservedObject private var uploads = PhotoUploadManager.shared
    var body: some View {
        Button { uploads.presented.toggle() } label: { Image(systemName: uploads.active ? "arrow.up.circle.fill" : "arrow.up.circle") }
            .help("Uploads")
            .accessibilityLabel("Uploads")
            .popover(isPresented: $uploads.presented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Uploads").font(.headline)
                    Text(uploads.status.isEmpty ? "No uploads" : uploads.status).textSelection(.enabled)
                    if uploads.active {
                        if let progress = uploads.progress { ProgressView(value: progress) } else { ProgressView() }
                        Button("Cancel") { uploads.cancel() }
                    }
                }.padding().frame(width: 300, alignment: .leading)
            }
    }
}

/// A Finder upload destination. Accepts concrete file URLs, never in-process
/// selection or album drags, and refreshes the library when the upload finishes.
@MainActor
struct PhotoUploadDrop {
    let destination: PhotoUploadDestination
    let repository: CachedPhotosRepository
    let finished: @MainActor () async -> Void

    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        !PhotoUploadManager.shared.active && !PhotoUploadManager.fileURLs(sender).isEmpty ? .copy : []
    }

    func perform(_ sender: NSDraggingInfo) -> Bool {
        PhotoUploadManager.shared.start(PhotoUploadManager.fileURLs(sender), repository: repository,
                                        destination: destination, finished: finished)
    }
}

struct FileUploadTarget: NSViewRepresentable {
    let upload: PhotoUploadDrop?
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) { view.upload = upload }
    @MainActor final class Target: NSView {
        var upload: PhotoUploadDrop?
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
        required init?(coder: NSCoder) { fatalError() }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { upload?.operation(for: sender) ?? [] }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { upload?.perform(sender) ?? false }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    }
}
