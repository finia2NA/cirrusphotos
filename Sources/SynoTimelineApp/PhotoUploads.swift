import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// Uploads one session's Finder drops, one batch at a time. Progress and per-file failures
/// are reported to the session's Activity panel. Once ended it refuses new work.
@MainActor
final class PhotoUploadManager {
    private(set) var active = false
    private(set) var isEnded = false
    private let activity: ActivityCenter
    private var task: Task<Void, Never>?
    /// Thumbnail polls with the browser that started them, if any.
    private var thumbnailPolls: [UUID: (owner: UUID?, task: Task<Void, Never>)] = [:]
    var thumbnailPollCount: Int { thumbnailPolls.count }

    init(activity: ActivityCenter) {
        self.activity = activity
    }

    static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        guard sender.draggingPasteboard.availableType(from: [SelectionDragRegistry.type, AlbumDragRegistry.type]) == nil else { return [] }
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// `owner` identifies the browser that accepted the drop; its thumbnail poll stops when
    /// that browser goes away.
    func start(_ urls: [URL], repository: CachedPhotosRepository, destination: PhotoUploadDestination,
               destinationName: String? = nil, owner: UUID? = nil,
               finished: @escaping @MainActor () async -> Void) -> Bool {
        guard !isEnded, !active, !urls.isEmpty else { return false }
        let access = urls.map { $0.startAccessingSecurityScopedResource() }
        active = true
        let items = urls.map { ActivityItem(file: $0) }
        let handle = activity.begin(.upload(destination: destinationName), items: items,
                                    cancel: { [weak self] in self?.cancel() },
                                    retry: { [weak self] retried in
            self?.start(retried.compactMap(\.fileURL), repository: repository, destination: destination,
                        destinationName: destinationName, owner: owner, finished: finished) ?? false
        })
        task = Task { [self] in
            defer {
                for (url, started) in zip(urls, access) where started { url.stopAccessingSecurityScopedResource() }
                active = false
                task = nil
            }
            var failed: [ActivityItem] = []
            var firstError: (any Error)?
            var uploadedIDs: [Int64] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                handle.status("\(index + 1) of \(urls.count): \(url.lastPathComponent)")
                handle.progress(fraction: nil)
                do {
                    let uploaded = try await repository.uploadPhoto(at: url, destination: destination) { transfer in
                        guard let total = transfer.totalBytes, total > 0 else { return }
                        let fraction = Double(transfer.completedBytes) / Double(total)
                        Task { @MainActor in handle.progress(fraction: fraction) }
                    }
                    uploadedIDs.append(uploaded.id)
                } catch is CancellationError { break }
                catch {
                    var item = items[index]
                    item.message = reportedFailure(error, operation: "Upload")
                    failed.append(item)
                    if firstError == nil { firstError = error }
                }
                handle.progress(completed: index + 1)
            }
            if Task.isCancelled {
                handle.status("Upload cancelled. Check the destination before retrying.")
                handle.cancelled()
            } else if let firstError {
                handle.status(nil)
                handle.fail(firstError, operation: "Upload", failedItems: failed, logs: false)
            } else {
                handle.status(nil)
                handle.succeed()
            }
            await finished()
            if !Task.isCancelled, !isEnded {
                pollThumbnails(of: uploadedIDs, repository: repository, destination: destination, owner: owner, finished: finished)
            }
        }
        return true
    }

    /// The NAS generates thumbnails after the transfer. The bounded poll ends on completion, on
    /// its own schedule, when the browser that started it goes away, or when the session ends.
    func pollThumbnails(of ids: [Int64], repository: CachedPhotosRepository, destination: PhotoUploadDestination,
                        owner: UUID?, finished: @escaping @MainActor () async -> Void) {
        guard !isEnded, !ids.isEmpty else { return }
        let key = UUID()
        let task = Task { [weak self] in
            defer { self?.thumbnailPolls[key] = nil }
            let ready = (try? await repository.refreshWhenUploadedThumbnailsAreReady(itemIDs: ids, destination: destination)) ?? false
            if ready, !Task.isCancelled { await finished() }
        }
        thumbnailPolls[key] = (owner, task)
    }

    /// Stops the thumbnail polls started from one browser.
    func cancelThumbnailPolling(owner: UUID) {
        for (key, poll) in thumbnailPolls where poll.owner == owner {
            poll.task.cancel()
            thumbnailPolls[key] = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Cancels the running batch and every thumbnail poll, and refuses new uploads.
    func end() {
        isEnded = true
        cancel()
        thumbnailPolls.values.forEach { $0.task.cancel() }
        thumbnailPolls.removeAll()
    }
}

/// A Finder upload destination. Accepts concrete file URLs, never in-process
/// selection or album drags, and refreshes the library when the upload finishes.
@MainActor
struct PhotoUploadDrop {
    let destination: PhotoUploadDestination
    var destinationName: String?
    let repository: CachedPhotosRepository
    let uploads: PhotoUploadManager
    /// The browser that accepts the drop.
    var owner: UUID?
    let finished: @MainActor () async -> Void

    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        !uploads.isEnded && !uploads.active && !PhotoUploadManager.fileURLs(sender).isEmpty ? .copy : []
    }

    func perform(_ sender: NSDraggingInfo) -> Bool {
        uploads.start(PhotoUploadManager.fileURLs(sender), repository: repository, destination: destination,
                      destinationName: destinationName, owner: owner, finished: finished)
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
