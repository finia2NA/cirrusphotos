import Foundation
import SynologyAPI

enum LocationDeltaDecision: Sendable, Equatable {
    case unchanged
    case updated([PhotoLocationRecord])
    case rebuildRequired(String)
}

enum LocationIndexDelta {
    static let maximumChangedIDs = 2_000

    static func merge(
        existing: [PhotoLocationRecord],
        diff: PhotoDiff,
        lookup: LocationItemLookup?
    ) -> LocationDeltaDecision {
        guard !diff.hasAlbumActivity else {
            return .rebuildRequired("Album activity is not proven irrelevant to location coverage.")
        }
        let changedCount = diff.modifiedItemIDs.count + diff.deletedItemIDs.count
        guard changedCount <= maximumChangedIDs else {
            return .rebuildRequired("The location delta exceeds the client safety bound.")
        }
        guard Set(diff.modifiedItemIDs).count == diff.modifiedItemIDs.count,
              Set(diff.deletedItemIDs).count == diff.deletedItemIDs.count else {
            return .rebuildRequired("The location delta contains duplicate IDs.")
        }
        guard Set(diff.modifiedItemIDs).isDisjoint(with: diff.deletedItemIDs) else {
            return .rebuildRequired("The location delta contains conflicting changes.")
        }
        if diff.isEmpty { return .unchanged }

        let modifiedItems: [PhotoItem]
        if diff.modifiedItemIDs.isEmpty {
            modifiedItems = []
        } else {
            guard let lookup, lookup.requestedIDs == diff.modifiedItemIDs,
                  lookup.items.map(\.id) == diff.modifiedItemIDs else {
                return .rebuildRequired("The authoritative location lookup was incomplete or reordered.")
            }
            modifiedItems = lookup.items
        }

        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in diff.deletedItemIDs { byID.removeValue(forKey: id) }
        for item in modifiedItems {
            if let coordinate = item.coordinate {
                byID[item.id] = PhotoLocationRecord(
                    id: item.id,
                    time: item.time,
                    coordinate: coordinate,
                    thumbnail: item.additional?.thumbnail
                )
            } else {
                byID.removeValue(forKey: item.id)
            }
        }
        let merged = byID.values.sorted {
            if $0.time != $1.time { return $0.time > $1.time }
            return $0.id < $1.id
        }
        return merged == existing ? .unchanged : .updated(merged)
    }
}
