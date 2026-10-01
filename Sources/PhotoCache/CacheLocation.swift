import Foundation

/// Resolves the prototype's persistent cache beside the project checkout.
/// LaunchServices does not guarantee an app's process working directory, so the
/// generated `.app` walks upward to the repository containing `Package.swift`.
public enum CacheLocation {
    public static func defaultRoot(
        fileManager: FileManager = .default,
        currentDirectory: URL? = nil,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> URL {
        projectRoot(
            fileManager: fileManager,
            currentDirectory: currentDirectory,
            bundleURL: bundleURL
        ).appendingPathComponent(".cache", isDirectory: true)
    }

    static func projectRoot(
        fileManager: FileManager,
        currentDirectory: URL?,
        bundleURL: URL
    ) -> URL {
        let workingDirectory = (currentDirectory
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        var candidates = [workingDirectory]
        var candidate = bundleURL.standardizedFileURL
        for _ in 0..<8 {
            candidates.append(candidate)
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            let manifest = candidate.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: manifest.path) { return candidate }
        }
        return workingDirectory
    }

    /// Best-effort one-time migration from the earlier macOS Caches location.
    /// Failure deliberately leaves the old cache untouched and starts a new one.
    static func migrateDirectory(
        from legacyRoot: URL,
        to destinationRoot: URL,
        fileManager: FileManager = .default
    ) {
        guard fileManager.fileExists(atPath: legacyRoot.path),
              !fileManager.fileExists(atPath: destinationRoot.path) else { return }
        do {
            try fileManager.createDirectory(
                at: destinationRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyRoot, to: destinationRoot)
        } catch {
            // A cache migration must never prevent the app from starting.
        }
    }
}
