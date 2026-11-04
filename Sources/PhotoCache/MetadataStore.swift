import Foundation
import GRDB
import OSLog
import SynologyAPI
import TimelineCore

/// Account/server identity and content authority jointly scope every stored item ID.
public struct MetadataNamespace: Hashable, Sendable {
    public let account: String
    public let scope: PhotoContentScope
    public init(account: String, scope: PhotoContentScope) {
        self.account = account; self.scope = scope
    }
    var key: String { account + "|" + scope.cacheComponent }
}
public struct CollectionKey: Hashable, Sendable {
    public let namespace: MetadataNamespace
    public let collection: PhotoCollectionDescriptor
    public init(namespace: MetadataNamespace, collection: PhotoCollectionDescriptor) {
        self.namespace = namespace; self.collection = collection
    }
}
public struct MetadataIndexItem: Codable, Sendable {
    public let id: Int64
    public let time: Int64
    public let coordinate: PhotoCoordinate?
    public let thumbnail: ThumbnailInfo?
}

public struct MetadataStoreVersion: Equatable, Sendable {
    public let revision: Int64
    public let resetEpoch: Int64
    public let cursor: DiffCursor?
    public let inventoryComplete: Bool
    public let proofRun: String?
}
public struct StoredCollectionCatalog: Sendable {
    public let catalog: CollectionDayCatalog
    public let presentationRevision: Int64
    public let validatedRun: String?
}
public struct MetadataStoreAdmission: Sendable {
    public let namespace: MetadataNamespace
    public let generation: Int
    public let metadataGeneration: Int
    public let revision: Int64
    public let resetEpoch: Int64
}

/// Typed record access on the existing cache actor. No transaction suspends.
/// The normalized format is initialized explicitly when the engine enrolls it.
extension DiskCache {
    static let metadataFormatVersion = 9

    public func initializeMetadataStore() throws {
        try database.inTransaction(.immediate) { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS metadata_format (version INTEGER NOT NULL)")
            if try Int.fetchOne(db, sql: "SELECT version FROM metadata_format") != Self.metadataFormatVersion {
                // Superseded metadata is dropped, never decoded. Media records are unchanged.
                let keep: Set = [CacheEntryRecord.databaseTableName, "metadata_format"]
                for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                where !keep.contains(table) { try db.drop(table: table) }
                try db.execute(sql: "DELETE FROM metadata_format; INSERT INTO metadata_format VALUES (\(Self.metadataFormatVersion))")
            }
            try CacheSchema.createMetadataTables(db)
            return .commit
        }
        metadataInitialized = true
    }

    func clearNormalizedMetadata(_ db: Database) throws {
        guard try db.tableExists(MetadataStateRecord.databaseTableName) else { return }
        for table in CacheSchema.metadataTables { try Table(table).deleteAll(db) }
    }

    // MARK: State and admission

    public func metadataState(_ namespace: MetadataNamespace) throws -> MetadataStoreVersion {
        try database.read { try metadataState($0, namespace) }
    }
    func metadataState(_ db: Database, _ namespace: MetadataNamespace) throws -> MetadataStoreVersion {
        guard let state = try MetadataStateRecord.fetchOne(db, key: namespace.key) else {
            return MetadataStoreVersion(revision: 0, resetEpoch: 0, cursor: nil, inventoryComplete: false, proofRun: nil)
        }
        return MetadataStoreVersion(revision: state.revision, resetEpoch: state.resetEpoch, cursor: state.cursor,
                                    inventoryComplete: state.inventoryComplete, proofRun: state.proofRun)
    }
    public func metadataAdmission(_ namespace: MetadataNamespace) throws -> MetadataStoreAdmission {
        let state = try metadataState(namespace)
        return MetadataStoreAdmission(namespace: namespace, generation: generation, metadataGeneration: metadataGeneration,
                                      revision: state.revision, resetEpoch: state.resetEpoch)
    }
    private func admit(_ admission: MetadataStoreAdmission, namespace: MetadataNamespace, _ db: Database) throws {
        let state = try metadataState(db, namespace)
        try admitLifetime(admission, namespace: namespace)
        guard state.revision == admission.revision, state.resetEpoch == admission.resetEpoch else {
            throw MetadataAdmissionError.superseded
        }
    }
    /// Local mutation patches intentionally tolerate revision changes caused by
    /// other serialized writes, while retaining namespace/reset fencing.
    private func admitLifetime(_ admission: MetadataStoreAdmission, namespace: MetadataNamespace) throws {
        guard namespace == admission.namespace, generation == admission.generation,
              metadataGeneration == admission.metadataGeneration else { throw MetadataAdmissionError.superseded }
    }
    private func writeState(_ db: Database, _ namespace: MetadataNamespace, revision: Int64, resetEpoch: Int64,
                            cursor: DiffCursor?, inventoryComplete: Bool, proofRun: String?) throws {
        try MetadataStateRecord(namespace: namespace.key, revision: revision, resetEpoch: resetEpoch, cursor: cursor,
                                inventoryComplete: inventoryComplete, proofRun: proofRun).insert(db, onConflict: .replace)
    }
    private func advanceMetadataLocalRevision(_ db: Database, _ namespace: MetadataNamespace) throws {
        let prior = try metadataState(db, namespace)
        try writeState(db, namespace, revision: prior.revision + 1, resetEpoch: prior.resetEpoch,
                       cursor: prior.cursor, inventoryComplete: prior.inventoryComplete, proofRun: prior.proofRun)
    }
    private func markInventoryIncomplete(_ db: Database, _ namespace: String, cause: @autoclosure () -> String) throws {
        let cleared = try MetadataStateRecord.filter { $0.namespace == namespace && $0.inventoryComplete }
            .updateAll(db) { $0.inventoryComplete.set(to: false) }
        if cleared > 0 {
            let scope = namespace.split(separator: "|").last.map(String.init) ?? "?", reason = cause()
            SynologyDiagnostics.diff.notice("\(scope, privacy: .public) inventory marked incomplete: \(reason, privacy: .public)")
        }
    }

    // MARK: Summaries

    func filterOptionCatalog(_ key: CollectionKey) throws -> LibraryFilterCatalog? {
        try? database.read { try FilterOptionCatalogRecord.row(key).fetchOne($0) }?.payload
    }

    func storeFilterOptionCatalog(_ catalog: LibraryFilterCatalog, key: CollectionKey,
                                  admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admit(admission, namespace: key.namespace, db)
            try FilterOptionCatalogRecord(namespace: key.namespace.key, collection: key.collection.rawValue, payload: catalog)
                .insert(db, onConflict: .replace)
        }
    }

    public func metadataCollectionIndex(_ kind: CollectionIndexKind, namespace: MetadataNamespace) throws -> ([CollectionIndexEntry], String?)? {
        guard let record = try database.read({ try CollectionSummaryRecord.row(namespace, kind).fetchOne($0) }) else { return nil }
        return (try CollectionIndexEntry.decoder(for: kind).decode([CollectionIndexEntry].self, from: record.payload), record.validatedRun)
    }

    public func storeMetadataCollectionIndex(_ kind: CollectionIndexKind, _ entries: [CollectionIndexEntry], namespace: MetadataNamespace,
                                             currentRun: String, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            try CollectionSummaryRecord(namespace: namespace.key, kind: kind, payload: JSONEncoder().encode(entries), validatedRun: currentRun)
                .insert(db, onConflict: .replace)
        }
    }

    public func invalidateMetadataCollectionIndex(_ kind: CollectionIndexKind, namespace: MetadataNamespace, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            try CollectionSummaryRecord.row(namespace, kind).updateAll(db) { $0.validatedRun.set(to: nil) }
            try advanceMetadataLocalRevision(db, namespace)
        }
    }

    public func metadataFolderDirectory(_ namespace: MetadataNamespace, id: Int64) throws -> (FolderDirectory, String?)? {
        try database.read { try FolderDirectoryRecord.row(namespace, id).fetchOne($0) }.map { ($0.payload, $0.validatedRun) }
    }
    public func storeMetadataFolderDirectory(_ value: FolderDirectory, namespace: MetadataNamespace, id: Int64, currentRun: String, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            let previous = try FolderDirectoryRecord.row(namespace, id).fetchOne(db)?.payload
            try FolderDirectoryRecord(namespace: namespace.key, folderID: id, payload: value, validatedRun: currentRun)
                .insert(db, onConflict: .replace)
            // A changed listing can change the folder's cover and those of its ancestors, nothing else.
            if let previous, previous != value {
                var affected: Set<Int64> = [id]
                var parent = value.folder.parent
                while affected.count < 64, affected.insert(parent).inserted,
                      let next = try FolderDirectoryRecord.row(namespace, parent).fetchOne(db) { parent = next.payload.folder.parent }
                try FolderCoverRecord.filter { $0.namespace == namespace.key && affected.contains($0.folderID) }
                    .updateAll(db) { $0.validatedRun.set(to: nil) }
            }
        }
    }

    public func metadataFolderCovers(_ namespace: MetadataNamespace, id: Int64) throws -> (covers: [ThumbnailInfo], validatedRun: String?)? {
        try database.read { try FolderCoverRecord.row(namespace, id).fetchOne($0) }.map { ($0.payload, $0.validatedRun) }
    }
    public func storeMetadataFolderCovers(_ covers: [ThumbnailInfo], namespace: MetadataNamespace, id: Int64, currentRun: String,
                                          admission: MetadataStoreAdmission) throws {
        // Derived display data: it needs reset fencing, not revision fencing, and holds no media to trim.
        try metadataWrite(enforceBudget: false) { db in
            try admitLifetime(admission, namespace: namespace)
            try FolderCoverRecord(namespace: namespace.key, folderID: id, payload: covers, validatedRun: currentRun)
                .insert(db, onConflict: .replace)
        }
    }
    public func invalidateMetadataFolderCovers(namespace: MetadataNamespace, admission: MetadataStoreAdmission) throws {
        try metadataWrite(enforceBudget: false) { db in
            try admitLifetime(admission, namespace: namespace)
            try FolderCoverRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
        }
    }

    public func metadataAlbumSummaries(_ namespace: MetadataNamespace) throws -> (albums: [AlbumSummary], validatedRun: String?)? {
        try database.read { try AlbumSummariesRecord.fetchOne($0, key: namespace.key) }.map { ($0.payload, $0.validatedRun) }
    }
    public func storeMetadataAlbumSummaries(_ albums: [AlbumSummary], namespace: MetadataNamespace,
                                            currentRun: String, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            try AlbumSummariesRecord(namespace: namespace.key, payload: albums, validatedRun: currentRun,
                                     revision: admission.revision, accessed: Date().timeIntervalSince1970)
                .insert(db, onConflict: .replace)
        }
    }

    public func invalidateMetadataAlbumSummaries(_ namespace: MetadataNamespace, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            try AlbumSummariesRecord.filter(key: namespace.key).updateAll(db) { $0.validatedRun.set(to: nil) }
            try advanceMetadataLocalRevision(db, namespace)
        }
    }

    // MARK: Collection catalogs

    public func metadataCatalog(_ key: CollectionKey) throws -> StoredCollectionCatalog? {
        try database.read { try metadataCatalog($0, key) }
    }
    private func metadataCatalog(_ db: Database, _ key: CollectionKey) throws -> StoredCollectionCatalog? {
        try CollectionStateRecord.row(key).fetchOne(db).map {
            StoredCollectionCatalog(catalog: $0.catalog, presentationRevision: $0.presentationRevision, validatedRun: $0.validatedRun)
        }
    }
    public func metadataDayGeneration(_ key: CollectionKey, day: CaptureDay) throws -> Int64? {
        try database.read { try CollectionDayRecord.row(key, day: day.id).fetchOne($0)?.membershipGeneration }
    }

    /// Catalog presentation changes never stamp unaffected days with a new generation.
    public func storeMetadataCatalog(_ catalog: CollectionDayCatalog, key: CollectionKey,
                                     validatedRun: String, admission: MetadataStoreAdmission, invalidateMembership: Bool = false) throws {
        try metadataWrite { db in
            try admit(admission, namespace: key.namespace, db)
            let prior = try metadataCatalog(db, key)
            let old = Dictionary(uniqueKeysWithValues: (prior?.catalog.days ?? []).map { ($0.day, $0.count) })
            let nextDays = Set(catalog.days.map(\.day))
            for entry in prior?.catalog.days ?? [] where !nextDays.contains(entry.day) {
                try deleteMetadataDay(db, key, day: entry.day)
            }
            var changed = prior == nil || prior?.catalog.completeness != catalog.completeness || old.count != catalog.days.count
            let stored = Dictionary(uniqueKeysWithValues: try CollectionDayRecord.all(key).fetchAll(db).map { ($0.day, $0) })
            for entry in catalog.days {
                if old[entry.day] != entry.count { changed = true }
                let existing = stored[entry.day.id]
                let advance = existing == nil || existing?.itemCount != entry.count || invalidateMembership
                try CollectionDayRecord(namespace: key.namespace.key, collection: key.collection.rawValue, day: entry.day.id,
                                        itemCount: entry.count, membershipGeneration: (existing?.membershipGeneration ?? 0) + (advance ? 1 : 0)).upsert(db)
            }
            try CollectionStateRecord(namespace: key.namespace.key, collection: key.collection.rawValue, catalog: catalog,
                                      presentationRevision: (prior?.presentationRevision ?? 0) + (changed ? 1 : 0),
                                      validatedRun: validatedRun, epoch: admission.resetEpoch).insert(db, onConflict: .replace)
        }
    }

    // MARK: Day pages

    /// Content is proven when this run's Diff reconciliation of the namespace's space accounted
    /// for every change since the stored cursor. Membership additionally needs this run's day
    /// catalog for a collection whose membership the feeds describe; changed days already carry
    /// new generations.
    private func changeProof(_ db: Database, _ key: CollectionKey, state: MetadataStoreVersion,
                             currentRun: String) throws -> (content: Bool, membership: Bool) {
        let content = state.proofRun == currentRun
        guard content, key.collection.membershipProvenByChanges else { return (content, false) }
        let catalog = try Row.fetchOne(db, CollectionStateRecord.row(key)
            .select(CollectionStateRecord.Columns.validatedRun, CollectionStateRecord.Columns.epoch))
        let membership = catalog.map { $0[CollectionStateRecord.Columns.validatedRun] as String? == currentRun
            && $0[CollectionStateRecord.Columns.epoch] as Int64 == state.resetEpoch } ?? false
        return (content, membership)
    }

    public func metadataPage(_ address: DayPageAddress, namespace: MetadataNamespace,
                             currentRun: String) throws -> PhotoPageSnapshot? {
        try metadataWrite(enforceBudget: false) { db in
            guard let page = try DayPageRecord.page(address, namespace).fetchOne(db) else { return nil }
            guard page.actualCount > 0, page.actualCount <= address.capacity, page.revision >= 0 else { throw CacheError.storage }
            let state = try metadataState(db, namespace)
            // The day row carries the catalog's count for this day; reading it avoids decoding the whole catalog.
            let key = CollectionKey(namespace: namespace, collection: address.collection)
            let day = try CollectionDayRecord.row(key, day: address.day.id).fetchOne(db)
            let proof = try changeProof(db, key, state: state, currentRun: currentRun)
            var membershipVerified = (page.validatedRun == currentRun || proof.membership) && page.epoch == state.resetEpoch
                && day?.membershipGeneration == page.dayGeneration && day?.itemCount == page.dayCount
            let members = try PageItemRecord.page(address, namespace).order { $0.ordinal }.fetchAll(db)
            let ids = members.map(\.itemID)
            let details = try itemDetails(db, namespace, ids: ids)
            var slots: [PhotoItemSlot] = []
            for member in members {
                guard member.ordinal == slots.count else { throw CacheError.storage }
                let detail = details[member.itemID]
                guard detail == nil || detail?.payload.id == member.itemID else { throw CacheError.storage }
                if let item = detail?.payload {
                    let time = address.collection.membershipTime(for: item)
                    if time.flatMap({ try? CaptureDay(time: $0) }) != address.day { membershipVerified = false }
                }
                let detailVerified = detail?.contentEpoch == state.resetEpoch && (detail?.annotationRun == currentRun || proof.content)
                slots.append(PhotoItemSlot(itemID: member.itemID, item: detail?.payload, verified: membershipVerified && detailVerified))
            }
            guard slots.count == page.actualCount else { throw CacheError.storage }
            let now = Date().timeIntervalSince1970
            try DayPageRecord.page(address, namespace).updateAll(db) { $0.accessed.set(to: now) }
            try ItemDetailRecord.filter { $0.namespace == namespace.key && ids.contains($0.itemID) }.updateAll(db) { $0.accessed.set(to: now) }
            return PhotoPageSnapshot(address: address, membershipRevision: UInt64(page.revision), membershipVerified: membershipVerified,
                                     slots: slots.map { PhotoItemSlot(itemID: $0.itemID, item: $0.item, verified: membershipVerified && $0.verified) })
        }
    }

    /// Membership and combined details commit together. Identity/location profiles do not overwrite full details.
    public func storeMetadataPage(_ page: DayPageRead, items: [PhotoItem], profile: ItemFieldProfile,
                                  namespace: MetadataNamespace, currentRun: String,
                                  admission: MetadataStoreAdmission) throws {
        guard items.count == page.count, Set(items.map(\.id)).count == items.count,
              try items.allSatisfy({ item in
                  guard let time = page.address.collection.membershipTime(for: item) else { return false }
                  return try CaptureDay(time: time) == page.address.day
              }) else { throw CollectionCatalogError.invalidCoverage }
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            let key = CollectionKey(namespace: namespace, collection: page.address.collection)
            guard let expectedDay = try CollectionDayRecord.row(key, day: page.address.day.id).fetchOne(db)?.membershipGeneration,
                  expectedDay >= 0, UInt64(expectedDay) == page.membershipGeneration else { throw MetadataAdmissionError.superseded }
            for item in items {
                try storeMetadataItem(db, item, profile: profile, namespace: namespace, currentRun: currentRun, epoch: admission.resetEpoch,
                                      revision: admission.revision, origin: "\(profile.rawValue) page \(page.address.collection.rawValue)")
            }
            try storeMetadataMembership(db, page, ids: items.map(\.id), namespace: namespace, currentRun: currentRun, admission: admission)
        }
    }

    private func storeMetadataMembership(_ db: Database, _ page: DayPageRead, ids: [Int64], namespace: MetadataNamespace,
                                         currentRun: String, admission: MetadataStoreAdmission) throws {
        let address = page.address
        let revision = (try DayPageRecord.page(address, namespace).fetchOne(db)?.revision ?? 0) + 1
        try deleteMetadataPage(db, address, namespace: namespace)
        try DayPageRecord(namespace: namespace.key, collection: address.collection.rawValue, day: address.day.id,
                          pageOffset: address.offset, capacity: address.capacity, sortOrder: address.order.rawValue,
                          actualCount: page.count, dayCount: page.dayCount, dayGeneration: Int64(page.membershipGeneration),
                          revision: revision, epoch: admission.resetEpoch, validatedRun: currentRun,
                          accessed: Date().timeIntervalSince1970).insert(db)
        for (ordinal, id) in ids.enumerated() {
            try PageItemRecord(namespace: namespace.key, collection: address.collection.rawValue, day: address.day.id,
                               pageOffset: address.offset, capacity: address.capacity, sortOrder: address.order.rawValue,
                               ordinal: ordinal, itemID: id).insert(db)
        }
    }

    public func storeMetadataIdentityPage(_ page: DayPageRead, entries: [DayTimelineEntry], namespace: MetadataNamespace,
                                          currentRun: String, admission: MetadataStoreAdmission) throws {
        guard entries.count == page.count, Set(entries.map(\.id)).count == entries.count,
              try entries.allSatisfy({ try CaptureDay(time: $0.time) == page.address.day }) else { throw CollectionCatalogError.invalidCoverage }
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            let key = CollectionKey(namespace: namespace, collection: page.address.collection)
            guard try CollectionDayRecord.row(key, day: page.address.day.id).fetchOne(db)?.membershipGeneration == Int64(page.membershipGeneration) else {
                throw MetadataAdmissionError.superseded
            }
            let identityOnly = ItemFieldProfile.identityAndTime.rawValue
            for entry in entries {
                let known = try ItemIndexRecord.row(namespace, entry.id).fetchOne(db)
                let currentLocation = known.map { $0.captureTime == entry.time && $0.epoch == admission.resetEpoch && $0.profile != identityOnly } ?? false
                if !currentLocation {
                    let reason = known.map { "identity page \(page.address.collection.rawValue) lists an item with profile \($0.profile), "
                        + "epoch \($0.epoch) of \(admission.resetEpoch), time changed \($0.captureTime != entry.time)" }
                        ?? "identity page \(page.address.collection.rawValue) lists an unindexed item"
                    try markInventoryIncomplete(db, namespace.key, cause: reason)
                }
                var index = known ?? ItemIndexRecord(namespace: namespace.key, itemID: entry.id, captureTime: entry.time, projection: nil,
                                                     profile: identityOnly, epoch: -1, identityEpoch: admission.resetEpoch)
                if index.captureTime != entry.time { index.epoch = -1 }
                index.captureTime = entry.time
                index.identityEpoch = admission.resetEpoch
                try index.upsert(db)
                if var detail = try ItemDetailRecord.row(namespace, entry.id).fetchOne(db), detail.payload.time != entry.time {
                    detail.contentEpoch = -1
                    try detail.update(db, columns: [ItemDetailRecord.Columns.contentEpoch])
                }
            }
            try storeMetadataMembership(db, page, ids: entries.map(\.id), namespace: namespace, currentRun: currentRun, admission: admission)
        }
    }

    /// `origin` names the writer for diagnostics; nil marks an applied Diff interval, which
    /// accounts for every item it adds, so it keeps a complete inventory complete.
    private func storeMetadataItem(_ db: Database, _ item: PhotoItem, profile: ItemFieldProfile, namespace: MetadataNamespace,
                                   currentRun: String, epoch: Int64, revision: Int64, origin: String?) throws {
        _ = try CaptureDay(time: item.time)
        let known = try ItemIndexRecord.row(namespace, item.id).fetchOne(db)
        if let origin, known == nil || (profile == .identityAndTime && known?.captureTime != item.time) {
            try markInventoryIncomplete(db, namespace.key, cause: known == nil ? "\(origin) stored an unindexed item"
                                        : "\(origin) changed an item's capture time")
        }
        // Only a requested GPS profile may replace the compact projection with absent GPS.
        var index: ItemIndexRecord
        if profile == .identityAndTime, let known {
            index = known
            if known.captureTime != item.time { index.epoch = -1 }
            index.captureTime = item.time
            index.identityEpoch = epoch
        } else {
            index = ItemIndexRecord(namespace: namespace.key, itemID: item.id, captureTime: item.time,
                                    projection: profile == .identityAndTime ? nil
                                        : MetadataIndexItem(id: item.id, time: item.time, coordinate: item.coordinate, thumbnail: item.additional?.thumbnail),
                                    profile: profile.rawValue, epoch: profile == .identityAndTime ? -1 : epoch, identityEpoch: epoch)
        }
        try index.upsert(db)
        guard profile == .fullPage else {
            if var full = try ItemDetailRecord.row(namespace, item.id).fetchOne(db),
               full.payload.time != item.time || (profile == .locations && (full.payload.coordinate != item.coordinate || full.payload.additional?.thumbnail != item.additional?.thumbnail)) {
                full.contentEpoch = -1
                try full.update(db, columns: [ItemDetailRecord.Columns.contentEpoch])
            }
            return
        }
        try ItemDetailRecord(namespace: namespace.key, itemID: item.id, payload: item, contentEpoch: epoch, annotationRun: currentRun,
                             revision: revision, accessed: Date().timeIntervalSince1970).insert(db, onConflict: .replace)
    }

    // MARK: Filter facets

    /// Applies the verification of `metadataPage` to every stored page of a collection in one read,
    /// without touching LRU state. Pages `metadataPage` would reject are skipped.
    func metadataFilterPages(_ namespace: MetadataNamespace, collection: PhotoCollectionDescriptor,
                             days: Set<CaptureDay>?, currentRun: String) throws -> [MetadataFilterPage] {
        guard metadataInitialized else { return [] }
        return try database.read { db in
            let state = try metadataState(db, namespace)
            let proof = try changeProof(db, CollectionKey(namespace: namespace, collection: collection), state: state, currentRun: currentRun)
            let dayIDs = days.map { $0.map(\.id) }
            var pageRequest = DayPageRecord.filter { $0.namespace == namespace.key && $0.collection == collection.rawValue }
            var memberRequest = PageItemRecord.filter { $0.namespace == namespace.key && $0.collection == collection.rawValue }
            var dayRequest = CollectionDayRecord.filter { $0.namespace == namespace.key && $0.collection == collection.rawValue }
            if let dayIDs {
                pageRequest = pageRequest.filter { dayIDs.contains($0.day) }
                memberRequest = memberRequest.filter { dayIDs.contains($0.day) }
                dayRequest = dayRequest.filter { dayIDs.contains($0.day) }
            }
            let pages = try pageRequest.fetchAll(db)
            let members = try memberRequest.fetchAll(db)
            let dayRows = Dictionary(uniqueKeysWithValues: try dayRequest.fetchAll(db).map { ($0.day, $0) })
            var facets: [Int64: ItemFacetRecord] = [:]
            let facetRequest = ItemFacetRecord.filter(ItemDetailRecord.Columns.namespace == namespace.key)
            if dayIDs == nil {
                for record in try facetRequest.fetchAll(db) { facets[record.itemID] = record }
            } else {
                let ids = members.map(\.itemID)
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let batch = Array(ids[start..<min(start + 500, ids.count)])
                    for record in try facetRequest.filter(batch.contains(ItemDetailRecord.Columns.itemID)).fetchAll(db) { facets[record.itemID] = record }
                }
            }
            let membersByPage = Dictionary(grouping: members) {
                FilterPageKey(day: $0.day, offset: $0.pageOffset, capacity: $0.capacity, order: $0.sortOrder)
            }
            var result: [MetadataFilterPage] = []
            for page in pages {
                guard page.actualCount > 0, page.actualCount <= page.capacity, page.revision >= 0,
                      let day = CaptureDay(id: page.day), let order = CollectionOrder(rawValue: page.sortOrder),
                      let address = try? DayPageAddress(collection: collection, day: day, offset: page.pageOffset, capacity: page.capacity, order: order)
                else { continue }
                let pageMembers = (membersByPage[FilterPageKey(day: page.day, offset: page.pageOffset, capacity: page.capacity, order: page.sortOrder)] ?? [])
                    .sorted { $0.ordinal < $1.ordinal }
                guard pageMembers.count == page.actualCount, pageMembers.indices.allSatisfy({ pageMembers[$0].ordinal == $0 }) else { continue }
                let dayRow = dayRows[page.day]
                var membershipVerified = (page.validatedRun == currentRun || proof.membership) && page.epoch == state.resetEpoch
                    && dayRow?.membershipGeneration == page.dayGeneration && dayRow?.itemCount == page.dayCount
                var detailsVerified = true
                var entries: [MetadataFilterEntry] = []
                for member in pageMembers {
                    guard let record = facets[member.itemID] else { detailsVerified = false; continue }
                    let time = record.facets.membershipTime(in: collection)
                    if time.flatMap({ try? CaptureDay(time: $0) }) != day { membershipVerified = false }
                    if !(record.contentEpoch == state.resetEpoch && (record.annotationRun == currentRun || proof.content)) { detailsVerified = false }
                    entries.append(MetadataFilterEntry(ordinal: member.ordinal, itemID: member.itemID, time: time, values: record.facets.values))
                }
                result.append(MetadataFilterPage(address: address, entries: entries, verified: membershipVerified && detailsVerified))
            }
            return result.sorted { $0.address.day > $1.address.day || ($0.address.day == $1.address.day && $0.address.offset < $1.address.offset) }
        }
    }

    // MARK: Item details

    public func metadataDetails(_ namespace: MetadataNamespace, ids: [Int64], currentRun: String) throws -> [Int64: PhotoItemSlot] {
        guard ids.count <= 2000 else { throw CollectionCatalogError.exceedsLimit }
        return try database.read { db in
            let state = try metadataState(db, namespace)
            let proven = state.proofRun == currentRun
            return try itemDetails(db, namespace, ids: ids).mapValues {
                PhotoItemSlot(itemID: $0.itemID, item: $0.payload,
                              verified: $0.contentEpoch == state.resetEpoch && ($0.annotationRun == currentRun || proven))
            }
        }
    }
    private func itemDetails(_ db: Database, _ namespace: MetadataNamespace, ids: [Int64]) throws -> [Int64: ItemDetailRecord] {
        var result: [Int64: ItemDetailRecord] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            for record in try ItemDetailRecord.filter({ $0.namespace == namespace.key && batch.contains($0.itemID) }).fetchAll(db) {
                result[record.itemID] = record
            }
        }
        return result
    }

    public func storeMetadataDetails(_ items: [PhotoItem], namespace: MetadataNamespace,
                                     currentRun: String, admission: MetadataStoreAdmission) throws -> Set<CaptureDay> {
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            var dirtyDays: Set<CaptureDay> = []
            for item in items {
                if let old = try ItemDetailRecord.row(namespace, item.id).fetchOne(db), old.contentEpoch == admission.resetEpoch,
                   old.payload.withFavorite(false) != item.withFavorite(false) {
                    dirtyDays.insert(try CaptureDay(time: old.payload.time)); dirtyDays.insert(try CaptureDay(time: item.time))
                }
                try storeMetadataItem(db, item, profile: .fullPage, namespace: namespace, currentRun: currentRun,
                                      epoch: admission.resetEpoch, revision: admission.revision, origin: "detail read")
            }
            if !dirtyDays.isEmpty {
                let days = dirtyDays.map(\.id)
                try CollectionDayRecord.filter { $0.namespace == namespace.key && days.contains($0.day) }
                    .updateAll(db) { $0.membershipGeneration += 1 }
                try CollectionStateRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
                try advanceMetadataLocalRevision(db, namespace)
            }
            return dirtyDays
        }
    }

    public func metadataCollectionReferences(_ namespace: MetadataNamespace, collection: PhotoCollectionDescriptor, ids: [Int64]) throws -> [TimelineSection] {
        guard ids.count <= 100 else { throw CollectionCatalogError.exceedsLimit }
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            let members = try PageItemRecord.filter {
                $0.namespace == namespace.key && $0.collection == collection.rawValue && ids.contains($0.itemID)
            }.fetchAll(db)
            struct Reference: Hashable { let day: String; let offset: Int; let count: Int; let dayCount: Int }
            var seen = Set<Reference>()
            var sections: [TimelineSection] = []
            for member in members {
                guard let page = try DayPageRecord.page(of: member).fetchOne(db),
                      seen.insert(Reference(day: page.day, offset: page.pageOffset, count: page.actualCount, dayCount: page.dayCount)).inserted
                else { continue }
                let parts = page.day.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3 else { throw CacheError.storage }
                let day = try CaptureDay(year: parts[0], month: parts[1], day: parts[2])
                sections.append(TimelineSection(offset: page.pageOffset, limit: page.actualCount,
                                                list: [TimelineDay(year: day.year, month: day.month, day: day.day, itemCount: page.dayCount)]))
            }
            return sections
        }
    }

    // MARK: Item index and locations

    /// The number of indexed items when the namespace holds a complete inventory, otherwise nil.
    public func metadataCompleteInventoryCount(_ namespace: MetadataNamespace) throws -> Int? {
        try database.read { db in
            let state = try metadataState(db, namespace)
            guard state.inventoryComplete else { return nil }
            return try ItemIndexRecord.filter { $0.namespace == namespace.key && $0.identityEpoch == state.resetEpoch }.fetchCount(db)
        }
    }
    public func metadataItemTimes(_ namespace: MetadataNamespace, ids: [Int64]) throws -> [MetadataIndexItem] {
        guard ids.count <= 2000 else { throw CollectionCatalogError.exceedsLimit }
        return try database.read { db in
            let epoch = try metadataState(db, namespace).resetEpoch
            return try ItemIndexRecord.filter { $0.namespace == namespace.key && $0.identityEpoch == epoch && ids.contains($0.itemID) }
                .fetchAll(db).map { MetadataIndexItem(id: $0.itemID, time: $0.captureTime, coordinate: nil, thumbnail: nil) }
        }
    }

    /// Days of every cached page, in any collection of the namespace, that lists one of the IDs.
    public func metadataReferencedDays(_ namespace: MetadataNamespace, ids: [Int64]) throws -> [Int64: Set<CaptureDay>] {
        guard ids.count <= 2000 else { throw CollectionCatalogError.exceedsLimit }
        return try database.read { db in
            var result: [Int64: Set<CaptureDay>] = [:]
            for member in try PageItemRecord.filter({ $0.namespace == namespace.key && ids.contains($0.itemID) }).fetchAll(db) {
                if let day = CaptureDay(id: member.day) { result[member.itemID, default: []].insert(day) }
            }
            return result
        }
    }

    public func metadataInventory(_ namespace: MetadataNamespace) throws -> [MetadataIndexItem] {
        try database.read { db in
            try ItemIndexRecord.filter { $0.namespace == namespace.key }.order { [$0.captureTime.desc, $0.itemID] }.fetchAll(db).map {
                MetadataIndexItem(id: $0.itemID, time: $0.captureTime, coordinate: $0.projection?.coordinate, thumbnail: $0.projection?.thumbnail)
            }
        }
    }

    public func metadataLocationProjection(_ namespace: MetadataNamespace, currentOnly: Bool = false) throws -> (state: MetadataStoreVersion, records: [PhotoLocationRecord]) {
        (try metadataState(namespace), currentOnly ? try metadataCurrentLocations(namespace) : try metadataCachedLocations(namespace))
    }
    public func metadataCachedLocations(_ namespace: MetadataNamespace) throws -> [PhotoLocationRecord] {
        try database.read { db in
            locations(try ItemIndexRecord.filter { $0.namespace == namespace.key && $0.projection != nil }.fetchAll(db))
        }.sorted { $0.time > $1.time || ($0.time == $1.time && $0.id < $1.id) }
    }
    public func metadataCurrentLocations(_ namespace: MetadataNamespace) throws -> [PhotoLocationRecord] {
        let identityOnly = ItemFieldProfile.identityAndTime.rawValue
        return try database.read { db in
            let epoch = try metadataState(db, namespace).resetEpoch
            return locations(try ItemIndexRecord.filter {
                $0.namespace == namespace.key && $0.epoch == epoch && $0.profile != identityOnly
            }.fetchAll(db))
        }.sorted { $0.time > $1.time }
    }
    private func locations(_ records: [ItemIndexRecord]) -> [PhotoLocationRecord] {
        records.compactMap { record in
            record.projection?.coordinate.map {
                PhotoLocationRecord(id: record.itemID, time: record.captureTime, coordinate: $0, thumbnail: record.projection?.thumbnail)
            }
        }
    }

    public func stageMetadataInventory(_ items: [PhotoItem], job: UUID, namespace: MetadataNamespace,
                                      admission: MetadataStoreAdmission) throws {
        guard items.count <= 1000 else { throw CollectionCatalogError.exceedsLimit }
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            for item in items {
                _ = try CaptureDay(time: item.time)
                try InventoryStagingRecord(job: job.uuidString, namespace: namespace.key, itemID: item.id, captureTime: item.time,
                                           projection: MetadataIndexItem(id: item.id, time: item.time, coordinate: item.coordinate, thumbnail: item.additional?.thumbnail))
                    .insert(db)
            }
        }
    }
    public func discardMetadataInventoryStage(_ job: UUID) throws {
        try database.write { try discardMetadataInventoryStage($0, job) }
    }
    private func discardMetadataInventoryStage(_ db: Database, _ job: UUID) throws {
        try InventoryStagingRecord.filter { $0.job == job.uuidString }.deleteAll(db)
    }
    public func commitMetadataInventory(_ job: UUID, namespace: MetadataNamespace, catalog: CollectionDayCatalog,
                                       cursor: DiffCursor?, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            let staged = try InventoryStagingRecord.filter { $0.job == job.uuidString && $0.namespace == namespace.key }.fetchAll(db)
            guard catalog.completeness == .complete, staged.count == catalog.itemCount else { throw CollectionCatalogError.invalidCoverage }
            var dayCounts: [String: Int] = [:]
            for record in staged { dayCounts[try CaptureDay(time: record.captureTime).id, default: 0] += 1 }
            guard dayCounts == Dictionary(uniqueKeysWithValues: catalog.days.map { ($0.day.id, $0.count) }) else { throw CollectionCatalogError.invalidCoverage }
            try ItemIndexRecord.filter { $0.namespace == namespace.key }.deleteAll(db)
            for record in staged {
                try ItemIndexRecord(namespace: namespace.key, itemID: record.itemID, captureTime: record.captureTime, projection: record.projection,
                                    profile: ItemFieldProfile.locations.rawValue, epoch: admission.resetEpoch, identityEpoch: admission.resetEpoch).insert(db)
            }
            let state = try metadataState(db, namespace)
            try writeState(db, namespace, revision: state.revision + 1, resetEpoch: state.resetEpoch, cursor: cursor, inventoryComplete: true,
                           proofRun: state.proofRun)
            try discardMetadataInventoryStage(db, job)
        }
    }

    // MARK: Source changes and local mutations

    /// Source advancement and every dependent invalidation share this transaction.
    /// A reset enrolls only later reads; future empty intervals cannot revive old rows.
    /// `favorites` holds the final value of each favorite event in the interval; `proven`
    /// records that this run's feeds account for every change since the stored cursor.
    public func applyMetadataChanges(namespace: MetadataNamespace, cursor: DiffCursor?,
                                     replacements: [PhotoItem], deletedIDs: [Int64],
                                     affectedDays: Set<CaptureDay>, invalidateAll: Bool,
                                     favorites: [Int64: Bool] = [:], proven: Bool = false,
                                     currentRun: String, admission: MetadataStoreAdmission) throws {
        guard Set(replacements.map(\.id)).count == replacements.count,
              Set(deletedIDs).count == deletedIDs.count,
              Set(replacements.map(\.id)).isDisjoint(with: deletedIDs) else { throw CollectionCatalogError.invalidCoverage }
        try metadataWrite { db in
            try admit(admission, namespace: namespace, db)
            let prior = try metadataState(db, namespace)
            let changed = invalidateAll || !replacements.isEmpty || !deletedIDs.isEmpty || !favorites.isEmpty
            let revision = prior.revision + (changed ? 1 : 0)
            let epoch = prior.resetEpoch + (invalidateAll ? 1 : 0)
            let namespaceDays = CollectionDayRecord.filter { $0.namespace == namespace.key }
            let days = affectedDays.map(\.id)
            try (invalidateAll ? namespaceDays : namespaceDays.filter { days.contains($0.day) })
                .updateAll(db) { $0.membershipGeneration += 1 }
            if changed {
                try CollectionStateRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
                try AlbumSummariesRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            }
            try deleteItems(db, namespace, ids: deletedIDs)
            for item in replacements {
                try storeMetadataItem(db, item, profile: .fullPage, namespace: namespace, currentRun: currentRun, epoch: epoch, revision: revision,
                                      origin: nil)
            }
            if !favorites.isEmpty, !invalidateAll { try applyFavoriteEvents(db, favorites, namespace: namespace, currentRun: currentRun) }
            try writeState(db, namespace, revision: revision, resetEpoch: epoch, cursor: cursor,
                           inventoryComplete: !invalidateAll && prior.inventoryComplete,
                           proofRun: proven && !invalidateAll ? currentRun : nil)
        }
    }

    /// Patches favorite flags and marks only the Favorites days that can contain the
    /// items. An item without a known capture time invalidates all of Favorites.
    private func applyFavoriteEvents(_ db: Database, _ favorites: [Int64: Bool], namespace: MetadataNamespace,
                                     currentRun: String) throws {
        guard let space = namespace.scope.space else { return }
        let key = CollectionKey(namespace: namespace, collection: .favorites(space))
        var days: Set<String> = []
        var unknown = false
        for (id, favorite) in favorites {
            try patchMetadataDetail(db, namespace: namespace, itemID: id, annotationRun: currentRun) { $0.withFavorite(favorite) }
            if let time = try ItemIndexRecord.row(namespace, id).fetchOne(db)?.captureTime {
                days.insert(try CaptureDay(time: time).id)
            } else { unknown = true }
        }
        let favoriteDays = CollectionDayRecord.all(key)
        try (unknown ? favoriteDays : favoriteDays.filter { days.contains($0.day) }).updateAll(db) { $0.membershipGeneration += 1 }
        if unknown { try CollectionStateRecord.row(key).updateAll(db) { $0.validatedRun.set(to: nil) } }
    }

    public func invalidateMetadataCollection(_ key: CollectionKey, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: key.namespace)
            try CollectionStateRecord.row(key).updateAll(db) { $0.validatedRun.set(to: nil) }
            try CollectionDayRecord.all(key).updateAll(db) { $0.membershipGeneration += 1 }
            try advanceMetadataLocalRevision(db, key.namespace)
        }
    }

    /// Deleted items leave the namespace's indexes and every cached collection,
    /// summary and day page is revalidated before reuse. Unlike a Diff
    /// application this keeps the cursor and does not require a tombstone.
    public func invalidateMetadataAfterDeletion(namespace: MetadataNamespace, deletedIDs: [Int64],
                                                admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            try deleteItems(db, namespace, ids: Array(Set(deletedIDs)))
            try CollectionStateRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try AlbumSummariesRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try FolderDirectoryRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try FolderCoverRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try CollectionSummaryRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try CollectionDayRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.membershipGeneration += 1 }
            try advanceMetadataLocalRevision(db, namespace)
        }
    }

    /// Withdraws only this run's validation of catalogs and summary lists, so the next read
    /// of each fetches it again. Stored rows, page membership and Diff proof are untouched.
    public func withdrawSummaryValidation(namespace: MetadataNamespace,
                                          admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            try CollectionStateRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try AlbumSummariesRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try FolderDirectoryRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try FolderCoverRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
            try CollectionSummaryRecord.filter { $0.namespace == namespace.key }.updateAll(db) { $0.validatedRun.set(to: nil) }
        }
    }

    /// Keeps every stored row readable but withdraws all current-run validation and
    /// Diff proof. Dropping the cursor makes the next reconciliation start a new reset
    /// epoch, so every page and detail is read again before it counts as verified.
    public func withdrawMetadataValidation() throws {
        try metadataWrite { db in
            guard metadataInitialized else { return }
            try MetadataStateRecord.updateAll(db) { [$0.cursor.set(to: nil), $0.proofRun.set(to: nil), $0.revision += 1] }
            try CollectionStateRecord.updateAll(db) { $0.validatedRun.set(to: nil) }
            try AlbumSummariesRecord.updateAll(db) { $0.validatedRun.set(to: nil) }
            try FolderDirectoryRecord.updateAll(db) { $0.validatedRun.set(to: nil) }
            try FolderCoverRecord.updateAll(db) { $0.validatedRun.set(to: nil) }
            try CollectionSummaryRecord.updateAll(db) { $0.validatedRun.set(to: nil) }
            try DayPageRecord.updateAll(db) { $0.validatedRun.set(to: nil) }
            try ItemDetailRecord.updateAll(db) { $0.annotationRun.set(to: nil) }
            try CollectionDayRecord.updateAll(db) { $0.membershipGeneration += 1 }
        }
    }

    public func applyMetadataFavoriteValues(_ values: [Int64: Bool], namespace: MetadataNamespace,
                                            currentRun: String, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            for (id, favorite) in values {
                try patchMetadataDetail(db, namespace: namespace, itemID: id, annotationRun: currentRun) { $0.withFavorite(favorite) }
            }
            if let space = namespace.scope.space {
                let favorites = CollectionKey(namespace: namespace, collection: .favorites(space))
                try CollectionStateRecord.row(favorites).updateAll(db) { $0.validatedRun.set(to: nil) }
                try CollectionDayRecord.all(favorites).updateAll(db) { $0.membershipGeneration += 1 }
            }
            try advanceMetadataLocalRevision(db, namespace)
        }
    }
    /// Replaces the rating and tags of cached details and withdraws the validation of the tag
    /// index and of the collections of every tag whose membership changed.
    public func applyMetadataAnnotations(_ values: [Int64: PhotoAnnotations], changedTagIDs: Set<Int64>,
                                         namespace: MetadataNamespace, admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            for (id, annotations) in values {
                try patchMetadataDetail(db, namespace: namespace, itemID: id) { $0.withAnnotations(annotations) }
            }
            if let space = namespace.scope.space {
                for tagID in changedTagIDs {
                    let key = CollectionKey(namespace: namespace, collection: .tag(tagID, space: space))
                    try CollectionStateRecord.row(key).updateAll(db) { $0.validatedRun.set(to: nil) }
                    try CollectionDayRecord.all(key).updateAll(db) { $0.membershipGeneration += 1 }
                }
                try CollectionSummaryRecord.row(namespace, .tag).updateAll(db) { $0.validatedRun.set(to: nil) }
            }
            try advanceMetadataLocalRevision(db, namespace)
        }
    }
    public func applyMetadataRotationValues(_ values: [Int64: PhotoItem], namespace: MetadataNamespace,
                                            admission: MetadataStoreAdmission) throws {
        try metadataWrite { db in
            try admitLifetime(admission, namespace: namespace)
            for (id, replacement) in values {
                try patchMetadataDetail(db, namespace: namespace, itemID: id) { $0.withRotationMetadata(from: replacement) }
                if var index = try ItemIndexRecord.row(namespace, id).fetchOne(db) {
                    index.projection = MetadataIndexItem(id: id, time: index.captureTime, coordinate: index.projection?.coordinate,
                                                         thumbnail: replacement.additional?.thumbnail)
                    try index.update(db, columns: [ItemIndexRecord.Columns.projection])
                }
            }
            try advanceMetadataLocalRevision(db, namespace)
        }
    }
    private func patchMetadataDetail(_ db: Database, namespace: MetadataNamespace, itemID: Int64, annotationRun: String? = nil,
                                     transform: (PhotoItem) -> PhotoItem) throws {
        guard var detail = try ItemDetailRecord.row(namespace, itemID).fetchOne(db) else { return }
        detail.payload = transform(detail.payload)
        detail.revision += 1
        if let annotationRun { detail.annotationRun = annotationRun }
        try detail.update(db)
    }

    public func evictMetadataDetails(namespace: MetadataNamespace, itemIDs: [Int64]) throws {
        _ = try database.write { db in
            try ItemDetailRecord.filter { $0.namespace == namespace.key && itemIDs.contains($0.itemID) }.deleteAll(db)
        }
    }

    // MARK: Budget and eviction

    public func metadataStorageCost() throws -> Int64 {
        try database.read { try metadataStorageCost($0) }
    }
    /// Approximate stored bytes per row kind; eviction compares these against the budget.
    func metadataStorageCost(_ db: Database) throws -> Int64 {
        guard metadataInitialized else { return 0 }
        func total<Record: TableRecord>(_ record: Record.Type, _ cost: SQLExpression) throws -> Int64 {
            try Int64.fetchOne(db, Record.select(sum(cost) ?? 0)) ?? 0
        }
        return try total(ItemDetailRecord.self, length(ItemDetailRecord.Columns.payload))
            + total(DayPageRecord.self, DayPageRecord.Columns.actualCount * 16 + 128)
            + total(ItemIndexRecord.self, (length(ItemIndexRecord.Columns.projection) ?? 0) + 64)
            + total(CollectionStateRecord.self, length(CollectionStateRecord.Columns.catalog) + 128)
            + total(AlbumSummariesRecord.self, length(AlbumSummariesRecord.Columns.payload))
    }

    /// Approximates a stored JSON column's length for eviction accounting.
    private static func encodedSize<Value: Encodable>(_ value: Value) -> Int64 {
        Int64((try? JSONEncoder().encode(value).count) ?? 0)
    }

    private enum EvictionVictim {
        case detail(ItemDetailRecord), page(DayPageRecord), index(ItemIndexRecord), collection(CollectionStateRecord), albums(AlbumSummariesRecord)
    }

    /// Eviction preserves page slots when details leave, and removes membership items
    /// together with their page. The compact inventory has Map's retention priority.
    /// Returns the estimated cost removed (as counted by `metadataStorageCost`), or nil
    /// when nothing at or below `throughRank` remained.
    func trimNormalizedMetadata(throughRank: Int) throws -> Int64? {
        let pageRank = CachePriorityPolicy.evictionRank(for: .metadataPage)
        let indexRank = CachePriorityPolicy.evictionRank(for: .locationIndex)
        let catalogRank = CachePriorityPolicy.evictionRank(for: .activeTimeline)
        return try metadataWrite(enforceBudget: false) { db -> Int64? in
            guard metadataInitialized else { return nil }
            var candidates: [(rank: Int, accessed: Double, victim: EvictionVictim)] = []
            if pageRank <= throughRank {
                if let detail = try ItemDetailRecord.order(ItemDetailRecord.Columns.accessed).fetchOne(db) { candidates.append((pageRank, detail.accessed, .detail(detail))) }
                if let page = try DayPageRecord.order(DayPageRecord.Columns.accessed).fetchOne(db) { candidates.append((pageRank, page.accessed, .page(page))) }
            }
            if indexRank <= throughRank, let index = try ItemIndexRecord.fetchOne(db) { candidates.append((indexRank, 0, .index(index))) }
            if catalogRank <= throughRank {
                if let state = try CollectionStateRecord.fetchOne(db) { candidates.append((catalogRank, 0, .collection(state))) }
                if let albums = try AlbumSummariesRecord.order(AlbumSummariesRecord.Columns.accessed).fetchOne(db) { candidates.append((catalogRank, albums.accessed, .albums(albums))) }
            }
            guard let victim = candidates.min(by: { ($0.rank, $0.accessed) < ($1.rank, $1.accessed) })?.victim else { return nil }
            switch victim {
            case .detail(let detail):
                try detail.delete(db)
                return Self.encodedSize(detail.payload)
            case .page(let page):
                try PageItemRecord.page(of: page).deleteAll(db)
                try page.delete(db)
                return Int64(page.actualCount) * 16 + 128
            case .index(let index):
                try markInventoryIncomplete(db, index.namespace, cause: "cache budget evicted an item index row")
                try index.delete(db)
                return (index.projection.map(Self.encodedSize) ?? 0) + 64
            case .collection(let state):
                try MetadataStateRecord.filter(key: state.namespace).updateAll(db) { $0.revision += 1 }
                let namespace = state.namespace, collection = state.collection
                let pages = DayPageRecord.filter { $0.namespace == namespace && $0.collection == collection }
                let pageCost = try Int64.fetchOne(db, pages.select(sum(DayPageRecord.Columns.actualCount * 16 + 128) ?? 0)) ?? 0
                try PageItemRecord.filter { $0.namespace == namespace && $0.collection == collection }.deleteAll(db)
                try pages.deleteAll(db)
                try CollectionDayRecord.filter { $0.namespace == namespace && $0.collection == collection }.deleteAll(db)
                try state.delete(db)
                return pageCost + Self.encodedSize(state.catalog) + 128
            case .albums(let albums):
                try albums.delete(db)
                return Self.encodedSize(albums.payload)
            }
        }
    }

    // MARK: Helpers

    private func deleteItems(_ db: Database, _ namespace: MetadataNamespace, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try ItemIndexRecord.filter { $0.namespace == namespace.key && ids.contains($0.itemID) }.deleteAll(db)
        try ItemDetailRecord.filter { $0.namespace == namespace.key && ids.contains($0.itemID) }.deleteAll(db)
    }
    private func deleteMetadataDay(_ db: Database, _ key: CollectionKey, day: CaptureDay) throws {
        let namespace = key.namespace.key, collection = key.collection.rawValue
        try PageItemRecord.filter { $0.namespace == namespace && $0.collection == collection && $0.day == day.id }.deleteAll(db)
        try DayPageRecord.filter { $0.namespace == namespace && $0.collection == collection && $0.day == day.id }.deleteAll(db)
        try CollectionDayRecord.row(key, day: day.id).deleteAll(db)
    }
    private func deleteMetadataPage(_ db: Database, _ address: DayPageAddress, namespace: MetadataNamespace) throws {
        try PageItemRecord.page(address, namespace).deleteAll(db)
        try DayPageRecord.page(address, namespace).deleteAll(db)
    }
    private func metadataWrite<Value>(enforceBudget: Bool = true, _ operation: (Database) throws -> Value) throws -> Value {
        var value: Value?
        try database.inTransaction(.immediate) { db in
            value = try operation(db)
            return .commit
        }
        if enforceBudget { try trim(metadataWrite: true) }
        return value!
    }
}

/// One stored day page of a collection, reduced to filter facets.
struct MetadataFilterPage: Sendable {
    let address: DayPageAddress
    /// Members with stored details, in ordinal order. Members without details are omitted.
    let entries: [MetadataFilterEntry]
    let verified: Bool
}
struct MetadataFilterEntry: Sendable {
    let ordinal: Int
    let itemID: Int64
    let time: Int64?
    let values: LibraryFilterValues
}
private struct FilterPageKey: Hashable { let day: String; let offset: Int; let capacity: Int; let order: String }

// MARK: - Keyed requests

private extension ItemIndexRecord {
    static func row(_ namespace: MetadataNamespace, _ id: Int64) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == namespace.key && $0.itemID == id }
    }
}
private extension ItemDetailRecord {
    static func row(_ namespace: MetadataNamespace, _ id: Int64) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == namespace.key && $0.itemID == id }
    }
}
private extension CollectionStateRecord {
    static func row(_ key: CollectionKey) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == key.namespace.key && $0.collection == key.collection.rawValue }
    }
}
private extension CollectionDayRecord {
    static func all(_ key: CollectionKey) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == key.namespace.key && $0.collection == key.collection.rawValue }
    }
    static func row(_ key: CollectionKey, day: String) -> QueryInterfaceRequest<Self> {
        all(key).filter { $0.day == day }
    }
}
/// A day page is identified by six columns, shared by `day_pages` and `page_items`.
private func dayPageKey(namespace: String, collection: String, day: String, offset: Int, capacity: Int, order: String) -> SQLExpression {
    typealias C = DayPageRecord.Columns
    let terms: [SQLExpression] = [C.namespace == namespace, C.collection == collection, C.day == day,
                                  C.pageOffset == offset, C.capacity == capacity, C.sortOrder == order]
    return terms.joined(operator: .and)
}
private func dayPageKey(_ address: DayPageAddress, _ namespace: MetadataNamespace) -> SQLExpression {
    dayPageKey(namespace: namespace.key, collection: address.collection.rawValue, day: address.day.id,
               offset: address.offset, capacity: address.capacity, order: address.order.rawValue)
}
private extension DayPageRecord {
    static func page(_ address: DayPageAddress, _ namespace: MetadataNamespace) -> QueryInterfaceRequest<Self> {
        filter(dayPageKey(address, namespace))
    }
    static func page(of member: PageItemRecord) -> QueryInterfaceRequest<Self> {
        filter(dayPageKey(namespace: member.namespace, collection: member.collection, day: member.day,
                          offset: member.pageOffset, capacity: member.capacity, order: member.sortOrder))
    }
}
private extension PageItemRecord {
    static func page(_ address: DayPageAddress, _ namespace: MetadataNamespace) -> QueryInterfaceRequest<Self> {
        filter(dayPageKey(address, namespace))
    }
    static func page(of page: DayPageRecord) -> QueryInterfaceRequest<Self> {
        filter(dayPageKey(namespace: page.namespace, collection: page.collection, day: page.day,
                          offset: page.pageOffset, capacity: page.capacity, order: page.sortOrder))
    }
}
private extension CollectionSummaryRecord {
    static func row(_ namespace: MetadataNamespace, _ kind: CollectionIndexKind) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == namespace.key && $0.kind == kind.rawValue }
    }
}
private extension FolderDirectoryRecord {
    static func row(_ namespace: MetadataNamespace, _ id: Int64) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == namespace.key && $0.folderID == id }
    }
}
private extension FolderCoverRecord {
    static func row(_ namespace: MetadataNamespace, _ id: Int64) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == namespace.key && $0.folderID == id }
    }
}
private extension FilterOptionCatalogRecord {
    static func row(_ key: CollectionKey) -> QueryInterfaceRequest<Self> {
        filter { $0.namespace == key.namespace.key && $0.collection == key.collection.rawValue }
    }
}

extension PhotoCollectionDescriptor {
    /// Collections whose membership their space's Diff feeds fully describe: folder moves and
    /// tag edits arrive as item modifications, and Personal favorites as favorite events. Shared
    /// Space has no favorite-event feed. Album members have no resolved origin space, People and
    /// Subjects assignments are not shown to appear in the feeds, and Recently Added groups by
    /// indexed day, so those keep per-run reads.
    var membershipProvenByChanges: Bool {
        switch self {
        case .library, .folder, .tag, .favorites(.personal): return true
        default: return false
        }
    }
}
