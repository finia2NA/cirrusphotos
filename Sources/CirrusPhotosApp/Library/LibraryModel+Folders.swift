import Foundation
import PhotoCache
import SynologyAPI

/// A folder row whose cover or permission could not be read; the fields name what was left out.
struct UnreadableFolderDetails: LocalizedError {
    let folderID: Int64
    let fields: [String]
    var errorDescription: String? { "Its cover or download permission is not shown." }
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
