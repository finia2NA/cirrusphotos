import AppKit
import Darwin
import Foundation
import PhotoCache
import SynologyAPI

/// One promised file of a drag: an item and the name it is promised under.
struct PromisedFile: Sendable, Hashable {
    let itemID: Int64
    let filename: String
}

/// The promises of one drag share a batch. The first request downloads every promised item once
/// (one ZIP for several photos) and extracts it into a staging folder; each request then takes
/// its own file from there. The staging folder lives as long as the batch, which the drag
/// pasteboard keeps through the providers' delegates.
@MainActor
final class PhotoPromiseBatch {
    enum State {
        case idle
        case running
        case ready(PromiseStaging, folder: URL, files: [Int64: URL])
        case failed(any Error)
    }

    struct Request {
        let file: PromisedFile?
        let placeholder: PromisePlaceholder
        let completion: (Error?) -> Void
    }

    let payload: PhotoDragPayload
    var state: State = .idle
    var requests: [Request] = []
    var jobID: UUID?
    private(set) var fraction: Double = 0

    init(payload: PhotoDragPayload) { self.payload = payload }

    /// Progress of the shared download, shown on every placeholder Finder is waiting on.
    func report(_ fraction: Double) {
        self.fraction = fraction
        for request in requests { request.placeholder.update(fraction: fraction) }
    }
}

/// A staging folder removed when the last owner releases it.
final class PromiseStaging: @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    deinit { try? FileManager.default.removeItem(at: root) }
}

/// An empty file or folder created where the receiver asked for the promised item, with a
/// published file progress, so Finder shows the item with a progress pie and a cancel button
/// while it downloads. The finished item replaces it only while it is still this placeholder.
/// When the destination already exists, nothing is created and the item is placed exclusively.
final class PromisePlaceholder: @unchecked Sendable {
    let url: URL
    let isDirectory: Bool
    private let identity: (dev: dev_t, ino: ino_t)?
    private let progress: Progress
    private let lock = NSLock()
    private var published = false

    init(destination: URL, isDirectory: Bool, onCancel: (@Sendable () -> Void)? = nil) {
        url = destination
        self.isDirectory = isDirectory
        let created: Bool
        if isDirectory {
            created = mkdir(destination.path, 0o755) == 0
        } else {
            let descriptor = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            created = descriptor >= 0
            if descriptor >= 0 { close(descriptor) }
        }
        var info = stat()
        identity = created && lstat(destination.path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
        progress = Progress(totalUnitCount: 1000)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = destination
        progress.isCancellable = onCancel != nil
        progress.cancellationHandler = onCancel
        progress.isPausable = false
        if identity != nil {
            progress.publish()
            published = true
        }
    }

    var hasPlaceholder: Bool { identity != nil }

    func update(fraction: Double) {
        progress.completedUnitCount = Int64(min(max(fraction, 0), 1) * 1000)
    }

    /// Copies `source` beside the destination and moves it into place over the placeholder.
    /// The copy is a clone when the staging folder is on the destination's volume.
    func install(copyOf source: URL) throws {
        let fm = FileManager.default
        let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("payload", isDirectory: isDirectory)
        try Task.checkCancellation()
        try fm.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        if let identity {
            guard isUnchanged(identity) else { throw POSIXError(.EEXIST) }
            // A file or an empty folder is replaced in one rename.
            if rename(staged.path, url.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else if renamex_np(staged.path, url.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        unpublish()
    }

    /// Removes the placeholder if it is still the empty item created here.
    func discard() {
        if let identity, isUnchanged(identity) {
            if isDirectory { rmdir(url.path) } else { unlink(url.path) }
        }
        unpublish()
    }

    private func isUnchanged(_ identity: (dev: dev_t, ino: ino_t)) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_dev == identity.dev, info.st_ino == identity.ino else { return false }
        if isDirectory {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) == true
        }
        return info.st_size == 0
    }

    private func unpublish() {
        lock.lock()
        defer { lock.unlock() }
        guard published else { return }
        published = false
        progress.unpublish()
    }
}

extension PhotoDownloadManager {
    /// Finds each promised file in an extracted download. A single promised file takes the only
    /// file of a single-file download; otherwise files are matched by name, case-insensitively,
    /// anywhere in the folder. A Live Photo that arrived as its own nested archive is unzipped
    /// next to it and searched again. Names that are missing or ambiguous are left out.
    nonisolated static func locate(_ promised: [PromisedFile], in folder: URL) throws -> [Int64: URL] {
        var files = try regularFiles(in: folder)
        if promised.count == 1, files.count == 1 { return [promised[0].itemID: files[0]] }
        var located: [Int64: URL] = [:]
        func match(_ file: PromisedFile) -> URL? {
            let matches = files.filter { $0.lastPathComponent.caseInsensitiveCompare(file.filename) == .orderedSame }
            return matches.count == 1 ? matches[0] : nil
        }
        for file in promised {
            if let url = match(file) { located[file.itemID] = url; continue }
            let base = URL(fileURLWithPath: file.filename).deletingPathExtension().lastPathComponent
            let archives = files.filter {
                $0.pathExtension.lowercased() == "zip"
                    && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(base) == .orderedSame
            }
            guard archives.count == 1, try isZIPArchive(archives[0]) else { continue }
            let nested = archives[0].deletingPathExtension().appendingPathExtension("contents")
            try populateFolder(nested, from: archives[0], filename: archives[0].lastPathComponent)
            files = try regularFiles(in: folder)
            if let url = match(file) { located[file.itemID] = url }
        }
        return located
    }

    nonisolated static func regularFiles(in folder: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
