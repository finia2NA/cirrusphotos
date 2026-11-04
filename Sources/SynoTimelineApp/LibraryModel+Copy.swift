import AppKit
import PhotoCache
import SynologyAPI

/// Edit > Copy on a browser selection puts its filenames and item IDs on the pasteboard as text.
/// File copy for Finder and Photos is not implemented yet; drag and drop provides that, with the same text beside it.
extension LibraryModel {
    /// Resolves the captured selection, including unloaded items, then replaces the pasteboard text.
    /// The pasteboard keeps its previous contents until resolution finishes, and on failure.
    func copySelectionText(_ snapshot: BrowserCommandSnapshot) {
        guard let repository, let captured = snapshot.captureSelection(timeline: snapshot.timeline) else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            guard let text = await SelectionText.resolve(captured, repository: repository) else {
                NSSound.beep()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
