import Foundation

/// Which items of an album are already in the download folder, so a new run continues
/// where the previous one stopped. Kept as a hidden JSON file in that folder.
final class DownloadState {
    private struct Contents: Codable {
        var reference: String
        /// Item ID → file name in the folder.
        var completed: [String: String]
    }

    let folder: URL
    let partialFolder: URL
    private let file: URL
    private var contents: Contents

    init(folder: URL, reference: String) throws {
        self.folder = folder
        partialFolder = folder.appendingPathComponent(".partial", isDirectory: true)
        file = folder.appendingPathComponent(".album-downloader.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Contents.self, from: data), saved.reference == reference {
            contents = saved
        } else {
            contents = Contents(reference: reference, completed: [:])
        }
    }

    /// True when the item was downloaded before and its file is still there.
    func isComplete(_ id: Int64) -> Bool {
        guard let name = contents.completed[String(id)] else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func partialFile(for id: Int64) throws -> URL {
        try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
        return partialFolder.appendingPathComponent("\(id).part")
    }

    /// Moves a finished partial file into the folder under a free name and records it.
    func complete(_ id: Int64, partial: URL, filename: String) throws -> String {
        let manager = FileManager.default
        let name = Self.availableName(for: filename, in: folder)
        try manager.moveItem(at: partial, to: folder.appendingPathComponent(name))
        contents.completed[String(id)] = name
        let data = try JSONEncoder().encode(contents)
        try data.write(to: file, options: .atomic)
        return name
    }

    /// Removes the partial folder once nothing is left in it.
    func cleanUp() {
        let manager = FileManager.default
        if (try? manager.contentsOfDirectory(atPath: partialFolder.path))?.isEmpty == true {
            try? manager.removeItem(at: partialFolder)
        }
    }

    /// `name.ext`, or `name (2).ext` and so on when that file exists.
    static func availableName(for filename: String, in folder: URL) -> String {
        let manager = FileManager.default
        var candidate = filename
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 2
        while manager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// A safe single path component; falls back when nothing usable remains.
    static func safeName(_ name: String, fallback: String) -> String {
        var cleaned = (name as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? fallback : cleaned
    }
}
