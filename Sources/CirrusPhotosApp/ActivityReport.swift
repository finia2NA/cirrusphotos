import AppKit
import Foundation
import PhotoCache
import SynologyAPI

/// Plain-text failure details for the clipboard, for the user or for debugging. Never includes
/// the NAS address, session or credentials.
enum ActivityReport {
    static let itemLimit = 50

    static func text(title: String, failure: ActivityFailure, items: [ActivityItem], connection: String?,
                     bundle: Bundle = .main, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var lines = [
            "Cirrus Photos \(version)\(build.map { " (\($0))" } ?? ""), macOS \(osVersion)",
            "\(failure.date.ISO8601Format()) · \(failure.operation) · \(failure.errorKind)\(failure.unconfirmed ? " · unconfirmed" : "")",
            "Action: \(title)",
            "Message: \(failure.message)",
        ]
        lines += failure.underlying.map { "Underlying: \($0)" }
        if let connection { lines.append("Connection: \(connection)") }
        let collections = Set(items.compactMap { item -> String? in
            if case .photo(_, let collection) = item.reference { return collection.rawValue }
            return nil
        })
        if !collections.isEmpty { lines.append("Collection: \(collections.sorted().joined(separator: ", "))") }
        if !items.isEmpty {
            let listed = items.prefix(itemLimit).map { item in
                item.photoID.map { "\($0) \(item.name)" } ?? item.name
            }
            let more = items.count > itemLimit ? ", and \(items.count - itemLimit) more" : ""
            lines.append("Items (\(items.count)): \(listed.joined(separator: ", "))\(more)")
            lines += items.compactMap { item in item.message.map { "Item \(item.name): \($0)" } }
        }
        return lines.map(LogRedaction.scrub).joined(separator: "\n")
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
