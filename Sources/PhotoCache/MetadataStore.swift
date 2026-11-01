import Foundation
import SQLite3
import SynologyAPI
import TimelineCore

/// Account identity includes the server and Personal Space. No bare item ID is a store key.
public struct MetadataNamespace: Hashable, Sendable {
    public let account: String
    public init(account: String) { self.account = account }
    var key: String { account + "|personal" }
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
}
public struct StoredCollectionCatalog: Sendable {
    public let catalog: CollectionDayCatalog
    public let presentationRevision: Int64
    public let validatedRun: String?
}
public struct MetadataStoreAdmission: Sendable {
    public let generation: Int
    public let metadataGeneration: Int
    public let revision: Int64
    public let resetEpoch: Int64
}

/// Typed helpers on the existing SQLite actor. No SQL transaction suspends.
/// The normalized format is initialized explicitly when the engine enrolls it.
extension DiskCache {
    static let metadataFormatVersion = 1
    private static let normalizedTables = ["filter_option_catalogs", "metadata_inventory_staging", "album_summaries", "page_items", "day_pages", "collection_days", "collection_state", "item_details", "item_index", "metadata_state"]

    public func initializeMetadataStore() throws {
        try metadataTransaction {
            try metadataSQL("CREATE TABLE IF NOT EXISTS metadata_format (version INTEGER NOT NULL)")
            let statement = try prepare("SELECT version FROM metadata_format")
            let version = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : nil
            sqlite3_finalize(statement)
            if version != Self.metadataFormatVersion {
                for table in Self.normalizedTables { try metadataSQL("DROP TABLE IF EXISTS \(table)") }
                try metadataSQL("DELETE FROM metadata_format; INSERT INTO metadata_format VALUES (\(Self.metadataFormatVersion))")
                // Media record values are unchanged. Superseded metadata is never decoded.
                try metadataSQL("DELETE FROM entries WHERE kind IN (3,4,5,6)")
            }
            try metadataSQL("""
            CREATE TABLE IF NOT EXISTS metadata_state (
              namespace TEXT PRIMARY KEY, revision INTEGER NOT NULL, reset_epoch INTEGER NOT NULL,
              cursor BLOB, inventory_complete INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS item_index (
              namespace TEXT NOT NULL, item_id INTEGER NOT NULL, capture_time INTEGER NOT NULL,
              projection BLOB, profile TEXT NOT NULL, epoch INTEGER NOT NULL, identity_epoch INTEGER NOT NULL,
              PRIMARY KEY(namespace,item_id));
            CREATE TABLE IF NOT EXISTS item_details (
              namespace TEXT NOT NULL, item_id INTEGER NOT NULL, payload BLOB NOT NULL,
              content_epoch INTEGER NOT NULL, annotation_run TEXT, revision INTEGER NOT NULL,
              cost INTEGER NOT NULL, accessed REAL NOT NULL,
              PRIMARY KEY(namespace,item_id));
            CREATE TABLE IF NOT EXISTS collection_state (
              namespace TEXT NOT NULL, collection TEXT NOT NULL, catalog BLOB NOT NULL,
              presentation_revision INTEGER NOT NULL, validated_run TEXT, epoch INTEGER NOT NULL,
              PRIMARY KEY(namespace,collection));
            CREATE TABLE IF NOT EXISTS collection_days (
              namespace TEXT NOT NULL, collection TEXT NOT NULL, day TEXT NOT NULL,
              item_count INTEGER NOT NULL, membership_generation INTEGER NOT NULL,
              PRIMARY KEY(namespace,collection,day));
            CREATE TABLE IF NOT EXISTS day_pages (
              namespace TEXT NOT NULL, collection TEXT NOT NULL, day TEXT NOT NULL,
              page_offset INTEGER NOT NULL, capacity INTEGER NOT NULL, sort_order TEXT NOT NULL,
              actual_count INTEGER NOT NULL, day_count INTEGER NOT NULL, day_generation INTEGER NOT NULL,
              revision INTEGER NOT NULL, epoch INTEGER NOT NULL, validated_run TEXT,
              cost INTEGER NOT NULL, accessed REAL NOT NULL,
              PRIMARY KEY(namespace,collection,day,page_offset,capacity,sort_order));
            CREATE TABLE IF NOT EXISTS page_items (
              namespace TEXT NOT NULL, collection TEXT NOT NULL, day TEXT NOT NULL,
              page_offset INTEGER NOT NULL, capacity INTEGER NOT NULL, sort_order TEXT NOT NULL,
              ordinal INTEGER NOT NULL, item_id INTEGER NOT NULL,
              PRIMARY KEY(namespace,collection,day,page_offset,capacity,sort_order,ordinal));
            CREATE TABLE IF NOT EXISTS album_summaries (
              namespace TEXT PRIMARY KEY,payload BLOB NOT NULL,validated_run TEXT,revision INTEGER NOT NULL,
              cost INTEGER NOT NULL,accessed REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS filter_option_catalogs (
              namespace TEXT NOT NULL, collection TEXT NOT NULL, payload BLOB NOT NULL,
              PRIMARY KEY(namespace,collection));
            CREATE TABLE IF NOT EXISTS metadata_inventory_staging (
              job TEXT NOT NULL, namespace TEXT NOT NULL, item_id INTEGER NOT NULL,
              capture_time INTEGER NOT NULL, projection BLOB NOT NULL,
              PRIMARY KEY(job,namespace,item_id));
            CREATE INDEX IF NOT EXISTS page_items_reverse ON page_items(namespace,item_id);
            """)
        }
    }

    func clearNormalizedMetadata() throws {
        let query = try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata_state'")
        let exists = sqlite3_step(query) == SQLITE_ROW
        sqlite3_finalize(query)
        guard exists else { return }
        for table in Self.normalizedTables { try metadataSQL("DELETE FROM \(table)") }
    }

    public func metadataState(_ namespace: MetadataNamespace) throws -> MetadataStoreVersion {
        let statement = try prepare("SELECT revision,reset_epoch,cursor,inventory_complete FROM metadata_state WHERE namespace=?")
        defer { sqlite3_finalize(statement) }
        bind(namespace.key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return MetadataStoreVersion(revision: 0, resetEpoch: 0, cursor: nil, inventoryComplete: false)
        }
        return MetadataStoreVersion(revision: sqlite3_column_int64(statement, 0), resetEpoch: sqlite3_column_int64(statement, 1),
                                    cursor: try metadataBlob(statement, 2).map { try JSONDecoder().decode(DiffCursor.self, from: $0) },
                                    inventoryComplete: sqlite3_column_int(statement, 3) == 1)
    }
    public func metadataAdmission(_ namespace: MetadataNamespace) throws -> MetadataStoreAdmission {
        let state = try metadataState(namespace)
        return MetadataStoreAdmission(generation: generation, metadataGeneration: metadataGeneration,
                                      revision: state.revision, resetEpoch: state.resetEpoch)
    }
    private func admit(_ admission: MetadataStoreAdmission, namespace: MetadataNamespace) throws {
        let state = try metadataState(namespace)
        guard generation == admission.generation, metadataGeneration == admission.metadataGeneration,
              state.revision == admission.revision, state.resetEpoch == admission.resetEpoch else {
            throw MetadataAdmissionError.superseded
        }
    }

    func filterOptionCatalog(_ key: CollectionKey) throws -> LibraryFilterCatalog? {
        let statement = try prepare("SELECT payload FROM filter_option_catalogs WHERE namespace=? AND collection=?")
        defer { sqlite3_finalize(statement) }
        bind(key.namespace.key, at: 1, in: statement)
        bind(key.collection.rawValue, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let payload = metadataBlob(statement, 0) else { return nil }
        return try? JSONDecoder().decode(LibraryFilterCatalog.self, from: payload)
    }

    func storeFilterOptionCatalog(_ catalog: LibraryFilterCatalog, key: CollectionKey,
                                  admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            try admit(admission, namespace: key.namespace)
            let data = try JSONEncoder().encode(catalog)
            let statement = try prepare("INSERT OR REPLACE INTO filter_option_catalogs VALUES (?,?,?)")
            bind(key.namespace.key, at: 1, in: statement)
            bind(key.collection.rawValue, at: 2, in: statement)
            metadataBind(data, at: 3, in: statement)
            try metadataStep(statement)
        }
    }

    public func metadataAlbumSummaries(_ namespace: MetadataNamespace) throws -> (albums: [AlbumSummary], validatedRun: String?)? {
        let statement = try prepare("SELECT payload,validated_run FROM album_summaries WHERE namespace=?")
        defer { sqlite3_finalize(statement) }
        bind(namespace.key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let data = metadataBlob(statement, 0) else { return nil }
        return (try JSONDecoder().decode([AlbumSummary].self, from: data), columnString(statement, 1))
    }
    public func storeMetadataAlbumSummaries(_ albums: [AlbumSummary], namespace: MetadataNamespace,
                                            currentRun: String, admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            let data = try JSONEncoder().encode(albums)
            let statement = try prepare("INSERT OR REPLACE INTO album_summaries VALUES (?,?,?,?,?,?)")
            bind(namespace.key, at: 1, in: statement); metadataBind(data, at: 2, in: statement)
            bind(currentRun, at: 3, in: statement); sqlite3_bind_int64(statement, 4, admission.revision)
            sqlite3_bind_int64(statement, 5, Int64(data.count)); sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try metadataStep(statement)
        }
    }

    public func invalidateMetadataAlbumSummaries(_ namespace: MetadataNamespace, admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            guard generation == admission.generation, metadataGeneration == admission.metadataGeneration else { throw MetadataAdmissionError.superseded }
            let statement = try prepare("UPDATE album_summaries SET validated_run=NULL WHERE namespace=?")
            bind(namespace.key, at: 1, in: statement)
            try metadataStep(statement)
            try advanceMetadataLocalRevision(namespace)
        }
    }

    public func metadataCatalog(_ key: CollectionKey) throws -> StoredCollectionCatalog? {
        let statement = try prepare("SELECT catalog,presentation_revision,validated_run FROM collection_state WHERE namespace=? AND collection=?")
        defer { sqlite3_finalize(statement) }
        bind(key.namespace.key, at: 1, in: statement); bind(key.collection.rawValue, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let data = metadataBlob(statement, 0) else { return nil }
        return StoredCollectionCatalog(catalog: try JSONDecoder().decode(CollectionDayCatalog.self, from: data),
                                       presentationRevision: sqlite3_column_int64(statement, 1), validatedRun: columnString(statement, 2))
    }
    public func metadataDayGeneration(_ key: CollectionKey, day: CaptureDay) throws -> Int64? {
        let statement = try prepare("SELECT membership_generation FROM collection_days WHERE namespace=? AND collection=? AND day=?")
        defer { sqlite3_finalize(statement) }
        bind(key.namespace.key, at: 1, in: statement); bind(key.collection.rawValue, at: 2, in: statement); bind(day.id, at: 3, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    /// Catalog presentation changes never stamp unaffected days with a new generation.
    public func storeMetadataCatalog(_ catalog: CollectionDayCatalog, key: CollectionKey,
                                     validatedRun: String, admission: MetadataStoreAdmission, invalidateMembership: Bool = false) throws {
        try metadataTransaction {
            try admit(admission, namespace: key.namespace)
            let prior = try metadataCatalog(key)
            let old = Dictionary(uniqueKeysWithValues: (prior?.catalog.days ?? []).map { ($0.day, $0.count) })
            let nextDays = Set(catalog.days.map(\.day))
            for entry in prior?.catalog.days ?? [] where !nextDays.contains(entry.day) {
                try deleteMetadataDay(key, day: entry.day)
            }
            var changed = prior == nil || prior?.catalog.completeness != catalog.completeness || old.count != catalog.days.count
            for entry in catalog.days {
                if old[entry.day] != entry.count { changed = true }
                let statement = try prepare("""
                INSERT INTO collection_days VALUES (?,?,?,?,1)
                ON CONFLICT(namespace,collection,day) DO UPDATE SET
                membership_generation=membership_generation + CASE WHEN item_count!=excluded.item_count OR \(invalidateMembership ? 1 : 0)=1 THEN 1 ELSE 0 END,
                item_count=excluded.item_count
                """)
                bind(key.namespace.key, at: 1, in: statement); bind(key.collection.rawValue, at: 2, in: statement)
                bind(entry.day.id, at: 3, in: statement); sqlite3_bind_int64(statement, 4, Int64(entry.count))
                try metadataStep(statement)
            }
            let revision = (prior?.presentationRevision ?? 0) + (changed ? 1 : 0)
            let statement = try prepare("INSERT OR REPLACE INTO collection_state VALUES (?,?,?,?,?,?)")
            bind(key.namespace.key, at: 1, in: statement); bind(key.collection.rawValue, at: 2, in: statement)
            metadataBind(try JSONEncoder().encode(catalog), at: 3, in: statement)
            sqlite3_bind_int64(statement, 4, revision); bind(validatedRun, at: 5, in: statement)
            sqlite3_bind_int64(statement, 6, admission.resetEpoch); try metadataStep(statement)
        }
    }

    public func metadataPage(_ address: DayPageAddress, namespace: MetadataNamespace,
                             currentRun: String) throws -> PhotoPageSnapshot? {
        let query = try prepare("""
        SELECT actual_count,day_count,day_generation,revision,epoch,validated_run
        FROM day_pages WHERE namespace=? AND collection=? AND day=? AND page_offset=? AND capacity=? AND sort_order=?
        """)
        bindMetadataAddress(address, namespace: namespace, statement: query)
        guard sqlite3_step(query) == SQLITE_ROW else { sqlite3_finalize(query); return nil }
        let count = Int(sqlite3_column_int64(query, 0)), dayCount = Int(sqlite3_column_int64(query, 1))
        let dayGeneration = sqlite3_column_int64(query, 2), revision = sqlite3_column_int64(query, 3), epoch = sqlite3_column_int64(query, 4)
        let run = columnString(query, 5)
        sqlite3_finalize(query)
        guard count > 0, count <= address.capacity, revision >= 0 else { throw CacheError.storage }
        let state = try metadataState(namespace)
        let key = CollectionKey(namespace: namespace, collection: address.collection)
        let currentDay = try metadataDayGeneration(key, day: address.day)
        let catalog = try metadataCatalog(key)
        let catalogCount = catalog?.catalog.days.first { $0.day == address.day }?.count
        var membershipVerified = run == currentRun && epoch == state.resetEpoch && currentDay == dayGeneration && catalogCount == dayCount
        let statement = try prepare("""
        SELECT p.ordinal,p.item_id,d.payload,d.content_epoch,d.annotation_run
        FROM page_items p LEFT JOIN item_details d ON d.namespace=p.namespace AND d.item_id=p.item_id
        WHERE p.namespace=? AND p.collection=? AND p.day=? AND p.page_offset=? AND p.capacity=? AND p.sort_order=?
        ORDER BY p.ordinal
        """)
        defer { sqlite3_finalize(statement) }
        bindMetadataAddress(address, namespace: namespace, statement: statement)
        var slots: [PhotoItemSlot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard Int(sqlite3_column_int64(statement, 0)) == slots.count else { throw CacheError.storage }
            let id = sqlite3_column_int64(statement, 1)
            let item = try metadataBlob(statement, 2).map { try JSONDecoder().decode(PhotoItem.self, from: $0) }
            guard item == nil || item?.id == id else { throw CacheError.storage }
            if let item, (try? CaptureDay(time: item.time)) != address.day { membershipVerified = false }
            let detailVerified = sqlite3_column_int64(statement, 3) == state.resetEpoch && columnString(statement, 4) == currentRun
            slots.append(PhotoItemSlot(itemID: id, item: item, verified: membershipVerified && detailVerified))
        }
        guard slots.count == count else { throw CacheError.storage }
        let touch = try prepare("UPDATE day_pages SET accessed=?7 WHERE namespace=?1 AND collection=?2 AND day=?3 AND page_offset=?4 AND capacity=?5 AND sort_order=?6")
        bindMetadataAddress(address, namespace: namespace, statement: touch)
        sqlite3_bind_double(touch, 7, Date().timeIntervalSince1970); try metadataStep(touch)
        let details = try prepare("UPDATE item_details SET accessed=?7 WHERE namespace=?1 AND item_id IN (SELECT item_id FROM page_items WHERE namespace=?1 AND collection=?2 AND day=?3 AND page_offset=?4 AND capacity=?5 AND sort_order=?6)")
        bindMetadataAddress(address, namespace: namespace, statement: details)
        sqlite3_bind_double(details, 7, Date().timeIntervalSince1970); try metadataStep(details)
        return PhotoPageSnapshot(address: address, membershipRevision: UInt64(revision), membershipVerified: membershipVerified,
                                 slots: slots.map { PhotoItemSlot(itemID: $0.itemID, item: $0.item, verified: membershipVerified && $0.verified) })
    }

    /// Membership and combined details commit together. Identity/location profiles do not overwrite full details.
    public func storeMetadataPage(_ page: DayPageRead, items: [PhotoItem], profile: ItemFieldProfile,
                                  namespace: MetadataNamespace, currentRun: String,
                                  admission: MetadataStoreAdmission) throws {
        guard items.count == page.count, Set(items.map(\.id)).count == items.count,
              try items.allSatisfy({ try CaptureDay(time: $0.time) == page.address.day }) else { throw CollectionCatalogError.invalidCoverage }
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            let key = CollectionKey(namespace: namespace, collection: page.address.collection)
            guard let expectedDay = try metadataDayGeneration(key, day: page.address.day),
                  expectedDay >= 0, UInt64(expectedDay) == page.membershipGeneration else { throw MetadataAdmissionError.superseded }
            for item in items { try storeMetadataItem(item, profile: profile, namespace: namespace, currentRun: currentRun, epoch: admission.resetEpoch, revision: admission.revision) }
            try storeMetadataMembership(page, ids: items.map(\.id), namespace: namespace, currentRun: currentRun, admission: admission)

        }
    }

    private func storeMetadataMembership(_ page: DayPageRead, ids: [Int64], namespace: MetadataNamespace,
                                         currentRun: String, admission: MetadataStoreAdmission) throws {
            let old = try prepare("SELECT revision FROM day_pages WHERE namespace=? AND collection=? AND day=? AND page_offset=? AND capacity=? AND sort_order=?")
            bindMetadataAddress(page.address, namespace: namespace, statement: old)
            let revision = (sqlite3_step(old) == SQLITE_ROW ? sqlite3_column_int64(old, 0) : 0) + 1
            sqlite3_finalize(old)
            try deleteMetadataPage(page.address, namespace: namespace)
            let statement = try prepare("INSERT INTO day_pages VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            bindMetadataAddress(page.address, namespace: namespace, statement: statement)
            sqlite3_bind_int64(statement, 7, Int64(page.count)); sqlite3_bind_int64(statement, 8, Int64(page.dayCount))
            sqlite3_bind_int64(statement, 9, Int64(page.membershipGeneration)); sqlite3_bind_int64(statement, 10, revision)
            sqlite3_bind_int64(statement, 11, admission.resetEpoch); bind(currentRun, at: 12, in: statement)
            sqlite3_bind_int64(statement, 13, Int64(ids.count * 16 + 128)); sqlite3_bind_double(statement, 14, Date().timeIntervalSince1970)
            try metadataStep(statement)
            for (ordinal, id) in ids.enumerated() {
                let statement = try prepare("INSERT INTO page_items VALUES (?,?,?,?,?,?,?,?)")
                bindMetadataAddress(page.address, namespace: namespace, statement: statement)
                sqlite3_bind_int64(statement, 7, Int64(ordinal)); sqlite3_bind_int64(statement, 8, id)
                try metadataStep(statement)
            }
    }
    public func storeMetadataIdentityPage(_ page: DayPageRead, entries: [DayTimelineEntry], namespace: MetadataNamespace,
                                          currentRun: String, admission: MetadataStoreAdmission) throws {
        guard entries.count == page.count, Set(entries.map(\.id)).count == entries.count,
              try entries.allSatisfy({ try CaptureDay(time: $0.time) == page.address.day }) else { throw CollectionCatalogError.invalidCoverage }
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            let generation = try metadataDayGeneration(CollectionKey(namespace: namespace, collection: page.address.collection), day: page.address.day)
            guard generation == Int64(page.membershipGeneration) else { throw MetadataAdmissionError.superseded }
            for entry in entries {
                let coverage = try prepare("UPDATE metadata_state SET inventory_complete=0 WHERE namespace=? AND NOT EXISTS (SELECT 1 FROM item_index WHERE namespace=? AND item_id=? AND capture_time=? AND epoch=? AND profile!='identityAndTime')")
                bind(namespace.key, at: 1, in: coverage); bind(namespace.key, at: 2, in: coverage)
                sqlite3_bind_int64(coverage, 3, entry.id); sqlite3_bind_int64(coverage, 4, entry.time); sqlite3_bind_int64(coverage, 5, admission.resetEpoch); try metadataStep(coverage)
                let statement = try prepare("""
                INSERT INTO item_index VALUES (?,?,?,NULL,'identityAndTime',-1,?)
                ON CONFLICT(namespace,item_id) DO UPDATE SET
                  epoch=CASE WHEN capture_time!=excluded.capture_time THEN -1 ELSE epoch END,
                  capture_time=excluded.capture_time,identity_epoch=excluded.identity_epoch
                """)
                bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, entry.id)
                sqlite3_bind_int64(statement, 3, entry.time); sqlite3_bind_int64(statement, 4, admission.resetEpoch); try metadataStep(statement)
                let dirty = try prepare("UPDATE item_details SET content_epoch=-1 WHERE namespace=? AND item_id=? AND json_extract(payload,'$.time')!=?")
                bind(namespace.key, at: 1, in: dirty); sqlite3_bind_int64(dirty, 2, entry.id); sqlite3_bind_int64(dirty, 3, entry.time); try metadataStep(dirty)
            }
            try storeMetadataMembership(page, ids: entries.map(\.id), namespace: namespace, currentRun: currentRun, admission: admission)
        }
    }

    private func storeMetadataItem(_ item: PhotoItem, profile: ItemFieldProfile, namespace: MetadataNamespace,
                                   currentRun: String, epoch: Int64, revision: Int64) throws {
        _ = try CaptureDay(time: item.time)
        let known = try prepare("SELECT capture_time FROM item_index WHERE namespace=? AND item_id=?")
        bind(namespace.key, at: 1, in: known); sqlite3_bind_int64(known, 2, item.id)
        let existed = sqlite3_step(known) == SQLITE_ROW
        let changedTime = existed && sqlite3_column_int64(known, 0) != item.time
        sqlite3_finalize(known)
        if !existed || (profile == .identityAndTime && changedTime) {
            let coverage = try prepare("UPDATE metadata_state SET inventory_complete=0 WHERE namespace=?")
            bind(namespace.key, at: 1, in: coverage); try metadataStep(coverage)
        }
        // Only a requested GPS profile may replace the compact projection with absent GPS.
        let statement = try prepare("""
        INSERT INTO item_index VALUES (?,?,?,?,?,?,?) ON CONFLICT(namespace,item_id) DO UPDATE SET
        capture_time=excluded.capture_time,
        projection=CASE WHEN excluded.profile='identityAndTime' THEN projection ELSE excluded.projection END,
        profile=CASE WHEN excluded.profile='identityAndTime' THEN profile ELSE excluded.profile END,
        epoch=CASE WHEN excluded.profile='identityAndTime' THEN CASE WHEN capture_time!=excluded.capture_time THEN -1 ELSE epoch END ELSE excluded.epoch END,
        identity_epoch=excluded.identity_epoch
        """)
        bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, item.id); sqlite3_bind_int64(statement, 3, item.time)
        metadataBind(profile == .identityAndTime ? nil : try JSONEncoder().encode(MetadataIndexItem(id: item.id, time: item.time, coordinate: item.coordinate, thumbnail: item.additional?.thumbnail)), at: 4, in: statement)
        bind(profile.rawValue, at: 5, in: statement); sqlite3_bind_int64(statement, 6, profile == .identityAndTime ? -1 : epoch); sqlite3_bind_int64(statement, 7, epoch); try metadataStep(statement)
        guard profile == .fullPage else {
            let prior = try prepare("SELECT payload FROM item_details WHERE namespace=? AND item_id=?")
            bind(namespace.key, at: 1, in: prior); sqlite3_bind_int64(prior, 2, item.id)
            let bytes = sqlite3_step(prior) == SQLITE_ROW ? metadataBlob(prior, 0) : nil
            sqlite3_finalize(prior)
            if let bytes, let full = try? JSONDecoder().decode(PhotoItem.self, from: bytes),
               full.time != item.time || (profile == .locations && (full.coordinate != item.coordinate || full.additional?.thumbnail != item.additional?.thumbnail)) {
                let dirty = try prepare("UPDATE item_details SET content_epoch=-1 WHERE namespace=? AND item_id=?")
                bind(namespace.key, at: 1, in: dirty); sqlite3_bind_int64(dirty, 2, item.id); try metadataStep(dirty)
            }
            return
        }
        let bytes = try JSONEncoder().encode(item)
        let detail = try prepare("INSERT OR REPLACE INTO item_details VALUES (?,?,?,?,?,?,?,?)")
        bind(namespace.key, at: 1, in: detail); sqlite3_bind_int64(detail, 2, item.id); metadataBind(bytes, at: 3, in: detail)
        sqlite3_bind_int64(detail, 4, epoch); bind(currentRun, at: 5, in: detail); sqlite3_bind_int64(detail, 6, revision)
        sqlite3_bind_int64(detail, 7, Int64(bytes.count)); sqlite3_bind_double(detail, 8, Date().timeIntervalSince1970)
        try metadataStep(detail)
    }

    public func metadataDetails(_ namespace: MetadataNamespace, ids: [Int64], currentRun: String) throws -> [Int64: PhotoItemSlot] {
        guard ids.count <= 2000 else { throw CollectionCatalogError.exceedsLimit }
        let state = try metadataState(namespace)
        var result: [Int64: PhotoItemSlot] = [:]
        for id in ids {
            let query = try prepare("SELECT payload,content_epoch,annotation_run FROM item_details WHERE namespace=? AND item_id=?")
            bind(namespace.key, at: 1, in: query); sqlite3_bind_int64(query, 2, id)
            if sqlite3_step(query) == SQLITE_ROW, let bytes = metadataBlob(query, 0) {
                let item = try JSONDecoder().decode(PhotoItem.self, from: bytes)
                result[id] = PhotoItemSlot(itemID: id, item: item,
                                          verified: sqlite3_column_int64(query, 1) == state.resetEpoch && columnString(query, 2) == currentRun)
            }
            sqlite3_finalize(query)
        }
        return result
    }
    public func storeMetadataDetails(_ items: [PhotoItem], namespace: MetadataNamespace,
                                     currentRun: String, admission: MetadataStoreAdmission) throws -> Set<CaptureDay> {
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            var dirtyDays: Set<CaptureDay> = []
            for item in items {
                let query = try prepare("SELECT payload,content_epoch FROM item_details WHERE namespace=? AND item_id=?")
                bind(namespace.key, at: 1, in: query); sqlite3_bind_int64(query, 2, item.id)
                if sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int64(query, 1) == admission.resetEpoch,
                   let bytes = metadataBlob(query, 0) {
                    let old = try JSONDecoder().decode(PhotoItem.self, from: bytes)
                    if old.withFavorite(false) != item.withFavorite(false) {
                        dirtyDays.insert(try CaptureDay(time: old.time)); dirtyDays.insert(try CaptureDay(time: item.time))
                    }
                }
                sqlite3_finalize(query)
                try storeMetadataItem(item, profile: .fullPage, namespace: namespace, currentRun: currentRun,
                                      epoch: admission.resetEpoch, revision: admission.revision)
            }
            if !dirtyDays.isEmpty {
                for day in dirtyDays {
                    let statement = try prepare("UPDATE collection_days SET membership_generation=membership_generation+1 WHERE namespace=? AND day=?")
                    bind(namespace.key, at: 1, in: statement); bind(day.id, at: 2, in: statement); try metadataStep(statement)
                }
                let catalog = try prepare("UPDATE collection_state SET validated_run=NULL WHERE namespace=?")
                bind(namespace.key, at: 1, in: catalog); try metadataStep(catalog)
                try advanceMetadataLocalRevision(namespace)
            }
            return dirtyDays
        }
    }
    public func metadataCollectionReferences(_ namespace: MetadataNamespace, collection: PhotoCollectionDescriptor, ids: [Int64]) throws -> [TimelineSection] {
        guard ids.count <= 100 else { throw CollectionCatalogError.exceedsLimit }
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let statement = try prepare("""
        SELECT DISTINCT d.day,d.page_offset,d.actual_count,d.day_count
        FROM page_items p JOIN day_pages d ON d.namespace=p.namespace AND d.collection=p.collection AND d.day=p.day
          AND d.page_offset=p.page_offset AND d.capacity=p.capacity AND d.sort_order=p.sort_order
        WHERE p.namespace=? AND p.collection=? AND p.item_id IN (\(placeholders))
        """)
        defer { sqlite3_finalize(statement) }
        bind(namespace.key, at: 1, in: statement)
        bind(collection.rawValue, at: 2, in: statement)
        for (offset, id) in ids.enumerated() { sqlite3_bind_int64(statement, Int32(offset + 3), id) }
        var sections: [TimelineSection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = columnString(statement, 0) else { throw CacheError.storage }
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { throw CacheError.storage }
            let day = try CaptureDay(year: parts[0], month: parts[1], day: parts[2])
            sections.append(TimelineSection(offset: Int(sqlite3_column_int64(statement, 1)), limit: Int(sqlite3_column_int64(statement, 2)),
                                            list: [TimelineDay(year: day.year, month: day.month, day: day.day, itemCount: Int(sqlite3_column_int64(statement, 3)))]))
        }
        return sections
    }

    public func metadataItemTimes(_ namespace: MetadataNamespace, ids: [Int64]) throws -> [MetadataIndexItem] {
        guard ids.count <= 2000 else { throw CollectionCatalogError.exceedsLimit }
        let epoch = try metadataState(namespace).resetEpoch
        var result: [MetadataIndexItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try prepare("SELECT item_id,capture_time FROM item_index WHERE namespace=? AND identity_epoch=? AND item_id IN (\(placeholders))")
            bind(namespace.key, at: 1, in: statement)
            sqlite3_bind_int64(statement, 2, epoch)
            for (offset, id) in batch.enumerated() { sqlite3_bind_int64(statement, Int32(offset + 3), id) }
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(MetadataIndexItem(id: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1), coordinate: nil, thumbnail: nil))
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    public func metadataInventory(_ namespace: MetadataNamespace) throws -> [MetadataIndexItem] {
        let statement = try prepare("SELECT item_id,capture_time,projection FROM item_index WHERE namespace=? ORDER BY capture_time DESC,item_id")
        defer { sqlite3_finalize(statement) }
        bind(namespace.key, at: 1, in: statement)
        var result: [MetadataIndexItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let data = metadataBlob(statement, 2) {
                let projection = try JSONDecoder().decode(MetadataIndexItem.self, from: data)
                result.append(MetadataIndexItem(id: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1),
                                                coordinate: projection.coordinate, thumbnail: projection.thumbnail))
            } else {
                result.append(MetadataIndexItem(id: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1), coordinate: nil, thumbnail: nil))
            }
        }
        return result
    }

    public func metadataLocationProjection(_ namespace: MetadataNamespace, currentOnly: Bool = false) throws -> (state: MetadataStoreVersion, records: [PhotoLocationRecord]) {
        (try metadataState(namespace), currentOnly ? try metadataCurrentLocations(namespace) : try metadataCachedLocations(namespace))
    }
    public func metadataCachedLocations(_ namespace: MetadataNamespace) throws -> [PhotoLocationRecord] {
        let statement = try prepare("SELECT item_id,capture_time,projection FROM item_index WHERE namespace=? AND projection IS NOT NULL")
        defer { sqlite3_finalize(statement) }
        bind(namespace.key, at: 1, in: statement)
        var records: [PhotoLocationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = metadataBlob(statement, 2) else { continue }
            let projection = try JSONDecoder().decode(MetadataIndexItem.self, from: data)
            if let coordinate = projection.coordinate {
                records.append(PhotoLocationRecord(id: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1), coordinate: coordinate, thumbnail: projection.thumbnail))
            }
        }
        return records.sorted { $0.time > $1.time || ($0.time == $1.time && $0.id < $1.id) }
    }
    public func stageMetadataInventory(_ items: [PhotoItem], job: UUID, namespace: MetadataNamespace,
                                      admission: MetadataStoreAdmission) throws {
        guard items.count <= 1000 else { throw CollectionCatalogError.exceedsLimit }
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            for item in items {
                _ = try CaptureDay(time: item.time)
                let statement = try prepare("INSERT INTO metadata_inventory_staging VALUES (?,?,?,?,?)")
                bind(job.uuidString, at: 1, in: statement); bind(namespace.key, at: 2, in: statement)
                sqlite3_bind_int64(statement, 3, item.id); sqlite3_bind_int64(statement, 4, item.time)
                metadataBind(try JSONEncoder().encode(MetadataIndexItem(id: item.id, time: item.time, coordinate: item.coordinate, thumbnail: item.additional?.thumbnail)), at: 5, in: statement)
                try metadataStep(statement)
            }
        }
    }
    public func discardMetadataInventoryStage(_ job: UUID) throws {
        let statement = try prepare("DELETE FROM metadata_inventory_staging WHERE job=?")
        bind(job.uuidString, at: 1, in: statement); try metadataStep(statement)
    }
    public func commitMetadataInventory(_ job: UUID, namespace: MetadataNamespace, catalog: CollectionDayCatalog,
                                       cursor: DiffCursor?, admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            let count = try prepare("SELECT COUNT(*) FROM metadata_inventory_staging WHERE job=? AND namespace=?")
            bind(job.uuidString, at: 1, in: count); bind(namespace.key, at: 2, in: count)
            let actual = sqlite3_step(count) == SQLITE_ROW ? Int(sqlite3_column_int64(count, 0)) : -1
            sqlite3_finalize(count)
            guard catalog.completeness == .complete, actual == catalog.itemCount else { throw CollectionCatalogError.invalidCoverage }
            let grouped = try prepare("SELECT strftime('%Y-%m-%d',capture_time,'unixepoch'),COUNT(*) FROM metadata_inventory_staging WHERE job=? AND namespace=? GROUP BY 1")
            bind(job.uuidString, at: 1, in: grouped); bind(namespace.key, at: 2, in: grouped)
            var dayCounts: [String: Int] = [:]
            while sqlite3_step(grouped) == SQLITE_ROW {
                if let day = columnString(grouped, 0) { dayCounts[day] = Int(sqlite3_column_int64(grouped, 1)) }
            }
            sqlite3_finalize(grouped)
            guard dayCounts == Dictionary(uniqueKeysWithValues: catalog.days.map { ($0.day.id, $0.count) }) else { throw CollectionCatalogError.invalidCoverage }
            let delete = try prepare("DELETE FROM item_index WHERE namespace=?")
            bind(namespace.key, at: 1, in: delete); try metadataStep(delete)
            let insert = try prepare("INSERT INTO item_index SELECT namespace,item_id,capture_time,projection,'locations',?,? FROM metadata_inventory_staging WHERE job=? AND namespace=?")
            sqlite3_bind_int64(insert, 1, admission.resetEpoch); sqlite3_bind_int64(insert, 2, admission.resetEpoch)
            bind(job.uuidString, at: 3, in: insert); bind(namespace.key, at: 4, in: insert); try metadataStep(insert)
            let state = try metadataState(namespace)
            let statement = try prepare("INSERT OR REPLACE INTO metadata_state VALUES (?,?,?,?,1)")
            bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, state.revision + 1)
            sqlite3_bind_int64(statement, 3, state.resetEpoch); metadataBind(try cursor.map { try JSONEncoder().encode($0) }, at: 4, in: statement)
            try metadataStep(statement)
            try discardMetadataInventoryStage(job)
        }
    }

    public func metadataCurrentLocations(_ namespace: MetadataNamespace) throws -> [PhotoLocationRecord] {
        let state = try metadataState(namespace)
        let statement = try prepare("SELECT item_id,capture_time,projection FROM item_index WHERE namespace=? AND epoch=? AND profile!='identityAndTime'")
        defer { sqlite3_finalize(statement) }
        bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, state.resetEpoch)
        var records: [PhotoLocationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = metadataBlob(statement, 2) else { continue }
            let projection = try JSONDecoder().decode(MetadataIndexItem.self, from: data)
            if let coordinate = projection.coordinate {
                records.append(PhotoLocationRecord(id: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1), coordinate: coordinate, thumbnail: projection.thumbnail))
            }
        }
        return records.sorted { $0.time > $1.time }
    }

    /// Source advancement and every dependent invalidation share this transaction.
    /// A reset enrolls only later reads; future empty intervals cannot revive old rows.
    public func applyMetadataChanges(namespace: MetadataNamespace, cursor: DiffCursor?,
                                     replacements: [PhotoItem], deletedIDs: [Int64],
                                     affectedDays: Set<CaptureDay>, invalidateAll: Bool,
                                     currentRun: String, admission: MetadataStoreAdmission) throws {
        guard Set(replacements.map(\.id)).count == replacements.count,
              Set(deletedIDs).count == deletedIDs.count,
              Set(replacements.map(\.id)).isDisjoint(with: deletedIDs) else { throw CollectionCatalogError.invalidCoverage }
        try metadataTransaction {
            try admit(admission, namespace: namespace)
            let prior = try metadataState(namespace)
            let changed = invalidateAll || !replacements.isEmpty || !deletedIDs.isEmpty
            let revision = prior.revision + (changed ? 1 : 0)
            let epoch = prior.resetEpoch + (invalidateAll ? 1 : 0)
            if invalidateAll {
                let statement = try prepare("UPDATE collection_days SET membership_generation=membership_generation+1 WHERE namespace=?")
                bind(namespace.key, at: 1, in: statement); try metadataStep(statement)
            } else {
                for day in affectedDays {
                    let statement = try prepare("UPDATE collection_days SET membership_generation=membership_generation+1 WHERE namespace=? AND day=?")
                    bind(namespace.key, at: 1, in: statement); bind(day.id, at: 2, in: statement); try metadataStep(statement)
                }
            }
            if changed {
                let statement = try prepare("UPDATE collection_state SET validated_run=NULL WHERE namespace=?")
                bind(namespace.key, at: 1, in: statement); try metadataStep(statement)
                let albums = try prepare("UPDATE album_summaries SET validated_run=NULL WHERE namespace=?")
                bind(namespace.key, at: 1, in: albums); try metadataStep(albums)
            }
            for id in deletedIDs {
                for table in ["item_index", "item_details"] {
                    let statement = try prepare("DELETE FROM \(table) WHERE namespace=? AND item_id=?")
                    bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, id); try metadataStep(statement)
                }
            }
            for item in replacements {
                try storeMetadataItem(item, profile: .fullPage, namespace: namespace, currentRun: currentRun, epoch: epoch, revision: revision)
            }
            let statement = try prepare("INSERT OR REPLACE INTO metadata_state VALUES (?,?,?,?,?)")
            bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, revision)
            sqlite3_bind_int64(statement, 3, epoch); metadataBind(try cursor.map { try JSONEncoder().encode($0) }, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, !invalidateAll && prior.inventoryComplete ? 1 : 0)
            try metadataStep(statement)
        }
    }

    public func invalidateMetadataCollection(_ key: CollectionKey, admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            guard generation == admission.generation, metadataGeneration == admission.metadataGeneration else { throw MetadataAdmissionError.superseded }
            let catalog = try prepare("UPDATE collection_state SET validated_run=NULL WHERE namespace=? AND collection=?")
            bind(key.namespace.key, at: 1, in: catalog); bind(key.collection.rawValue, at: 2, in: catalog); try metadataStep(catalog)
            let days = try prepare("UPDATE collection_days SET membership_generation=membership_generation+1 WHERE namespace=? AND collection=?")
            bind(key.namespace.key, at: 1, in: days); bind(key.collection.rawValue, at: 2, in: days); try metadataStep(days)
            try advanceMetadataLocalRevision(key.namespace)
        }
    }

    public func applyMetadataFavoriteValues(_ values: [Int64: Bool], namespace: MetadataNamespace,
                                            currentRun: String, admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            guard generation == admission.generation, metadataGeneration == admission.metadataGeneration else { throw MetadataAdmissionError.superseded }
            for (id, favorite) in values {
                try patchMetadataDetail(namespace: namespace, itemID: id, annotationRun: currentRun) { $0.withFavorite(favorite) }
            }
            let catalog = try prepare("UPDATE collection_state SET validated_run=NULL WHERE namespace=? AND collection='favorites'")
            bind(namespace.key, at: 1, in: catalog); try metadataStep(catalog)
            let days = try prepare("UPDATE collection_days SET membership_generation=membership_generation+1 WHERE namespace=? AND collection='favorites'")
            bind(namespace.key, at: 1, in: days); try metadataStep(days)
            try advanceMetadataLocalRevision(namespace)
        }
    }
    public func applyMetadataRotationValues(_ values: [Int64: PhotoItem], namespace: MetadataNamespace,
                                            admission: MetadataStoreAdmission) throws {
        try metadataTransaction {
            guard generation == admission.generation, metadataGeneration == admission.metadataGeneration else { throw MetadataAdmissionError.superseded }
            for (id, replacement) in values {
                try patchMetadataDetail(namespace: namespace, itemID: id) { $0.withRotationMetadata(from: replacement) }
                let query = try prepare("SELECT capture_time,projection FROM item_index WHERE namespace=? AND item_id=?")
                bind(namespace.key, at: 1, in: query); sqlite3_bind_int64(query, 2, id)
                if sqlite3_step(query) == SQLITE_ROW {
                    let time = sqlite3_column_int64(query, 0)
                    let prior = try metadataBlob(query, 1).map { try JSONDecoder().decode(MetadataIndexItem.self, from: $0) }
                    let projection = MetadataIndexItem(id: id, time: time, coordinate: prior?.coordinate, thumbnail: replacement.additional?.thumbnail)
                    let update = try prepare("UPDATE item_index SET projection=? WHERE namespace=? AND item_id=?")
                    metadataBind(try JSONEncoder().encode(projection), at: 1, in: update)
                    bind(namespace.key, at: 2, in: update); sqlite3_bind_int64(update, 3, id); try metadataStep(update)
                }
                sqlite3_finalize(query)
            }
            try advanceMetadataLocalRevision(namespace)
        }
    }
    private func patchMetadataDetail(namespace: MetadataNamespace, itemID: Int64, annotationRun: String? = nil,
                                     transform: (PhotoItem) -> PhotoItem) throws {
        let query = try prepare("SELECT payload FROM item_details WHERE namespace=? AND item_id=?")
        bind(namespace.key, at: 1, in: query); sqlite3_bind_int64(query, 2, itemID)
        let bytes = sqlite3_step(query) == SQLITE_ROW ? metadataBlob(query, 0) : nil
        sqlite3_finalize(query)
        guard let bytes else { return }
        let item = transform(try JSONDecoder().decode(PhotoItem.self, from: bytes))
        let encoded = try JSONEncoder().encode(item)
        let statement = try prepare("UPDATE item_details SET payload=?,cost=?,revision=revision+1,annotation_run=COALESCE(?,annotation_run) WHERE namespace=? AND item_id=?")
        metadataBind(encoded, at: 1, in: statement); sqlite3_bind_int64(statement, 2, Int64(encoded.count))
        bind(annotationRun, at: 3, in: statement); bind(namespace.key, at: 4, in: statement); sqlite3_bind_int64(statement, 5, itemID); try metadataStep(statement)
    }
    private func advanceMetadataLocalRevision(_ namespace: MetadataNamespace) throws {
        let prior = try metadataState(namespace)
        let statement = try prepare("INSERT OR REPLACE INTO metadata_state VALUES (?,?,?,?,?)")
        bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, prior.revision + 1)
        sqlite3_bind_int64(statement, 3, prior.resetEpoch)
        metadataBind(try prior.cursor.map { try JSONEncoder().encode($0) }, at: 4, in: statement)
        sqlite3_bind_int(statement, 5, prior.inventoryComplete ? 1 : 0); try metadataStep(statement)
    }

    public func evictMetadataDetails(namespace: MetadataNamespace, itemIDs: [Int64]) throws {
        try metadataTransaction {
            for id in itemIDs {
                let statement = try prepare("DELETE FROM item_details WHERE namespace=? AND item_id=?")
                bind(namespace.key, at: 1, in: statement); sqlite3_bind_int64(statement, 2, id); try metadataStep(statement)
            }
        }
    }
    public func metadataStorageCost() throws -> Int64 {
        guard try normalizedMetadataExists() else { return 0 }
        let query = try prepare("SELECT (SELECT COALESCE(SUM(cost),0) FROM item_details)+(SELECT COALESCE(SUM(cost),0) FROM day_pages)+(SELECT COALESCE(SUM(COALESCE(LENGTH(projection),0)+64),0) FROM item_index)+(SELECT COALESCE(SUM(LENGTH(catalog)+128),0) FROM collection_state)+(SELECT COALESCE(SUM(cost),0) FROM album_summaries)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw CacheError.storage }
        return sqlite3_column_int64(query, 0)
    }

    private func normalizedMetadataExists() throws -> Bool {
        let query = try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata_state'")
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW
    }
    /// Eviction preserves page slots when details leave, and removes reverse references
    /// together with a membership row. The compact inventory has Map's retention priority.
    func trimNormalizedMetadata(throughRank: Int) throws -> Bool {
        guard try normalizedMetadataExists() else { return false }
        let pageRank = CachePriorityPolicy.evictionRank(for: .metadataPage)
        let indexRank = CachePriorityPolicy.evictionRank(for: .locationIndex)
        let catalogRank = CachePriorityPolicy.evictionRank(for: .activeTimeline)
        let query = try prepare("""
        SELECT table_name,row_id,rank FROM (
          SELECT 'item_details' AS table_name,rowid AS row_id,\(pageRank) AS rank,accessed FROM item_details
          UNION ALL SELECT 'day_pages',rowid,\(pageRank),accessed FROM day_pages
          UNION ALL SELECT 'item_index',rowid,\(indexRank),0 FROM item_index
          UNION ALL SELECT 'collection_state',rowid,\(catalogRank),0 FROM collection_state
          UNION ALL SELECT 'album_summaries',rowid,\(catalogRank),accessed FROM album_summaries
        ) WHERE rank<=? ORDER BY rank,accessed LIMIT 1
        """)
        sqlite3_bind_int64(query, 1, Int64(throughRank))
        guard sqlite3_step(query) == SQLITE_ROW, let table = columnString(query, 0) else { sqlite3_finalize(query); return false }
        let row = sqlite3_column_int64(query, 1)
        sqlite3_finalize(query)
        try metadataTransaction(enforceBudget: false) {
            if table == "collection_state" {
                let revision = try prepare("UPDATE metadata_state SET revision=revision+1 WHERE namespace=(SELECT namespace FROM collection_state WHERE rowid=?)")
                sqlite3_bind_int64(revision, 1, row); try metadataStep(revision)
                for dependent in ["page_items", "day_pages", "collection_days"] {
                    let deletion = try prepare("DELETE FROM \(dependent) WHERE EXISTS (SELECT 1 FROM collection_state c WHERE c.rowid=? AND c.namespace=\(dependent).namespace AND c.collection=\(dependent).collection)")
                    sqlite3_bind_int64(deletion, 1, row); try metadataStep(deletion)
                }
            } else if table == "day_pages" {
                let references = try prepare("""
                DELETE FROM page_items WHERE EXISTS (
                  SELECT 1 FROM day_pages p WHERE p.rowid=? AND p.namespace=page_items.namespace
                  AND p.collection=page_items.collection AND p.day=page_items.day AND p.page_offset=page_items.page_offset
                  AND p.capacity=page_items.capacity AND p.sort_order=page_items.sort_order)
                """)
                sqlite3_bind_int64(references, 1, row); try metadataStep(references)
            } else if table == "item_index" {
                let dirty = try prepare("UPDATE metadata_state SET inventory_complete=0 WHERE namespace=(SELECT namespace FROM item_index WHERE rowid=?)")
                sqlite3_bind_int64(dirty, 1, row); try metadataStep(dirty)
            }
            let statement = try prepare("DELETE FROM \(table) WHERE rowid=?")
            sqlite3_bind_int64(statement, 1, row); try metadataStep(statement)
        }
        return true
    }

    private func deleteMetadataDay(_ key: CollectionKey, day: CaptureDay) throws {
        for table in ["page_items", "day_pages", "collection_days"] {
            let statement = try prepare("DELETE FROM \(table) WHERE namespace=? AND collection=? AND day=?")
            bind(key.namespace.key, at: 1, in: statement); bind(key.collection.rawValue, at: 2, in: statement); bind(day.id, at: 3, in: statement)
            try metadataStep(statement)
        }
    }
    private func deleteMetadataPage(_ address: DayPageAddress, namespace: MetadataNamespace) throws {
        for table in ["page_items", "day_pages"] {
            let statement = try prepare("DELETE FROM \(table) WHERE namespace=? AND collection=? AND day=? AND page_offset=? AND capacity=? AND sort_order=?")
            bindMetadataAddress(address, namespace: namespace, statement: statement); try metadataStep(statement)
        }
    }
    private func bindMetadataAddress(_ address: DayPageAddress, namespace: MetadataNamespace, statement: OpaquePointer?) {
        bind(namespace.key, at: 1, in: statement); bind(address.collection.rawValue, at: 2, in: statement)
        bind(address.day.id, at: 3, in: statement); sqlite3_bind_int64(statement, 4, Int64(address.offset))
        sqlite3_bind_int64(statement, 5, Int64(address.capacity)); bind(address.order.rawValue, at: 6, in: statement)
    }
    private func metadataBind(_ data: Data?, at index: Int32, in statement: OpaquePointer?) {
        guard let data else { sqlite3_bind_null(statement, index); return }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func metadataBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
    private func metadataStep(_ statement: OpaquePointer?) throws {
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CacheError.storage }
    }
    private func metadataSQL(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CacheError.storage }
    }
    private func metadataTransaction<Value>(enforceBudget: Bool = true, _ operation: () throws -> Value) throws -> Value {
        try metadataSQL("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try metadataSQL("COMMIT")
            if enforceBudget { try trim() }
            return value
        } catch {
            try? metadataSQL("ROLLBACK")
            throw error
        }
    }
}
