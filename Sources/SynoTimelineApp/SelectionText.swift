import Foundation
import PhotoCache
import SynologyAPI

/// The text form of a selection: one `filename,id` line per item, with no header row. Copy and
/// drag both put it on the pasteboard beside any file representation, and the receiver picks.
enum SelectionText {
    static func csv(for items: [PhotoItem]) -> String {
        items.map { "\(field($0.filename ?? "")),\($0.id)" }.joined(separator: "\n")
    }

    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Resolves the captured selection, including unloaded items. A snapshot's session
    /// registrations are released by resolving, so each use needs its own capture.
    static func resolve(_ selection: PhotoSelectionSnapshot, repository: CachedPhotosRepository) async -> String? {
        guard let items = await SelectionItemResolver(repository: repository).resolve(selection), !items.isEmpty else { return nil }
        return csv(for: items)
    }
}
