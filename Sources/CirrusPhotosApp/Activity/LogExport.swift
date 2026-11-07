import AppKit
import Foundation
import OSLog
import SwiftUI
import SynologyAPI
import UniformTypeIdentifiers

/// Writes the app's own unified-log entries to a text file the user attaches to a bug report.
/// Nothing is sent anywhere.
enum LogExport {
    static let subsystem = AppIdentity.bundleIdentifier
    static let logArguments = ["show", "--last", "24h", "--info", "--debug", "--style", "compact",
                               "--predicate", "subsystem == \"\(subsystem)\""]
    static let logTool = URL(fileURLWithPath: "/usr/bin/log")

    static func fileName(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Cirrus Photos Logs \(formatter.string(from: date)).txt"
    }

    static func header(bundle: Bundle = .main,
                       osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                       exported: Date = Date(), sessionOnly: Bool) -> String {
        let range = sessionOnly
            ? "current session only (the system log could not be read)"
            : "last 24 hours"
        return """
        Cirrus Photos \(AppVersion.versionAndBuild(bundle: bundle))
        macOS: \(osVersion)
        Exported: \(exported.ISO8601Format())
        Range: \(range)
        Subsystem: \(subsystem)
        ----

        """
    }

    /// Redaction applied to every exported line, on top of the system's private-value redaction.
    static func scrubbed(_ line: String) -> String { LogRedaction.scrub(line) }

    /// Writes the export to `url` and returns the number of log lines. Runs off the main actor.
    nonisolated static func export(to url: URL) async throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        do {
            return try await viaLogTool(handle: handle)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            return try viaCurrentProcess(handle: handle)
        }
    }

    private struct ToolFailure: Error {}

    private nonisolated static func viaLogTool(handle: FileHandle) async throws -> Int {
        let process = Process()
        process.executableURL = logTool
        process.arguments = logArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return try await withTaskCancellationHandler {
            try handle.write(contentsOf: Data(header(sessionOnly: false).utf8))
            var count = 0
            var pending = Data()
            for try await line in output.fileHandleForReading.bytes.lines {
                pending.append(Data((scrubbed(line) + "\n").utf8))
                count += 1
                if pending.count >= 64 * 1024 {
                    try handle.write(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: pending)
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw ToolFailure() }
            return count
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private nonisolated static func viaCurrentProcess(handle: FileHandle) throws -> Int {
        try handle.write(contentsOf: Data(header(sessionOnly: true).utf8))
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        var count = 0
        var pending = Data()
        for entry in try store.getEntries(matching: predicate) {
            guard let entry = entry as? OSLogEntryLog else { continue }
            let line = "\(entry.date.ISO8601Format()) \(label(entry.level)) [\(entry.category)] \(entry.composedMessage)"
            pending.append(Data((scrubbed(line) + "\n").utf8))
            count += 1
        }
        try handle.write(contentsOf: pending)
        return count
    }

    private nonisolated static func label(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Default"
        case .error: "Error"
        case .fault: "Fault"
        default: "Default"
        }
    }
}

/// Runs Help ▸ Export Logs…: save panel, export, then an alert with the result.
@MainActor
final class LogExporter: ObservableObject {
    @Published private(set) var isExporting = false

    func run() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogExport.fileName()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Export Logs"
        panel.message = "Saves this app's log entries from the last 24 hours. Nothing is sent."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let count = try await Task.detached { try await LogExport.export(to: url) }.value
                present(success: url, lines: count)
            } catch {
                present(failure: error)
            }
        }
    }

    private func present(success url: URL, lines: Int) {
        let alert = NSAlert()
        alert.messageText = "Logs exported"
        alert.informativeText = "\(lines) log lines were saved to \(url.lastPathComponent)."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func present(failure error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Logs could not be exported"
        alert.informativeText = error.logSummary
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Help menu: Report an Issue… and Export Logs….
struct HelpCommands: Commands {
    @ObservedObject var exporter: LogExporter

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Report an Issue…") { NSWorkspace.shared.open(IssueReport.url()) }
            Button("Export Logs…") { exporter.run() }
                .disabled(exporter.isExporting)
        }
    }
}
