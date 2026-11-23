import Foundation
import PhotoCache
import SynologyAPI

/// A folder row whose cover or permission could not be read; the fields name what was left out.
struct UnreadableFolderDetails: LocalizedError {
    let folderID: Int64
    let fields: [String]
    var errorDescription: String? {
        let cover = fields.contains { $0.hasPrefix("additional.thumbnail") || $0.hasPrefix("additional:") }
        let permission = fields.contains { $0.hasPrefix("additional.access_permission") || $0.hasPrefix("additional:") }
        if cover && permission { return "Some folder cover images and download permission could not be read." }
        if cover { return "Some folder cover images could not be read." }
        return "Download permission could not be read."
    }
}

extension LibraryModel {
    /// Records each child of a freshly read listing that had unreadable details in History,
    /// once per folder and session.
    func noteUnreadableFolderDetails(in directory: FolderDirectory, space: PhotoSpace) {
        for child in directory.children where !child.unreadableFields.isEmpty {
            guard reportedUnreadableFolders.insert(.folder(child.id, space: space)).inserted else { continue }
            let error = UnreadableFolderDetails(folderID: child.id, fields: child.unreadableFields)
            activity.record(.unreadableFolderDetails(name: child.displayName), outcome: .failed,
                            failure: ActivityFailure(error: error, operation: "Folders"))
        }
    }
}
