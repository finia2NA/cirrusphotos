import Foundation
import GRDB
import SynologyAPI

/// The cache's tables. Each record type is the row shape of one table; `CacheSchema`
/// creates the tables from the same column keys. Incompatible formats are discarded,
/// never migrated: media rows by `DiskCache.schemaVersion`, metadata rows by
/// `DiskCache.metadataFormatVersion`. Nested Codable columns are stored as JSON text.
enum CacheSchema {
    static let metadataTables = [
        MetadataStateRecord.databaseTableName, ItemIndexRecord.databaseTableName, ItemDetailRecord.databaseTableName,
        CollectionStateRecord.databaseTableName, CollectionDayRecord.databaseTableName, DayPageRecord.databaseTableName,
        PageItemRecord.databaseTableName, CollectionSummaryRecord.databaseTableName, FolderDirectoryRecord.databaseTableName,
        AlbumSummariesRecord.databaseTableName, FilterOptionCatalogRecord.databaseTableName, InventoryStagingRecord.databaseTableName
    ]

    static func createMediaTables(_ db: Database) throws {
        typealias C = CacheEntryRecord.Columns
        try db.create(table: CacheEntryRecord.databaseTableName, options: .ifNotExists) { t in
            t.primaryKey(C.key.name, .text)
            t.column(C.kind.name, .integer).notNull()
            t.column(C.file.name, .text)
            t.column(C.cost.name, .integer).notNull()
            t.column(C.accessed.name, .double).notNull()
            t.column(C.validatedRun.name, .text)
            t.column(C.etag.name, .text)
            t.column(C.lastModified.name, .text)
            t.column(C.digest.name, .text)
            t.column(C.retentionClass.name, .text)
            t.column(C.retentionRank.name, .integer)
            t.column(C.thumbnailFamily.name, .text)
            t.column(C.thumbnailSize.name, .text)
            t.column(C.rowRevision.name, .integer).notNull()
        }
        try db.create(index: "entries_retention", on: CacheEntryRecord.databaseTableName,
                      columns: [C.retentionRank.name, C.accessed.name], options: .ifNotExists)
        try db.create(index: "entries_thumbnail_family", on: CacheEntryRecord.databaseTableName,
                      columns: [C.thumbnailFamily.name, C.thumbnailSize.name], options: .ifNotExists)
    }

    static func createMetadataTables(_ db: Database) throws {
        try table(MetadataStateRecord.self, db, key: [.namespace]) { t in
            t.column(.namespace, .text); t.column(.revision, .integer); t.column(.resetEpoch, .integer)
            t.column(.cursor, .text, nullable: true); t.column(.inventoryComplete, .boolean)
        }
        try table(ItemIndexRecord.self, db, key: [.namespace, .itemID]) { t in
            t.column(.namespace, .text); t.column(.itemID, .integer); t.column(.captureTime, .integer)
            t.column(.projection, .text, nullable: true); t.column(.profile, .text); t.column(.epoch, .integer)
            t.column(.identityEpoch, .integer)
        }
        try table(ItemDetailRecord.self, db, key: [.namespace, .itemID]) { t in
            t.column(.namespace, .text); t.column(.itemID, .integer); t.column(.payload, .text)
            t.column(.contentEpoch, .integer); t.column(.annotationRun, .text, nullable: true)
            t.column(.revision, .integer); t.column(.accessed, .double)
            let facets = TableBuilder<ItemFacets.CodingKeys>(table: t.table)
            facets.column(.captureTime, .integer); facets.column(.indexedTime, .integer, nullable: true)
            facets.column(.mediaKind, .text); facets.column(.camera, .text, nullable: true)
            facets.column(.lens, .text, nullable: true); facets.column(.fileExtension, .text, nullable: true)
            facets.column(.megapixels, .double, nullable: true); facets.column(.bytes, .integer, nullable: true)
            facets.column(.iso, .double, nullable: true); facets.column(.focalLength, .double, nullable: true)
            facets.column(.aperture, .double, nullable: true); facets.column(.exposure, .double, nullable: true)
        }
        try table(CollectionStateRecord.self, db, key: [.namespace, .collection]) { t in
            t.column(.namespace, .text); t.column(.collection, .text); t.column(.catalog, .text)
            t.column(.presentationRevision, .integer); t.column(.validatedRun, .text, nullable: true); t.column(.epoch, .integer)
        }
        try table(CollectionDayRecord.self, db, key: [.namespace, .collection, .day]) { t in
            t.column(.namespace, .text); t.column(.collection, .text); t.column(.day, .text)
            t.column(.itemCount, .integer); t.column(.membershipGeneration, .integer)
        }
        try table(DayPageRecord.self, db, key: [.namespace, .collection, .day, .pageOffset, .capacity, .sortOrder]) { t in
            t.column(.namespace, .text); t.column(.collection, .text); t.column(.day, .text)
            t.column(.pageOffset, .integer); t.column(.capacity, .integer); t.column(.sortOrder, .text)
            t.column(.actualCount, .integer); t.column(.dayCount, .integer); t.column(.dayGeneration, .integer)
            t.column(.revision, .integer); t.column(.epoch, .integer); t.column(.validatedRun, .text, nullable: true)
            t.column(.accessed, .double)
        }
        try table(PageItemRecord.self, db, key: [.namespace, .collection, .day, .pageOffset, .capacity, .sortOrder, .ordinal]) { t in
            t.column(.namespace, .text); t.column(.collection, .text); t.column(.day, .text)
            t.column(.pageOffset, .integer); t.column(.capacity, .integer); t.column(.sortOrder, .text)
            t.column(.ordinal, .integer); t.column(.itemID, .integer)
        }
        try table(CollectionSummaryRecord.self, db, key: [.namespace, .kind]) { t in
            t.column(.namespace, .text); t.column(.kind, .text); t.column(.payload, .blob)
            t.column(.validatedRun, .text, nullable: true)
        }
        try table(FolderDirectoryRecord.self, db, key: [.namespace, .folderID]) { t in
            t.column(.namespace, .text); t.column(.folderID, .integer); t.column(.payload, .text)
            t.column(.validatedRun, .text, nullable: true)
        }
        try table(AlbumSummariesRecord.self, db, key: [.namespace]) { t in
            t.column(.namespace, .text); t.column(.payload, .text); t.column(.validatedRun, .text, nullable: true)
            t.column(.revision, .integer); t.column(.accessed, .double)
        }
        try table(FilterOptionCatalogRecord.self, db, key: [.namespace, .collection]) { t in
            t.column(.namespace, .text); t.column(.collection, .text); t.column(.payload, .text)
        }
        try table(InventoryStagingRecord.self, db, key: [.job, .namespace, .itemID]) { t in
            t.column(.job, .text); t.column(.namespace, .text); t.column(.itemID, .integer)
            t.column(.captureTime, .integer); t.column(.projection, .text)
        }
        try db.create(index: "page_items_reverse", on: PageItemRecord.databaseTableName,
                      columns: [PageItemRecord.Columns.namespace.name, PageItemRecord.Columns.itemID.name], options: .ifNotExists)
        try db.create(index: "item_details_accessed", on: ItemDetailRecord.databaseTableName,
                      columns: [ItemDetailRecord.Columns.accessed.name], options: .ifNotExists)
        try db.create(index: "day_pages_accessed", on: DayPageRecord.databaseTableName,
                      columns: [DayPageRecord.Columns.accessed.name], options: .ifNotExists)
    }

    private struct TableBuilder<Key: ColumnExpression> {
        let table: TableDefinition
        func column(_ key: Key, _ type: Database.ColumnType, nullable: Bool = false) {
            let column = table.column(key.name, type)
            if !nullable { column.notNull() }
        }
    }

    private static func table<Record: TableRecord>(_ record: Record.Type, _ db: Database, key: [Record.Columns],
                                                   _ body: (TableBuilder<Record.Columns>) -> Void) throws
    where Record.Columns: ColumnExpression {
        try db.create(table: Record.databaseTableName, options: .ifNotExists) { t in
            body(TableBuilder(table: t))
            t.primaryKey(key.map(\.name))
        }
    }
}

// MARK: - Media

struct CacheEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entries"
    var key: String
    var kind: Int
    var file: String?
    var cost: Int64
    var accessed: Double
    var validatedRun: String?
    var etag: String?
    var lastModified: String?
    var digest: String?
    var retentionClass: String?
    var retentionRank: Int?
    var thumbnailFamily: String?
    var thumbnailSize: String?
    var rowRevision: Int64
    enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case key, kind, file, cost, accessed, etag, digest
        case validatedRun = "validated_run", lastModified = "last_modified", retentionClass = "retention_class"
        case retentionRank = "retention_rank", thumbnailFamily = "thumbnail_family", thumbnailSize = "thumbnail_size"
        case rowRevision = "row_revision"
    }
    typealias Columns = CodingKeys
}

// MARK: - Metadata

struct MetadataStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "metadata_state"
    var namespace: String
    var revision: Int64
    var resetEpoch: Int64
    var cursor: DiffCursor?
    var inventoryComplete: Bool
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, revision, cursor, resetEpoch = "reset_epoch", inventoryComplete = "inventory_complete"
    }
    typealias Columns = CodingKeys
}

/// Identity, capture time and the compact GPS/thumbnail projection used by Map.
struct ItemIndexRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_index"
    var namespace: String
    var itemID: Int64
    var captureTime: Int64
    var projection: MetadataIndexItem?
    var profile: String
    var epoch: Int64
    var identityEpoch: Int64
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, projection, profile, epoch
        case itemID = "item_id", captureTime = "capture_time", identityEpoch = "identity_epoch"
    }
    typealias Columns = CodingKeys
}

/// Scalar filter facets derived from a stored item. Written with every detail row,
/// so they share its lifetime (eviction, deletion, replacement, reset).
struct ItemFacets: Codable, Equatable, Sendable {
    var captureTime: Int64
    var indexedTime: Int64?
    var mediaKind: String
    var camera: String?
    var lens: String?
    var fileExtension: String?
    var megapixels: Double?
    var bytes: Int64?
    var iso: Double?
    var focalLength: Double?
    var aperture: Double?
    var exposure: Double?
    enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case camera, lens, megapixels, bytes, iso, aperture, exposure
        case captureTime = "capture_time", indexedTime = "indexed_time", mediaKind = "media_kind"
        case fileExtension = "file_extension", focalLength = "focal_length"
    }

    init(_ item: PhotoItem) {
        let values = LibraryFilterValues(item)
        captureTime = item.time; indexedTime = item.indexedTime; mediaKind = Self.mediaKindKey(values.mediaKind)
        camera = values.camera; lens = values.lens; fileExtension = values.fileExtension
        megapixels = values.megapixels; bytes = values.bytes; iso = values.iso
        focalLength = values.focalLengthMM; aperture = values.aperture; exposure = values.exposureSeconds
    }

    static func mediaKindKey(_ kind: PhotoMediaKind) -> String {
        switch kind {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "live"
        case .unknown(let type): "other:" + type
        }
    }

    /// Filter values for matching; `.unknown` for an unrecognized stored media kind.
    var values: LibraryFilterValues {
        let kind: PhotoMediaKind
        switch mediaKind {
        case "photo": kind = .photo
        case "video": kind = .video
        case "live": kind = .livePhoto
        case let key where key.hasPrefix("other:"): kind = .unknown(String(key.dropFirst("other:".count)))
        case let key: kind = .unknown(key)
        }
        return LibraryFilterValues(mediaKind: kind, camera: camera, lens: lens, fileExtension: fileExtension, megapixels: megapixels,
                                   bytes: bytes, iso: iso, focalLengthMM: focalLength, aperture: aperture, exposureSeconds: exposure)
    }

    // Mirrors `PhotoCollectionDescriptor.membershipTime(for:)`.
    func membershipTime(in collection: PhotoCollectionDescriptor) -> Int64? {
        collection == .recentlyAdded ? indexedTime.map { $0 / 1000 } : captureTime
    }
}

/// Canonical full item content. Evictable independently of identity and membership.
/// The row also carries the payload's `ItemFacets` as flat columns.
struct ItemDetailRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_details"
    var namespace: String
    var itemID: Int64
    var payload: PhotoItem { didSet { facets = ItemFacets(payload) } }
    var contentEpoch: Int64
    var annotationRun: String?
    var revision: Int64
    var accessed: Double
    private(set) var facets: ItemFacets
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, payload, revision, accessed
        case itemID = "item_id", contentEpoch = "content_epoch", annotationRun = "annotation_run"
    }
    typealias Columns = CodingKeys

    init(namespace: String, itemID: Int64, payload: PhotoItem, contentEpoch: Int64, annotationRun: String?, revision: Int64, accessed: Double) {
        self.namespace = namespace; self.itemID = itemID; self.payload = payload; self.contentEpoch = contentEpoch
        self.annotationRun = annotationRun; self.revision = revision; self.accessed = accessed
        facets = ItemFacets(payload)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try values.decode(String.self, forKey: .namespace); itemID = try values.decode(Int64.self, forKey: .itemID)
        payload = try values.decode(PhotoItem.self, forKey: .payload); contentEpoch = try values.decode(Int64.self, forKey: .contentEpoch)
        annotationRun = try values.decodeIfPresent(String.self, forKey: .annotationRun)
        revision = try values.decode(Int64.self, forKey: .revision); accessed = try values.decode(Double.self, forKey: .accessed)
        facets = try ItemFacets(from: decoder)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(namespace, forKey: .namespace); try values.encode(itemID, forKey: .itemID)
        try values.encode(payload, forKey: .payload); try values.encode(contentEpoch, forKey: .contentEpoch)
        try values.encode(annotationRun, forKey: .annotationRun)
        try values.encode(revision, forKey: .revision); try values.encode(accessed, forKey: .accessed)
        try facets.encode(to: encoder)
    }
}

/// The facet columns of `item_details`, without the payload.
struct ItemFacetRecord: Decodable, FetchableRecord, TableRecord {
    static let databaseTableName = ItemDetailRecord.databaseTableName
    static var databaseSelection: [any SQLSelectable] {
        let keys: [any SQLSelectable] = [ItemDetailRecord.Columns.itemID, ItemDetailRecord.Columns.contentEpoch, ItemDetailRecord.Columns.annotationRun]
        return keys + ItemFacets.CodingKeys.allCases.map { $0 as any SQLSelectable }
    }
    var itemID: Int64
    var contentEpoch: Int64
    var annotationRun: String?
    var facets: ItemFacets
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ItemDetailRecord.CodingKeys.self)
        itemID = try values.decode(Int64.self, forKey: .itemID); contentEpoch = try values.decode(Int64.self, forKey: .contentEpoch)
        annotationRun = try values.decodeIfPresent(String.self, forKey: .annotationRun)
        facets = try ItemFacets(from: decoder)
    }
}

struct CollectionStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection_state"
    var namespace: String
    var collection: String
    var catalog: CollectionDayCatalog
    var presentationRevision: Int64
    var validatedRun: String?
    var epoch: Int64
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, collection, catalog, epoch
        case presentationRevision = "presentation_revision", validatedRun = "validated_run"
    }
    typealias Columns = CodingKeys
}

struct CollectionDayRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection_days"
    var namespace: String
    var collection: String
    var day: String
    var itemCount: Int
    var membershipGeneration: Int64
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, collection, day, itemCount = "item_count", membershipGeneration = "membership_generation"
    }
    typealias Columns = CodingKeys
}

/// Exact ordered membership of one day page; its items are `PageItemRecord`s.
struct DayPageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "day_pages"
    var namespace: String
    var collection: String
    var day: String
    var pageOffset: Int
    var capacity: Int
    var sortOrder: String
    var actualCount: Int
    var dayCount: Int
    var dayGeneration: Int64
    var revision: Int64
    var epoch: Int64
    var validatedRun: String?
    var accessed: Double
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, collection, day, capacity, revision, epoch, accessed
        case pageOffset = "page_offset", sortOrder = "sort_order", actualCount = "actual_count", dayCount = "day_count"
        case dayGeneration = "day_generation", validatedRun = "validated_run"
    }
    typealias Columns = CodingKeys
}

struct PageItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "page_items"
    var namespace: String
    var collection: String
    var day: String
    var pageOffset: Int
    var capacity: Int
    var sortOrder: String
    var ordinal: Int
    var itemID: Int64
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case namespace, collection, day, capacity, ordinal
        case pageOffset = "page_offset", sortOrder = "sort_order", itemID = "item_id"
    }
    typealias Columns = CodingKeys
}

/// People, subject and tag indexes. The payload keeps the server's JSON shape,
/// which `CollectionIndexEntry` decodes with a kind-specific decoder.
struct CollectionSummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection_summaries"
    var namespace: String
    var kind: CollectionIndexKind
    var payload: Data
    var validatedRun: String?
    enum CodingKeys: String, CodingKey, ColumnExpression { case namespace, kind, payload, validatedRun = "validated_run" }
    typealias Columns = CodingKeys
}

struct FolderDirectoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder_directories"
    var namespace: String
    var folderID: Int64
    var payload: FolderDirectory
    var validatedRun: String?
    enum CodingKeys: String, CodingKey, ColumnExpression { case namespace, payload, folderID = "folder_id", validatedRun = "validated_run" }
    typealias Columns = CodingKeys
}

struct AlbumSummariesRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album_summaries"
    var namespace: String
    var payload: [AlbumSummary]
    var validatedRun: String?
    var revision: Int64
    var accessed: Double
    enum CodingKeys: String, CodingKey, ColumnExpression { case namespace, payload, revision, accessed, validatedRun = "validated_run" }
    typealias Columns = CodingKeys
}

struct FilterOptionCatalogRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "filter_option_catalogs"
    var namespace: String
    var collection: String
    var payload: LibraryFilterCatalog
    enum CodingKeys: String, CodingKey, ColumnExpression { case namespace, collection, payload }
    typealias Columns = CodingKeys
}

/// A full GPS inventory scan in progress; committed atomically into `item_index`.
struct InventoryStagingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "metadata_inventory_staging"
    var job: String
    var namespace: String
    var itemID: Int64
    var captureTime: Int64
    var projection: MetadataIndexItem
    enum CodingKeys: String, CodingKey, ColumnExpression { case job, namespace, projection, itemID = "item_id", captureTime = "capture_time" }
    typealias Columns = CodingKeys
}
