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
}
