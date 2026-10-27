import SynologyAPI

struct MetadataChangeApplication: Sendable {
    let replacements: [PhotoItem]
    let deletedIDs: [Int64]
    let affectedDays: Set<CaptureDay>
    let invalidateAll: Bool

    static func prepare(diff: PhotoDiff, oldInventory: [MetadataIndexItem],
                        inventoryComplete: Bool, lookup: [PhotoItem]) throws -> Self {
        guard diff.isBoundedTerminal else { throw CollectionCatalogError.exceedsLimit }
        guard Set(lookup.map(\.id)).count == lookup.count,
              Set(lookup.map(\.id)) == Set(diff.modifiedItemIDs) else { throw CollectionCatalogError.invalidCoverage }
        let old = Dictionary(uniqueKeysWithValues: oldInventory.map { ($0.id, $0) })
        var days: Set<CaptureDay> = []
        var unknown = false
        for id in diff.modifiedItemIDs + diff.deletedItemIDs {
            if let prior = old[id] { days.insert(try CaptureDay(time: prior.time)) }
            else if !inventoryComplete { unknown = true }
        }
        for item in lookup { days.insert(try CaptureDay(time: item.time)) }
        return Self(replacements: lookup, deletedIDs: diff.deletedItemIDs, affectedDays: days, invalidateAll: unknown)
    }
}
