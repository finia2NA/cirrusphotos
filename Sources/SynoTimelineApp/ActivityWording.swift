import Foundation

/// Titles for Activity entries and History records.
enum ActivityWording {
    enum Stage { case running, done, failed }

    /// `total` renders "n of total" for a partly successful change.
    static func text(_ kind: ActivityKind, _ stage: Stage, count n: Int, of total: Int? = nil) -> String {
        let photos = quantity(n, total, "photo", "photos")
        let items = quantity(n, total, "item", "items")
        switch kind {
        case .favorite(let favorite):
            let verb = favorite ? "Favorit" : "Unfavorit"
            return pick(stage, "\(verb)ing \(photos)", "\(verb)ed \(photos)", "\(verb)ing failed for \(photos)")
        case .rotate(let direction):
            let side = direction == .clockwise ? "right" : "left"
            return pick(stage, "Rotating \(photos)", "Rotated \(photos) \(side)", "Rotating failed for \(photos)")
        case .rating(0):
            return pick(stage, "Clearing rating of \(photos)", "Cleared rating of \(photos)",
                        "Clearing rating failed for \(photos)")
        case .rating(let rating):
            let stars = String(repeating: "★", count: rating)
            return pick(stage, "Rating \(photos) \(stars)", "Rated \(photos) \(stars)", "Rating failed for \(photos)")
        case .addTags(let names):
            let tags = quoted(names)
            return pick(stage, "Tagging \(photos) \(tags)", "Tagged \(photos) \(tags)", "Tagging failed for \(photos)")
        case .newTag(let name):
            let tag = quoted([name])
            return pick(stage, "Tagging \(photos) \(tag)", "Tagged \(photos) \(tag)", "Tagging failed for \(photos)")
        case .removeTags(let names):
            let tags = quoted(names)
            return pick(stage, "Removing \(tags) from \(photos)", "Removed \(tags) from \(photos)",
                        "Removing tags failed for \(photos)")
        case .addToAlbum(_, let name), .addToIncomingAlbum(let name):
            return pick(stage, "Adding \(items) to \(name)", "Added \(items) to \(name)", "Adding to \(name) failed")
        case .createAlbum(let name):
            return pick(stage, "Creating album \(name)", "Created album \(name)", "Creating \(name) failed")
        case .removeFromAlbum(_, let name):
            return pick(stage, "Removing \(items) from \(name)", "Removed \(items) from \(name)",
                        "Removing from \(name) failed")
        case .deleteAlbum(let name):
            return pick(stage, "Deleting album \(name)", "Deleted album \(name)", "Deleting \(name) failed")
        case .deleteItems:
            return pick(stage, "Deleting \(items)", "Deleted \(items)", "Deleting failed for \(items)")
        case .download(let name):
            return pick(stage, name, "Downloaded \(name)", "\(name) failed")
        case .editHandoff(let name, let application):
            return pick(stage, name, "Opened \(name) in \(application)", "\(name) failed")
        case .filePromise(let name):
            return pick(stage, name, "Exported \(name)", "\(name) failed")
        case .upload(let destination):
            let target = destination.map { " to \($0)" } ?? ""
            return pick(stage, "Uploading \(photos)\(target)", "Uploaded \(photos)\(target)",
                        "Uploading failed for \(quantity(n, total, "file", "files"))")
        case .renameAlbum(let from, let to):
            return pick(stage, "Renaming album \(from)", "Renamed album \(from) to \(to)", "Renaming album \(from) failed")
        case .renamePerson(let name):
            return pick(stage, "Renaming person to \(name)", "Renamed person to \(name)", "Renaming person to \(name) failed")
        case .mergePerson(let source, let target):
            return pick(stage, "Merging \(source) into \(target)", "Merged \(source) into \(target)",
                        "Merging \(source) into \(target) failed")
        case .refresh:
            return pick(stage, "Refreshing from the NAS", "Refreshed from the NAS", "Refresh failed")
        case .metadataSync:
            return pick(stage, "Syncing library metadata", "Synced library metadata", "Metadata sync failed")
        case .notice(let title):
            return title
        case .unverified(let action):
            return pick(stage, action, action, "\(action) failed")
        case .albumSharing(let name):
            return pick(stage, "Updating sharing of \(name)", "Updated sharing of \(name)",
                        "Updating sharing of \(name) failed")
        }
    }

    static func quantity(_ n: Int, _ total: Int?, _ singular: String, _ plural: String) -> String {
        if let total { return "\(n) of \(total) \(total == 1 ? singular : plural)" }
        return "\(n) \(n == 1 ? singular : plural)"
    }

    private static func pick(_ stage: Stage, _ running: String, _ done: String, _ failed: String) -> String {
        switch stage {
        case .running: running
        case .done: done
        case .failed: failed
        }
    }

    private static func quoted(_ names: [String]) -> String {
        "“\(names.joined(separator: ", "))”"
    }
}

extension ActivityEntry {
    var title: String {
        switch phase {
        case .queued, .running:
            ActivityWording.text(kind, .running, count: max(totalCount - completedCount, 0))
        case .succeeded:
            ActivityWording.text(kind, .done, count: totalCount)
        case .cancelled:
            ActivityWording.text(kind, .running, count: totalCount)
        case .failed, .unconfirmed:
            ActivityWording.text(kind, .failed, count: failedItems.isEmpty ? totalCount : failedItems.count)
        }
    }

    /// The secondary line: the error, a waiting note, or the producer's status.
    var detail: String? {
        if phase == .unconfirmed { return [failure?.message, "May have been applied. Refresh to check."].compactMap { $0 }.joined(separator: " ") }
        if let failure { return [failure.message, status].compactMap { $0 }.joined(separator: " · ") }
        if phase == .queued { return status ?? "Waiting…" }
        return status
    }
}

extension HistoryRecord {
    var title: String {
        switch outcome {
        case .succeeded: ActivityWording.text(kind, .done, count: count)
        case .partial(let failed): ActivityWording.text(kind, .done, count: count, of: count + failed)
        case .failed, .unconfirmed: ActivityWording.text(kind, .failed, count: count)
        case .cancelled: "Cancelled: " + ActivityWording.text(kind, .running, count: count)
        }
    }

    var detail: String? {
        switch outcome {
        case .unconfirmed: [failure?.message, "May have been applied. Refresh to check."].compactMap { $0 }.joined(separator: " ")
        case .partial, .failed: failure?.message
        case .succeeded, .cancelled: nil
        }
    }
}
