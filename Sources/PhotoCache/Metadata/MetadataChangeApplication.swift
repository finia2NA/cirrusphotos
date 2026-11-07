import SynologyAPI

struct MetadataChangeApplication: Sendable {
    let replacements: [PhotoItem]
    let deletedIDs: [Int64]
    let affectedDays: Set<CaptureDay>
    let invalidateAll: Bool

    /// `referencedDays` holds, for changed IDs without an index row, the days of cached
    /// pages that still list them. An ID that no cached page lists cannot make one stale.
    static func prepare(diff: PhotoDiff, oldInventory: [MetadataIndexItem],
                        referencedDays: [Int64: Set<CaptureDay>], lookup: [PhotoItem]) throws -> Self {
        guard diff.isBoundedTerminal else { throw CollectionCatalogError.exceedsLimit }
        guard Set(lookup.map(\.id)).count == lookup.count,
              Set(lookup.map(\.id)) == Set(diff.modifiedItemIDs) else { throw CollectionCatalogError.invalidCoverage }
        let old = Dictionary(uniqueKeysWithValues: oldInventory.map { ($0.id, $0) })
        var days: Set<CaptureDay> = []
        for id in diff.modifiedItemIDs + diff.deletedItemIDs {
            if let prior = old[id] { days.insert(try CaptureDay(time: prior.time)) }
            days.formUnion(referencedDays[id] ?? [])
        }
        for item in lookup { days.insert(try CaptureDay(time: item.time)) }
        return Self(replacements: lookup, deletedIDs: diff.deletedItemIDs, affectedDays: days, invalidateAll: false)
    }
}
